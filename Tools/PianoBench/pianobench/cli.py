from pathlib import Path
import argparse
import json
import sys
from .benchmark import evaluate_version, compare_runs
from .datasets import prepare_maestro, prepare_paired, combine_manifests
from .fixtures import generate_fixtures, demo_predictions
from .runners import NativeRunner, BasicPitchRunner, CommandRunner
from .integrity import verify_run
from .io import load_json
from .scoring import ScoreConfig

def main(argv=None):
    parser = argparse.ArgumentParser(description="Headless Semitone piano accuracy tester")
    commands = parser.add_subparsers(dest="command", required=True)
    fixtures = commands.add_parser("fixtures", help="generate original five-tier diagnostic MIDI/audio")
    fixtures.add_argument("output")
    fixtures.add_argument("--renderer", choices=["toy", "fluidsynth"], default="toy")
    fixtures.add_argument("--soundfont")
    fixtures.add_argument("--split", choices=["validation", "test"], default="validation")
    combine = commands.add_parser("combine", help="combine frozen suites while preserving dataset/split metadata")
    combine.add_argument("manifests", nargs="+")
    combine.add_argument("--output", required=True)
    combine.add_argument("--allow-unverified", action="store_true")
    for name in ("maestro", "smd", "maps", "pairs"):
        p = commands.add_parser("prepare-" + name, help="freeze a subset of local paired piano data")
        p.add_argument("root")
        p.add_argument("output")
        p.add_argument("--split", choices=["train", "validation", "test"], default="test")
        p.add_argument("--limit", type=int, default=25, help="0 includes all available pairs")
        p.add_argument("--unbalanced", action="store_true")
    run = commands.add_parser("run", help="transcribe and score every manifest case")
    run.add_argument("manifest")
    source = run.add_mutually_exclusive_group(required=True)
    source.add_argument("--predictions", help="directory of <piece-id>.json/.mid/.csv predictions")
    source.add_argument("--native", help="compiled native/pianobench executable")
    source.add_argument("--command-argv", help='JSON argv template with {audio} and {output}; never a shell command')
    run.add_argument("--model", help="compiled .mlmodelc")
    run.add_argument("--weights", help="TranskunWeights.bin")
    run.add_argument("--compute", choices=["ane", "cpu"], default="ane")
    run.add_argument("--engine", choices=["transkun", "basic-pitch"], default="transkun", help="native engine; Basic Pitch uses its declared piano preset/CoreML default")
    run.add_argument("--output-suffix", choices=[".json", ".mid", ".csv"], default=".json")
    run.add_argument("--timeout", type=float, default=1800)
    run.add_argument("--version", required=True, help="commit/configuration identifier for this run")
    run.add_argument("--output", required=True, help="new empty output directory")
    run.add_argument("--prediction-offset-semantics", choices=["key_release", "pedal_extended", "unspecified"])
    run.add_argument("--version-metadata", help="optional provenance JSON file")
    run.add_argument("--onset-ms", type=float, default=50)
    run.add_argument("--strict", action="store_true")
    run.add_argument("--bootstrap", type=int, default=2000)
    run.add_argument("--allow-unverified", action="store_true", help="mark an exploratory alignment run")
    run.add_argument("--min-onset-f1", type=float, help="optional 0..1 regression gate")
    compare = commands.add_parser("compare", help="paired version comparison on identical frozen inputs")
    compare.add_argument("before")
    compare.add_argument("after")
    compare.add_argument("--output", required=True)
    compare.add_argument("--fail-regression", type=float, help="allowed onset macro F1 decrease, e.g. 0.005")
    compare.add_argument("--onset-only", action="store_true", help="compare attacks when engine offset conventions differ; no duration delta")
    verify = commands.add_parser("verify-run", help="check saved report/prediction/input bytes without native inference")
    verify.add_argument("directory")
    demo = commands.add_parser("demo", help="verify pipeline with oracle and deliberately flawed outputs")
    demo.add_argument("output")
    args = parser.parse_args(argv)
    try:
        if args.command == "fixtures":
            print(generate_fixtures(args.output, renderer=args.renderer, soundfont=args.soundfont, split=args.split))
        elif args.command == "combine":
            print(combine_manifests(args.manifests, args.output, allow_unverified=args.allow_unverified))
        elif args.command.startswith("prepare-"):
            if args.limit < 0:
                raise ValueError("limit must be nonnegative")
            if args.command == "prepare-maestro":
                path = prepare_maestro(args.root, args.output, split=args.split, limit=args.limit, balanced=not args.unbalanced)
            else:
                dataset = {"prepare-smd": "SMD", "prepare-maps": "MAPS", "prepare-pairs": "CUSTOM"}[args.command]
                path = prepare_paired(args.root, args.output, dataset=dataset, split=args.split,
                                      limit=args.limit, balanced=not args.unbalanced)
            print(path)
        elif args.command == "run":
            if args.bootstrap < 0 or (args.min_onset_f1 is not None and not 0 <= args.min_onset_f1 <= 1):
                raise ValueError("invalid bootstrap count/minimum F1")
            runner = None
            if args.native:
                if not args.model or (args.engine == "transkun" and not args.weights):
                    raise ValueError("--native requires --model and --weights")
                if args.engine == "basic-pitch":
                    if args.compute != "ane":
                        raise ValueError("--compute is a Transkun setting; Basic Pitch uses its app CoreML default")
                    runner = BasicPitchRunner(args.native, args.model, offset_semantics=args.prediction_offset_semantics or "unspecified", timeout_seconds=args.timeout)
                else:
                    runner = NativeRunner(args.native, args.model, args.weights, compute=args.compute,
                                          offset_semantics=args.prediction_offset_semantics or "unspecified", timeout_seconds=args.timeout)
            elif args.command_argv:
                from .io import load_json_bytes
                runner = CommandRunner(load_json_bytes(args.command_argv), timeout_seconds=args.timeout,
                                       output_suffix=args.output_suffix, offset_semantics=args.prediction_offset_semantics)
            report = evaluate_version(args.manifest, version=args.version, output_dir=args.output,
                                      prediction_dir=args.predictions, transcriber=runner,
                                      prediction_offset_semantics=args.prediction_offset_semantics,
                                      config=ScoreConfig(onset_tolerance=args.onset_ms / 1000, strict=args.strict),
                                      version_metadata=load_json(args.version_metadata) if args.version_metadata else None,
                                      allow_unverified=args.allow_unverified, bootstrap_samples=args.bootstrap)
            print(json.dumps(report["summary"], indent=2))
            print(f"Reports: {Path(args.output).resolve()}")
            f1 = report["summary"]["onset"]["macro_f1"]
            if report["summary"]["all_failed_cases"]:
                return 3
            if args.min_onset_f1 is not None and (f1 is None or f1 < args.min_onset_f1):
                return 3
        elif args.command == "compare":
            if args.fail_regression is not None and args.fail_regression < 0:
                raise ValueError("regression tolerance must be nonnegative")
            output = Path(args.output)
            if output.exists():
                raise FileExistsError("comparison output already exists")
            report = compare_runs(args.before, args.after, metrics=("onset",) if args.onset_only else ("onset", "onset_offset"))
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
            print(json.dumps(report["metrics"], indent=2))
            delta = report["metrics"]["onset"]["macro_f1_delta"]
            if args.fail_regression is not None and delta is not None and delta < -args.fail_regression:
                return 3
        elif args.command == "verify-run":
            print(json.dumps(verify_run(args.directory), indent=2))
        elif args.command == "demo":
            root = Path(args.output).resolve()
            manifest = generate_fixtures(root / "fixtures")
            for version, degraded in (("DEMO_ORACLE", False), ("DEMO_DEGRADED", True)):
                predictions = demo_predictions(manifest, root / version / "inputs", degraded=degraded)
                evaluate_version(manifest, version=version, output_dir=root / version / "reports",
                                 prediction_dir=predictions, prediction_offset_semantics="key_release", bootstrap_samples=200)
            comparison = compare_runs(root / "DEMO_ORACLE/reports/report.json", root / "DEMO_DEGRADED/reports/report.json")
            (root / "comparison.json").write_text(json.dumps(comparison, indent=2) + "\n")
            print(f"Tester demonstration (not Semitone accuracy): {root}")
            print(json.dumps(comparison["metrics"], indent=2))
    except Exception as exc:
        print(f"PianoBench: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2
    return 0
