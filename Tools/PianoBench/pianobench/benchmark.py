"""Public version evaluator, machine-readable reports, and paired regressions."""
from dataclasses import asdict
from pathlib import Path
from collections import defaultdict
from datetime import datetime, timezone
import csv
import importlib.metadata
import hashlib
import json
import platform
import time
import shutil
import numpy as np
from .io import canonical_hash, load_performance, sha256, write_performance
from .models import Performance
from .scoring import ScoreConfig, evaluate_performance, counts_score
from .manifest import load_manifest
from .difficulty import LEVELS
from .integrity import snapshot_cases, verify_inputs, write_receipt
from .version import TESTER_VERSION

def _tester_hash():
    return canonical_hash([(p.name, sha256(p)) for p in sorted(Path(__file__).parent.glob("*.py"))])

def _metric(row, name):
    value = row["scores"].get(name)
    return value["f1"] if value else None

def _bootstrap(rows, metric, n=2000, seed=20261002):
    rows = [r for r in rows if _metric(r, metric) is not None]
    groups = defaultdict(list)
    for r in rows:
        groups[r["piece"]["group_id"]].append(_metric(r, metric))
    if len(groups) < 2 or n <= 0:
        return None
    arrays = list(groups.values())
    means, lengths = np.asarray([sum(a) for a in arrays]), np.asarray([len(a) for a in arrays])
    rng = np.random.default_rng(seed)
    estimates = []
    for _ in range(n):
        draw = rng.integers(0, len(arrays), size=len(arrays))
        estimates.append(float(means[draw].sum() / lengths[draw].sum()))
    return [float(x) for x in np.percentile(estimates, [2.5, 97.5])]

def _aggregate(rows, bootstrap_samples=2000):
    out = {"performances": len(rows), "failed": sum(r["status"] != "ok" for r in rows),
           "independent_groups": len({r["piece"]["group_id"] for r in rows})}
    for metric in ("onset", "onset_offset"):
        selected = [r for r in rows if _metric(r, metric) is not None]
        counts = {k: sum(r["scores"][metric][k] for r in selected) for k in ("tp", "fp", "fn")}
        out[metric] = {"scored_performances": len(selected),
                       "macro_f1": float(np.mean([_metric(r, metric) for r in selected])) if selected else None,
                       "macro_f1_cluster_bootstrap_95": _bootstrap(selected, metric, bootstrap_samples),
                       "micro": counts_score(**counts)}
    return out

def _summarize(rows, bootstrap_samples):
    positive = [r for r in rows if r["piece"]["difficulty_level"] > 0]
    summary = _aggregate(positive, bootstrap_samples)
    summary["all_cases"] = len(rows)
    summary["all_failed_cases"] = sum(r["status"] != "ok" for r in rows)
    summary["native_validity_gate_rejections"] = sum(r["prediction_metadata"].get("looks_valid") is False for r in rows)
    summary["by_difficulty"] = {str(level): _aggregate([r for r in positive if r["piece"]["difficulty_level"] == level], bootstrap_samples)
                                for level in range(1, 6)}
    summary["missing_difficulty_levels"] = [l for l in range(1, 6) if not summary["by_difficulty"][str(l)]["performances"]]
    present = [g["onset"]["macro_f1"] for g in summary["by_difficulty"].values() if g["onset"]["macro_f1"] is not None]
    summary["equal_weight_present_difficulty_macro_f1"] = float(np.mean(present)) if present else None
    summary["by_dataset"] = {d: _aggregate([r for r in positive if r["piece"]["dataset"] == d], bootstrap_samples)
                             for d in sorted({r["piece"]["dataset"] for r in rows})}
    summary["by_recording_kind"] = {d: _aggregate([r for r in positive if r["piece"]["kind"] == d], bootstrap_samples)
                                    for d in sorted({r["piece"]["kind"] for r in rows})}
    summary["by_split"] = {d: _aggregate([r for r in positive if r["piece"]["split"] == d], bootstrap_samples)
                           for d in sorted({r["piece"]["split"] for r in rows})}
    summary["by_tag"] = {t: _aggregate([r for r in positive if t in r["piece"].get("tags", [])], 0)
                          for t in sorted({t for r in rows for t in r["piece"].get("tags", [])})}
    window_counts = defaultdict(lambda: {"tp": 0, "fp": 0, "fn": 0, "windows": 0})
    for r in positive:
        for w in r["scores"]["windows"]:
            group = window_counts[str(w["complexity"]["level"])]
            for key in ("tp", "fp", "fn"):
                group[key] += w["onset"][key]
            group["windows"] += 1
    summary["by_window_complexity"] = {level: {"windows": c["windows"], "onset": counts_score(c["tp"], c["fp"], c["fn"])}
                                       for level, c in sorted(window_counts.items())}
    negative = [r for r in rows if r["piece"]["difficulty_level"] == 0]
    successful_negative = [r for r in negative if r["status"] == "ok"]
    seconds = sum(r["piece"]["duration_seconds"] for r in successful_negative)
    false = sum(r["scores"]["negative_control"]["false_notes"] for r in successful_negative)
    summary["negative_controls"] = {"cases": len(negative), "failed": sum(r["status"] != "ok" for r in negative),
                                    "scored_cases": len(successful_negative), "seconds": seconds, "false_notes": false,
                                    "false_notes_per_minute": false * 60 / seconds if seconds else None}
    runtime = [r for r in rows if r["runtime_seconds"] is not None and r["status"] == "ok"]
    duration = sum(r["piece"]["duration_seconds"] for r in runtime)
    summary["runtime"] = {"timed_cases": len(runtime), "total_seconds": sum(r["runtime_seconds"] for r in runtime),
                          "pooled_real_time_factor": sum(r["runtime_seconds"] for r in runtime) / duration if duration else None}
    return summary

