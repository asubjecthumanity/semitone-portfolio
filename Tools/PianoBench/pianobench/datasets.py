"""Build small, frozen manifests from local official piano dataset releases."""
from pathlib import Path
import csv
import json
import re
import soundfile as sf
from .io import canonical_hash, load_performance, sha256
from .difficulty import complexity, POLICY

SOURCES = {
    "MAESTRO": {"release": "3.0.0", "url": "https://magenta.withgoogle.com/datasets/maestro",
                "terms": "CC BY-NC-SA 4.0", "training_overlap": "Many piano checkpoints trained on MAESTRO; verify exact checkpoint lineage."},
    "SMD": {"release": "2", "url": "https://www.audiolabs-erlangen.de/resources/MIR/SMD/midi",
            "terms": "CC BY-NC-SA 3.0", "training_overlap": "Check checkpoint lineage; v2 preserves pedal controllers."},
    "MAPS": {"release": "2010", "url": "https://adasp.telecom-paris.fr/resources/2010-07-08-maps-database/",
             "terms": "CC BY-NC-SA 2.0 France", "training_overlap": "Check checkpoint lineage; compositions recur across piano settings."},
    "CUSTOM": {"release": "user-supplied", "url": None, "terms": "Record asset-specific rights.",
               "training_overlap": "Record prior training or tuning exposure."},
}

def make_piece(audio, reference, *, dataset, piece_id, split, group_id, kind,
               level=None, tags=None, alignment_status="dataset_provided"):
    audio, reference = Path(audio).resolve(), Path(reference).resolve()
    truth = load_performance(reference, offset_semantics="key_release")
    info = sf.info(str(audio))
    features = complexity(truth.notes)
    return {"id": piece_id, "dataset": dataset, "dataset_release": SOURCES[dataset]["release"],
            "audio": str(audio), "reference": str(reference), "audio_sha256": sha256(audio),
            "reference_sha256": sha256(reference), "duration_seconds": info.duration,
            "sample_rate": info.samplerate, "channels": info.channels,
            "split": split, "group_id": group_id, "kind": kind,
            "difficulty_level": features["level"] if level is None else level,
            "difficulty_source": POLICY if level is None else "declared fixture/manual tier",
            "complexity": features, "tags": tags or [], "reference_offset_semantics": "key_release",
            "alignment": {"offset_seconds": 0, "status": alignment_status,
                          "basis": "Official paired dataset timestamps" if alignment_status == "dataset_provided" else "User must measure before official evaluation"},
            "source_url": SOURCES[dataset]["url"], "terms": SOURCES[dataset]["terms"]}

def _select(candidates, limit, balanced):
    # Stable selection by IDs; never select based on predictions or their scores.
    candidates = sorted(candidates, key=lambda p: canonical_hash(p["id"]))
    if not balanced:
        return candidates[:limit] if limit else candidates
    buckets = {level: [p for p in candidates if p["difficulty_level"] == level] for level in range(6)}
    selected = []
    while any(buckets.values()) and (not limit or len(selected) < limit):
        for level in range(6):
            if buckets[level] and (not limit or len(selected) < limit):
                selected.append(buckets[level].pop(0))
    return selected

