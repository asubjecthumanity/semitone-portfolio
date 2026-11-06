"""Verify immutable benchmark inputs and optionally launch MusicBench.

Version 1 supports PCM WAV plus SongTruth JSON or note CSV labels. Structural
checks and provenance are portable; native inference is a separate operation.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import wave

try:
    from .asset_registry import (identifier, load_json, load_json_bytes, sha256_file, source_uri, text, validate_assets)
except ImportError:
    from asset_registry import (identifier, load_json, load_json_bytes, sha256_file, source_uri, text, validate_assets)
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from Tools.PianoModel.event_contracts import load_note_csv, validate_notes, validate_intervals

ONSET_CONVENTIONS = {"sampler_note_on", "acoustic_onset", "reference_midi"}
OFFSET_CONVENTIONS = {"key_release", "acoustic_end"}


def number(value, where):
    try:
        valid = not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value)
    except OverflowError:
        valid = False
    if not valid:
        raise ValueError(f"{where}: expected a finite number")
    return value


def integer(value, where, minimum=0, maximum=None):
    if type(value) is not int or value < minimum or (maximum is not None and value > maximum):
        raise ValueError(f"{where}: invalid integer range")
    return value


def contained_file(root, relative):
    resolved = (root / relative).resolve(strict=True)
    if not resolved.is_relative_to(root) or not resolved.is_file():
        raise ValueError(f"{relative}: asset must be a file inside the dataset root")
    return resolved


def wav_info(path):
    try:
        with wave.open(str(path), "rb") as audio:
            info = dict(sample_rate=audio.getframerate(), channels=audio.getnchannels(), frames=audio.getnframes())
            expected = info["frames"] * info["channels"] * audio.getsampwidth()
            actual = 0
            while chunk := audio.readframes(65_536):
                actual += len(chunk)
            if actual != expected:
                raise ValueError(f"{path}: truncated WAV payload ({actual}/{expected} bytes)")
            return info
    except (wave.Error, EOFError) as error:
        raise ValueError(f"{path}: version 1 requires readable PCM WAV: {error}") from error


def validate_song_truth(truth, duration, offset, annotation, where):
    if not isinstance(truth, dict):
        raise ValueError(f"{where}: expected SongTruth object")
    identifier(truth.get("name"), f"{where}.name")
    text(truth.get("style"), f"{where}.style")
    if number(truth.get("bpm"), f"{where}.bpm") <= 0:
        raise ValueError(f"{where}: BPM must be positive")
    integer(truth.get("beatsPerBar"), f"{where}.beatsPerBar", 1)
    integer(truth.get("keyRoot"), f"{where}.keyRoot", 0, 11)
    if truth.get("keyMode") not in {"major", "minor"} or type(truth.get("reverb")) is not bool:
        raise ValueError(f"{where}: invalid key mode/reverb")
    if abs(number(truth.get("duration"), f"{where}.duration") - duration) > annotation["duration_tolerance"]:
        raise ValueError(f"{where}: truth duration disagrees with WAV")
    notes = truth.get("notes")
    if not isinstance(notes, list):
        raise ValueError(f"{where}.notes: expected a list")
    events = []
    for i, note in enumerate(notes):
        loc = f"{where}.notes[{i}]"
        if not isinstance(note, dict) or note.get("role") not in {"melody", "chords", "bass"}:
            raise ValueError(f"{loc}: invalid note/role")
        integer(note.get("program"), f"{loc}.program", 0, 127)
        events.append((number(note.get("on"), loc) + offset, number(note.get("off"), loc) + offset,
                       note.get("pitch"), note.get("velocity")))
    validate_notes(events, pitch_min=annotation["pitch_min"], pitch_max=annotation["pitch_max"],
                   duration=duration + annotation["duration_tolerance"], context=where)
    drums = truth.get("drums")
    if not isinstance(drums, list):
        raise ValueError(f"{where}.drums: expected a list")
    for hit in drums:
        if not isinstance(hit, dict):
            raise ValueError(f"{where}.drums: expected objects")
        integer(hit.get("gmNote"), f"{where}.gmNote", 0, 127)
        integer(hit.get("velocity"), f"{where}.velocity", 0, 127)
        time = number(hit.get("time"), f"{where}.drum time") + offset
        if not 0 <= time <= duration + annotation["duration_tolerance"]:
            raise ValueError(f"{where}: drum trigger outside audio")
    for key in ["beats", "downbeats"]:
        times = truth.get(key)
        if not isinstance(times, list):
            raise ValueError(f"{where}.{key}: expected a list")
        previous = -1.0
        for t in times:
            mapped = number(t, f"{where}.{key}") + offset
            if not 0 <= mapped <= duration + annotation["duration_tolerance"] or mapped <= previous:
                raise ValueError(f"{where}.{key}: times must be in range and strictly increasing")
            previous = mapped
    chords = truth.get("chords")
    if not isinstance(chords, list):
        raise ValueError(f"{where}.chords: expected a list")
    spans = []
    for chord in chords:
        if not isinstance(chord, dict):
            raise ValueError(f"{where}.chords: expected objects")
        integer(chord.get("root"), f"{where}.chord root", 0, 11)
        text(chord.get("quality"), f"{where}.chord quality")
        text(chord.get("label"), f"{where}.chord label")
        spans.append((number(chord.get("start"), where) + offset, number(chord.get("end"), where) + offset))
    validate_intervals(spans, duration=duration + annotation["duration_tolerance"], context=f"{where}.chords")
    return len(notes)


def verify_manifest(path, *, root=None, split="all", use=None):
    path = Path(path).resolve(strict=True)
    manifest_bytes = path.read_bytes()
    document = load_json_bytes(manifest_bytes, str(path))
    if not isinstance(document, dict) or type(document.get("schema_version")) is not int or document["schema_version"] != 1:
        raise ValueError("unsupported dataset manifest schema_version (expected integer 1)")
    identifier(document.get("dataset_id"), "dataset_id")
    text(document.get("dataset_version"), "dataset_version")
    assets = validate_assets(document.get("assets"))
    performances = document.get("performances")
    if not isinstance(performances, list) or not performances:
        raise ValueError("performances: expected a nonempty list")
    if split not in {"dev", "test", "all"}:
        raise ValueError("split must be dev, test or all")
    by_id, groups = {}, {}
    for performance in performances:
        if not isinstance(performance, dict):
            raise ValueError("performance: expected an object")
        ident = identifier(performance.get("performance_id"), "performance_id")
        if ident in by_id:
            raise ValueError(f"duplicate performance_id {ident}")
        assigned = performance.get("split")
        if assigned not in {"dev", "test"}:
            raise ValueError(f"{ident}: invalid split")
        for key in ["composition_id", "session_id", "lineage_id"]:
            group = identifier(performance.get(key), f"{ident}.{key}")
            previous = groups.setdefault((key, group), assigned)
            if previous != assigned:
                raise ValueError(f"{ident}: {key} {group!r} crosses dev/test splits")
        parent = performance.get("parent_performance_id")
        if parent is not None:
            identifier(parent, f"{ident}.parent_performance_id")
        instruments = performance.get("instruments")
        if not isinstance(instruments, list) or not instruments:
            raise ValueError(f"{ident}: instruments must be declared")
        for value in instruments:
            text(value, f"{ident}.instruments")
        text(performance.get("microphone"), f"{ident}.microphone")
        transforms = performance.get("transforms")
        if not isinstance(transforms, list) or (parent is not None and not transforms):
            raise ValueError(f"{ident}: declare transformations for every derivative")
        for transform in transforms:
            if not isinstance(transform, dict) or not isinstance(transform.get("parameters"), dict):
                raise ValueError(f"{ident}: transforms require name and parameter object")
            text(transform.get("name"), f"{ident}.transform name")
        audio = assets.get(identifier(performance.get("audio_asset"), f"{ident}.audio_asset"))
        truth = assets.get(identifier(performance.get("truth_asset"), f"{ident}.truth_asset"))
        if audio is None or audio["kind"] != "audio" or truth is None:
            raise ValueError(f"{ident}: unresolved/wrong-kind audio or truth asset")
        previous = groups.setdefault(("audio_sha256", audio["sha256"]), assigned)
        if previous != assigned:
            raise ValueError(f"{ident}: identical audio bytes cross dev/test splits")
        annotation = performance.get("annotation")
        if not isinstance(annotation, dict) or annotation.get("format") not in {"song_truth_v1", "note_csv_v1"}:
            raise ValueError(f"{ident}: unsupported annotation format")
        expected_kind = "song_truth" if annotation["format"] == "song_truth_v1" else "notes_csv"
        if truth["kind"] != expected_kind:
            raise ValueError(f"{ident}: annotation format and asset kind disagree")
        if annotation.get("onset") not in ONSET_CONVENTIONS or annotation.get("offset") not in OFFSET_CONVENTIONS:
            raise ValueError(f"{ident}: declare onset/offset semantics")
        source_uri(annotation.get("source_uri"), f"{ident}.annotation.source_uri", unknown=True)
        number(annotation.get("timing_offset_seconds"), f"{ident}.timing_offset_seconds")
        low = integer(annotation.get("pitch_min"), f"{ident}.pitch_min", 0, 127)
        high = integer(annotation.get("pitch_max"), f"{ident}.pitch_max", 0, 127)
        if low > high:
            raise ValueError(f"{ident}: pitch_min exceeds pitch_max")
        info = performance.get("audio")
        if not isinstance(info, dict) or set(info) != {"sample_rate", "channels", "frames"}:
            raise ValueError(f"{ident}: declare sample_rate, channels and frames")
        integer(info["sample_rate"], f"{ident}.sample_rate", 1)
        integer(info["channels"], f"{ident}.channels", 1)
        integer(info["frames"], f"{ident}.frames", 1)
        by_id[ident] = performance
    # Parent relations must resolve and preserve lineage; cycles cannot be
    # hidden by inventing fresh IDs for derivative files.
    for ident, p in by_id.items():
        seen = {ident}
        parent = p.get("parent_performance_id")
        while parent is not None:
            if parent not in by_id or parent in seen:
                raise ValueError(f"{ident}: missing/cyclic parent {parent!r}")
            ancestor = by_id[parent]
            if any(ancestor[key] != p[key] for key in ["lineage_id", "composition_id", "session_id"]):
                raise ValueError(f"{ident}: derivative changed its source group IDs")
            seen.add(parent)
            parent = ancestor.get("parent_performance_id")
    selected = [p for p in performances if split == "all" or p["split"] == split]
    if not selected:
        raise ValueError(f"no performances in split {split}")
    needed = {p[key] for p in selected for key in ["audio_asset", "truth_asset"]}
    validate_assets([assets[key] for key in sorted(needed)], use=use)
    base = Path(root).resolve(strict=True) if root is not None else path.parent
    files = {}
    for ident in needed:
        file = contained_file(base, assets[ident]["path"])
        if sha256_file(file) != assets[ident]["sha256"]:
            raise ValueError(f"{ident}: SHA-256 mismatch for {assets[ident]['path']}")
        files[ident] = file
    summaries = []
    for p in selected:
        ident = p["performance_id"]
        actual = wav_info(files[p["audio_asset"]])
        if actual != p["audio"]:
            raise ValueError(f"{ident}: declared audio header differs from WAV")
        duration = actual["frames"] / actual["sample_rate"]
        annotation = dict(p["annotation"], duration_tolerance=1 / actual["sample_rate"])
        offset = annotation["timing_offset_seconds"]
        if annotation["format"] == "song_truth_v1":
            notes = validate_song_truth(load_json(files[p["truth_asset"]]), duration, offset, annotation, ident)
        else:
            events = load_note_csv(files[p["truth_asset"]], pitch_min=annotation["pitch_min"], pitch_max=annotation["pitch_max"])
            mapped = [(on + offset, off + offset, pitch, velocity) for on, off, pitch, velocity in events]
            validate_notes(mapped, pitch_min=annotation["pitch_min"], pitch_max=annotation["pitch_max"], duration=duration + annotation["duration_tolerance"], context=ident)
            notes = len(events)
        summaries.append(dict(performance_id=ident, split=p["split"], session_id=p["session_id"],
                              composition_id=p["composition_id"], lineage_id=p["lineage_id"],
                              parent_performance_id=p.get("parent_performance_id"), transforms=p["transforms"],
                              audio_sha256=assets[p["audio_asset"]]["sha256"], truth_sha256=assets[p["truth_asset"]]["sha256"],
                              duration_seconds=duration, notes=notes, annotation=p["annotation"]))
    metadata = dict(status="verified", schema_version=1, dataset_id=document["dataset_id"],
                    dataset_version=document["dataset_version"], manifest_sha256=hashlib.sha256(manifest_bytes).hexdigest(),
                    split=split, intended_use=use, performances=summaries,
                    independent_sessions=len({p["session_id"] for p in selected}),
                    independent_lineages=len({p["lineage_id"] for p in selected}))
    return metadata, selected, assets, files


def run_benchmark(verified, *, binary, split, sweep=None):
    metadata, performances, assets, files = verified
    if sweep is not None and split != "dev":
        raise ValueError("parameter sweeps require --set dev")
    binary = Path(binary).resolve(strict=True)
    digest = sha256_file(binary)
    with tempfile.TemporaryDirectory(prefix="semitone-verified-") as temporary:
        folder = Path(temporary)
        songs = folder / "songs"
        songs.mkdir()
        names, copies = set(), []
        for p in performances:
            annotation = p["annotation"]
            if (annotation["format"] != "song_truth_v1" or annotation["timing_offset_seconds"] != 0 or
                    annotation["onset"] != "sampler_note_on" or annotation["offset"] != "key_release"):
                raise ValueError("native MusicBench launch requires zero-offset scheduled SongTruth labels")
            truth = load_json(files[p["truth_asset"]])
            name = truth["name"]
            if name.casefold() in names or not name.startswith(p["split"]):
                raise ValueError(f"{p['performance_id']}: native song name must be unique and start with its split")
            names.add(name.casefold())
            for key, suffix in [("audio_asset", ".wav"), ("truth_asset", ".json")]:
                ident = p[key]
                destination = songs / (name + suffix)
                shutil.copyfile(files[ident], destination)
                if sha256_file(destination) != assets[ident]["sha256"]:
                    raise ValueError(f"{ident}: source changed while making benchmark snapshot")
                copies.append((destination, assets[ident]["sha256"]))
        report_path = folder / "native-report.json"
        arguments = [str(binary), str(songs), "--set", split, "--json", str(report_path)]
        if sweep is not None:
            arguments += ["--sweep", sweep]
        result = subprocess.run(arguments, stdout=sys.stderr, stderr=sys.stderr, check=False)
        if result.returncode:
            return result.returncode, None
        if sha256_file(binary) != digest or any(sha256_file(path) != expected for path, expected in copies):
            raise ValueError("binary or dataset snapshot changed during the benchmark")
        report = load_json(report_path)
        if not isinstance(report, dict):
            raise ValueError("native benchmark did not produce a JSON report object")
        report["verified_dataset"] = dict(metadata, benchmark_binary_sha256=digest)
        return 0, report


def write_report(path, report):
    path = Path(path).absolute()
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as out:
            temporary = Path(out.name)
            json.dump(report, out, indent=2, sort_keys=True, allow_nan=False)
            out.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest")
    parser.add_argument("--root", help="asset root; default is the manifest's directory")
    parser.add_argument("--set", choices=["dev", "test", "all"], default="all")
    parser.add_argument("--use", choices=["local_evaluation", "ci", "redistribution", "training"], default="local_evaluation")
    parser.add_argument("--bench", help="optional native MusicBench executable")
    parser.add_argument("--sweep", choices=["notes", "voices", "all"])
    parser.add_argument("--json", help="write the verified report atomically")
    args = parser.parse_args(argv)
    if args.sweep and (not args.bench or args.set != "dev"):
        parser.error("sweeps require --bench and --set dev")
    if args.bench and not args.json:
        parser.error("--bench requires --json so prediction results retain input provenance")
    try:
        verified = verify_manifest(args.manifest, root=args.root, split=args.set, use=args.use)
        if args.json:
            base = Path(args.root).resolve() if args.root else Path(args.manifest).resolve().parent
            protected = {Path(args.manifest).resolve()} | {(base / asset["path"]).resolve() for asset in verified[2].values()}
            if args.bench:
                protected.add(Path(args.bench).resolve())
            if Path(args.json).resolve() in protected:
                raise ValueError("report output must not overwrite the manifest, source assets or executable")
        if args.bench:
            code, report = run_benchmark(verified, binary=args.bench, split=args.set, sweep=args.sweep)
            if code:
                return code if code > 0 else 1
        else:
            report = verified[0]
        if args.json:
            write_report(args.json, report)
    except (OSError, ValueError, TypeError) as error:
        parser.error(str(error))
    print(json.dumps(report, sort_keys=True, allow_nan=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