def _save_report(report, directory):
    directory = Path(directory)
    (directory / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    fields = ["id", "dataset", "difficulty_level", "kind", "status", "onset_precision", "onset_recall", "onset_f1",
              "offset_f1", "missed", "extra", "onset_mae_ms", "velocity_mae", "false_notes_per_minute", "real_time_factor", "error"]
    with (directory / "pieces.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for r in report["pieces"]:
            s, p = r["scores"], r["piece"]
            writer.writerow({"id": p["id"], "dataset": p["dataset"], "difficulty_level": p["difficulty_level"],
                             "kind": p["kind"], "status": r["status"],
                             "onset_precision": s["onset"]["precision"], "onset_recall": s["onset"]["recall"],
                             "onset_f1": s["onset"]["f1"], "offset_f1": _metric(r, "onset_offset"),
                             "missed": s["onset"]["fn"], "extra": s["onset"]["fp"],
                             "onset_mae_ms": s["onset_timing_ms"]["mean"],
                             "velocity_mae": s["velocity_error_midi"]["mean"] if s["velocity_error_midi"] else None,
                             "false_notes_per_minute": s["negative_control"]["false_notes_per_minute"] if s["negative_control"] else None,
                             "real_time_factor": r["runtime_seconds"] / p["duration_seconds"] if r["runtime_seconds"] is not None else None,
                             "error": r.get("error")})
    def percent(value):
        return "unavailable" if value is None else f"{value * 100:.2f}%"
    s = report["summary"]
    lines = [f"# PianoBench: {report['version']}", "", "This report evaluates performance events from the declared engine/export stage.", "",
             f"Onset macro F1: **{percent(s['onset']['macro_f1'])}**. Onset/offset macro F1: **{percent(s['onset_offset']['macro_f1'])}**.",
             f"Completed {s['all_cases'] - s['all_failed_cases']}/{s['all_cases']} cases. Failed positive cases count as missed notes.", "",
             "| Complexity tier | Cases | Failed | Onset F1 | Onset/offset F1 |", "|---|---:|---:|---:|---:|"]
    for level in range(1, 6):
        g = s["by_difficulty"][str(level)]
        lines.append(f"| {level}: {LEVELS[level]} | {g['performances']} | {g['failed']} | {percent(g['onset']['macro_f1'])} | {percent(g['onset_offset']['macro_f1'])} |")
    lines += ["", "Difficulty tiers are reference-derived transcription complexity, not formal pianist grades.",
              "A 50 ms onset tolerance and 50 cents pitch tolerance are used by default. Offset tolerance is max(50 ms, 20% of reference duration).",
              "Undeclared offset semantics withhold the headline duration score. The JSON contains separate diagnostic target views.",
              "Negative controls are reported as false notes per minute and excluded from note F1.",
              "95% confidence intervals resample composition/performance groups; fewer than two groups cannot estimate uncertainty.",
              "Real recordings and synthetic fixtures are separated in report.json; toy renders only verify plumbing.", ""]
    if report["imported_predictions_without_audio_hash"]:
        lines += [f"{report['imported_predictions_without_audio_hash']} successful imported predictions lack a verified audio association. Saving/replaying them does not establish one.", ""]
    lines += ["Pinned inputs are copied into this run. Use replay_manifest.json with this run's predictions to reproduce scoring; verify-run checks the saved bytes.", ""]
    if s["missing_difficulty_levels"]:
        lines += [f"Missing tiers: {s['missing_difficulty_levels']}. This run does not cover the full difficulty ladder.", ""]
    if s["native_validity_gate_rejections"]:
        lines += [f"Native validity gate rejected {s['native_validity_gate_rejections']} outputs. This report scores raw engine output; the app's preview fallback needs a separate accepted-output run.", ""]
    (directory / "report.md").write_text("\n".join(lines))

def evaluate_version(manifest_path, *, version, output_dir, prediction_dir=None,
                     transcriber=None, config=None, prediction_offset_semantics=None,
                     version_metadata=None, allow_unverified=False, bootstrap_samples=2000):
    """Evaluate an entire version with no interface.

    Supply either predictions named <piece-id>.json/.mid/.csv, or a callable
    transcriber(audio_path) returning Performance. Missing/failed predictions
    receive zero recall; invalid ground truth stops the run before scoring.
    """
    if not version or (prediction_dir is None) == (transcriber is None):
        raise ValueError("supply a version and exactly one prediction_dir or transcriber")
    if type(bootstrap_samples) is not int or bootstrap_samples < 0:
        raise ValueError("bootstrap_samples must be a nonnegative integer")
    cfg = config or ScoreConfig()
    tester_source_hash = _tester_hash()
    manifest, cases, fingerprint = load_manifest(manifest_path, allow_unverified=allow_unverified)
    directory = Path(output_dir).resolve()
    if directory.exists() and any(directory.iterdir()):
        raise FileExistsError("output directory is not empty; use a new directory for each run")
    (directory / "predictions").mkdir(parents=True, exist_ok=True)
    cases = snapshot_cases(manifest, cases, directory)
    replay_digest = sha256(directory / "replay_manifest.json")
    rows = []
    for piece, truth in cases:
        verify_inputs([(piece, truth)])
        start, elapsed, error, source_identity_verified = time.perf_counter(), None, None, False
        prediction_file, prediction_digest, imported_file, imported_digest = None, None, None, None
        try:
            if transcriber is not None:
                prediction = transcriber(Path(piece["audio"]))
                elapsed = time.perf_counter() - start
                if not isinstance(prediction, Performance):
                    raise TypeError("transcriber must return Performance")
            else:
                paths = [Path(prediction_dir) / (piece["id"] + ext) for ext in (".json", ".mid", ".midi", ".csv")]
                found = [p for p in paths if p.is_file()]
                if len(found) != 1:
                    raise ValueError(f"expected exactly one prediction for {piece['id']}; found {len(found)}")
                imported = directory / "imported_predictions" / (piece["id"] + found[0].suffix)
                imported.parent.mkdir(exist_ok=True)
                shutil.copyfile(found[0], imported)
                imported_file, imported_digest = imported.relative_to(directory).as_posix(), sha256(imported)
                prediction = load_performance(imported, offset_semantics=prediction_offset_semantics)
                if sha256(imported) != imported_digest:
                    raise ValueError("imported prediction changed while parsing")
            if prediction_offset_semantics:
                if prediction.offset_semantics not in ("unspecified", prediction_offset_semantics):
                    raise ValueError("prediction offset semantics conflict")
                prediction.offset_semantics = prediction_offset_semantics
            identity = prediction.metadata.get("audio_sha256")
            if identity and identity != piece["audio_sha256"]:
                raise ValueError("prediction belongs to different audio bytes")
            source_identity_verified = (transcriber is not None or identity == piece["audio_sha256"])
            if transcriber is None and prediction.metadata.get("source_audio_identity_verified") is False:
                source_identity_verified = False
            if prediction.duration is not None and abs(prediction.duration - piece["duration_seconds"]) > .02:
                raise ValueError("prediction duration differs from original audio")
            scores = evaluate_performance(truth, prediction, config=cfg, duration_seconds=piece["duration_seconds"])
            elapsed = prediction.metadata.get("subprocess_wall_seconds", prediction.metadata.get("total_seconds", elapsed))
            if elapsed is not None and (not np.isfinite(elapsed) or elapsed < 0):
                raise ValueError("invalid recorded runtime")
            status = "ok"
            prediction.metadata.update({"evaluation_audio_sha256": piece["audio_sha256"], "version": version,
                                        "source_audio_identity_verified": source_identity_verified})
            if source_identity_verified:
                prediction.metadata["audio_sha256"] = piece["audio_sha256"]
            prediction_file = "predictions/" + piece["id"] + ".json"
            write_performance(prediction, directory / prediction_file)
            prediction_digest = sha256(directory / prediction_file)
        except Exception as exc:
            status, error = "failed", f"{type(exc).__name__}: {exc}"
            # A failed transcriber has no usable notes, not a perfect silent result.
            prediction = Performance([], duration=piece["duration_seconds"],
                                     offset_semantics=prediction_offset_semantics or "unspecified")
            scores = evaluate_performance(truth, prediction, config=cfg, duration_seconds=piece["duration_seconds"])
            elapsed = None
        # Input/artifact drift invalidates the run, not the model's note recall.
        verify_inputs([(piece, truth)])
        rows.append({"piece": piece, "status": status, "error": error, "runtime_seconds": elapsed,
                     "source_audio_identity_verified": source_identity_verified,
                     "prediction_file": prediction_file, "prediction_sha256": prediction_digest,
                     "imported_prediction_file": imported_file, "imported_prediction_sha256": imported_digest,
                     "reference_metadata": truth.metadata,
                     "prediction_metadata": prediction.metadata, "scores": scores})
        # Checkpoint after every expensive native file; no restart silently mixes caches.
        (directory / "progress.json").write_text(json.dumps({"version": version, "completed": len(rows),
                                                            "total": len(cases), "pieces": rows}, allow_nan=False))
    # Infer a uniform successful prediction convention to include failed cases
    # in duration scoring, including runs imported from self-describing JSON.
    successful_conventions = {r["scores"]["offset_semantics"]["prediction"] for r in rows if r["status"] == "ok"}
    declared_convention = prediction_offset_semantics or getattr(transcriber, "metadata", {}).get("offset_semantics")
    if declared_convention is None and len(successful_conventions) == 1:
        declared_convention = next(iter(successful_conventions))
    if declared_convention and declared_convention != "unspecified":
        for row, (_, truth) in zip(rows, cases):
            if row["status"] == "failed":
                empty = Performance([], duration=truth.duration, offset_semantics=declared_convention)
                row["scores"] = evaluate_performance(truth, empty, config=cfg, duration_seconds=truth.duration)
    dependencies = {}
    for name in ("numpy", "scipy", "mido", "soundfile", "semitone-pianobench"):
        try:
            dependencies[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            dependencies[name] = "not-installed"
    if _tester_hash() != tester_source_hash:
        raise ValueError("tester sources changed during evaluation")
    report = {"schema_version": 1, "tester_version": TESTER_VERSION, "tester_sources_sha256": tester_source_hash, "version": version,
              "created_utc": datetime.now(timezone.utc).isoformat(), "suite_name": manifest.get("suite_name"),
              "manifest_sha256": hashlib.sha256(manifest.source_bytes).hexdigest(), "dataset_fingerprint": fingerprint,
              "input_policy": "verified-run-snapshot-v1", "replay_manifest": "replay_manifest.json",
              "replay_manifest_sha256": replay_digest,
              "score_config": asdict(cfg), "score_config_sha256": canonical_hash(asdict(cfg)),
              "version_metadata": {**(version_metadata or {}), **getattr(transcriber, "metadata", {})},
              "prediction_offset_semantics": declared_convention,
              "imported_predictions_without_audio_hash": sum(r["status"] == "ok" and not r["source_audio_identity_verified"] for r in rows),
              "environment": {"python": platform.python_version(), "platform": platform.platform(), "dependencies": dependencies},
              "exploratory_unverified_alignment": any(p["alignment"].get("status") not in ("verified", "dataset_provided") for p, _ in cases),
              "summary": _summarize(rows, bootstrap_samples), "pieces": rows}
    verify_inputs(cases)
    if hasattr(transcriber, "verify_artifacts"):
        transcriber.verify_artifacts()
    _save_report(report, directory)
    write_receipt(directory)
    return report

def compare_runs(before, after, *, bootstrap_samples=2000, seed=20261002, metrics=("onset", "onset_offset")):
    """Paired version delta, refusing changed inputs/tolerances/offset contracts."""
    def load(value):
        from .io import load_json
        return value if isinstance(value, dict) else load_json(value)
    before, after = load(before), load(after)
    if type(bootstrap_samples) is not int or bootstrap_samples < 0:
        raise ValueError("bootstrap_samples must be a nonnegative integer")
    if tuple(metrics) not in (("onset",), ("onset", "onset_offset")):
        raise ValueError("choose onset or onset plus onset_offset comparison metrics")
    for key in ("dataset_fingerprint", "score_config_sha256", "tester_version", "tester_sources_sha256"):
        if before[key] != after[key]:
            raise ValueError(f"cannot compare runs with different {key}")
    if "onset_offset" in metrics and before.get("prediction_offset_semantics") != after.get("prediction_offset_semantics"):
        raise ValueError("cannot compare runs with different prediction offset conventions")
    a = {r["piece"]["id"]: r for r in before["pieces"]}
    b = {r["piece"]["id"]: r for r in after["pieces"]}
    if a.keys() != b.keys():
        raise ValueError("paired comparison requires exactly the same pieces")
    out = {"schema_version": 1, "before": before["version"], "after": after["version"], "metrics": {}, "pieces": [],
           "compared_metrics": list(metrics)}
    for name in metrics:
        groups, deltas = defaultdict(list), []
        for identity in sorted(a):
            x, y = _metric(a[identity], name), _metric(b[identity], name)
            if (x is None) != (y is None):
                raise ValueError(f"{name} availability differs for {identity}; declare the same prediction offset convention")
            if x is not None:
                groups[a[identity]["piece"]["group_id"]].append(y - x)
                deltas.append(y - x)
        ci = None
        if len(groups) >= 2 and bootstrap_samples:
            arrays = list(groups.values())
            sums = np.asarray([sum(g) for g in arrays])
            counts = np.asarray([len(g) for g in arrays])
            rng, draws = np.random.default_rng(seed), []
            for _ in range(bootstrap_samples):
                ix = rng.integers(0, len(arrays), len(arrays))
                draws.append(sums[ix].sum() / counts[ix].sum())
            ci = [float(v) for v in np.percentile(draws, [2.5, 97.5])]
        out["metrics"][name] = {"paired_performances": len(deltas), "independent_groups": len(groups),
                                "macro_f1_delta": float(np.mean(deltas)) if deltas else None,
                                "paired_cluster_bootstrap_95": ci}
    for identity in sorted(a):
        x, y = _metric(a[identity], "onset"), _metric(b[identity], "onset")
        out["pieces"].append({"id": identity, "difficulty_level": a[identity]["piece"]["difficulty_level"],
                              "onset_f1_delta": y - x if x is not None else None,
                              "before_status": a[identity]["status"], "after_status": b[identity]["status"]})
    out["by_difficulty"] = {}
    for level in range(1, 6):
        values = [r["onset_f1_delta"] for r in out["pieces"] if r["difficulty_level"] == level and r["onset_f1_delta"] is not None]
        out["by_difficulty"][str(level)] = {"paired_performances": len(values),
                                           "macro_f1_delta": float(np.mean(values)) if values else None}
    out["negative_controls"] = {"before": before["summary"]["negative_controls"], "after": after["summary"]["negative_controls"]}
    return out