def write_manifest(pieces, output, suite_name, *, sources=None, notes=None):
    if not pieces:
        raise ValueError("no paired audio/performance-MIDI files found")
    output = Path(output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    value = {"schema_version": 1, "suite_name": suite_name, "complexity_policy": POLICY,
             "sources": sources or {}, "notes": notes or [], "pieces": pieces}
    output.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")
    return output

def prepare_maestro(root, output, *, split="test", limit=25, balanced=True):
    root = Path(root).resolve()
    candidates = sorted(root.glob("**/maestro-v3.0.0.csv"))
    if len(candidates) != 1:
        raise ValueError("root must contain exactly one official maestro-v3.0.0.csv")
    base = candidates[0].parent
    pieces, missing = [], 0
    with candidates[0].open(newline="") as stream:
        for row in csv.DictReader(stream):
            if row["split"] != split:
                continue
            audio, midi = base / row["audio_filename"], base / row["midi_filename"]
            if not audio.is_file() or not midi.is_file():
                missing += 1
                continue
            stem = Path(row["midi_filename"]).stem
            piece = make_piece(audio, midi, dataset="MAESTRO", piece_id="maestro-" + stem,
                               split=split, group_id=row["canonical_composer"] + "::" + row["canonical_title"],
                               kind="real", tags=[row["canonical_composer"]])
            piece["title"] = row["canonical_title"]
            pieces.append(piece)
    return write_manifest(_select(pieces, limit, balanced), output, f"maestro-v3-{split}",
                          sources={"MAESTRO": SOURCES["MAESTRO"]},
                          notes=[f"{missing} split entries absent locally. Official splits preserved.",
                                 "A balanced subset is a diagnostic slice, not the complete official test score."])

def prepare_paired(root, output, *, dataset="SMD", split="test", limit=25, balanced=True):
    root = Path(root).resolve()
    midis = {}
    for path in sorted(root.rglob("*")):
        if path.suffix.lower() in (".mid", ".midi"):
            if path.stem in midis and sha256(path) != sha256(midis[path.stem]):
                raise ValueError(f"ambiguous MIDI versions for {path.stem}; use one corrected release")
            midis[path.stem] = path
    audio_by_stem = {}
    for path in sorted(p for p in root.rglob("*") if p.suffix.lower() == ".wav"):
        if dataset == "SMD" and ("midi_wav" in str(path).lower() or "synth" in str(path).lower()):
            continue
        if path.stem in midis:
            audio_by_stem.setdefault(path.stem, []).append(path)
    pieces = []
    for stem, choices in audio_by_stem.items():
        # SMD offers original stereo WAV and a mono conversion of the same take.
        # Select one performance view, preferring the largest sample rate/channel count.
        audio = max(choices, key=lambda p: (sf.info(str(p)).samplerate, sf.info(str(p)).channels))
        if dataset == "SMD":
            group = re.sub(r"_\d{3}_\d{8}-SMD$", "", stem)
            kind, tags = "real", [stem.split("_")[0]]
        elif dataset == "MAPS":
            setting = stem.rsplit("_", 1)[-1]
            group = stem.rsplit("_", 1)[0]
            kind = "real" if setting in ("ENSTDkCl", "ENSTDkAm") else "synthetic_sampled"
            tags = [setting, "MAPS-" + stem.split("_")[1] if "_" in stem else "MAPS"]
        else:
            group, kind, tags = stem, "real", ["custom"]
        pieces.append(make_piece(audio, midis[stem], dataset=dataset, piece_id=dataset.lower() + "-" + stem,
                                 split=split, group_id=group, kind=kind, tags=tags,
                                 alignment_status="unverified" if dataset == "CUSTOM" else "dataset_provided"))
    return write_manifest(_select(pieces, limit, balanced), output, f"{dataset.lower()}-{split}",
                          sources={dataset: SOURCES[dataset]}, notes=[
                              "Composition groups keep repeated interpretations/renderers together.",
                              "Dataset timestamps may retain physical piano/acoustic delays; independently audit alignment."])

def combine_manifests(paths, output, *, allow_unverified=False):
    """Combine frozen suites, preserving absolute file paths and original splits."""
    from .manifest import load_manifest
    pieces, sources, seen = [], {}, set()
    for path in paths:
        raw, cases, _ = load_manifest(path, allow_unverified=allow_unverified)
        sources.update(raw.get("sources", {}))
        for piece, _ in cases:
            if piece["id"] in seen:
                raise ValueError(f"duplicate piece ID across suites: {piece['id']}")
            seen.add(piece["id"])
            pieces.append(piece)
    target = write_manifest(pieces, output, "combined-piano-suite", sources=sources,
                            notes=["Inspect per-dataset, recording-kind, and split scores separately.",
                                   "Standard official benchmark claims require the full official split, not this combined aggregate."])
    load_manifest(target, allow_unverified=allow_unverified)
    return target
