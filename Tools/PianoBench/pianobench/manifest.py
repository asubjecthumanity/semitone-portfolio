"""Validation, identity, and split leakage checks for fixed evaluation suites."""
from pathlib import Path
import json
import re
import soundfile as sf
from .io import canonical_hash, load_json_bytes, load_performance, sha256, shift_reference
from .models import finite

class LoadedManifest(dict):
    """Keep the exact parsed bytes, without changing the public three-item result."""
    def __init__(self, raw, source_bytes):
        super().__init__(raw)
        self.source_bytes = source_bytes

def load_manifest(path, *, allow_unverified=False, verify_hashes=True):
    path = Path(path).resolve()
    payload = path.read_bytes()
    raw = load_json_bytes(payload)
    if (not isinstance(raw, dict) or type(raw.get("schema_version")) is not int or raw["schema_version"] != 1
            or not isinstance(raw.get("pieces"), list) or not raw["pieces"]):
        raise ValueError("expected schema_version 1 and a nonempty pieces array")
    raw = LoadedManifest(raw, payload)
    result, seen, group_splits = [], set(), {}
    hashes_to_groups = {}
    audio_splits = {}
    for original in raw["pieces"]:
        p = dict(original)
        identity = p.get("id", "")
        if not isinstance(identity, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", identity):
            raise ValueError("piece ID must be a safe filename: letters, digits, _, ., -")
        if identity in (".", "..") or identity.casefold() in seen:
            raise ValueError(f"duplicate/invalid piece id: {identity}")
        seen.add(identity.casefold())
        for key in ("dataset", "group_id", "split", "kind", "reference_offset_semantics"):
            if not isinstance(p.get(key), str) or not p[key]:
                raise ValueError(f"piece {identity} needs {key}")
        if type(p.get("difficulty_level")) is not int or p["difficulty_level"] not in range(6):
            raise ValueError(f"piece {identity} needs difficulty_level 0..5")
        duration = finite(p.get("duration_seconds"), "duration_seconds")
        if duration <= 0:
            raise ValueError("duration_seconds must be positive")
        p["duration_seconds"] = duration
        alignment = p.get("alignment", {})
        if alignment.get("status") not in ("verified", "dataset_provided") and not allow_unverified:
            raise ValueError(f"unverified label alignment for {identity}; independently verify or use --allow-unverified for an exploratory run")
        alignment = dict(alignment)
        alignment["offset_seconds"] = finite(alignment.get("offset_seconds", 0), "alignment offset")
        p["alignment"] = alignment
        for key in ("audio", "reference"):
            resolved = Path(p[key])
            if not resolved.is_absolute():
                resolved = path.parent / resolved
            if not resolved.is_file():
                raise FileNotFoundError(f"missing {key} for {identity}: {resolved}")
            p[key] = str(resolved.resolve())
            recorded = p.get(key + "_sha256")
            if not isinstance(recorded, str) or not re.fullmatch(r"[0-9a-f]{64}", recorded):
                raise ValueError(f"missing or invalid {key}_sha256 for {identity}; freeze file hashes")
            if verify_hashes and sha256(resolved) != recorded:
                raise ValueError(f"changed {key} bytes for {identity}; rebuild and version the manifest")
        info = sf.info(p["audio"])
        audio_duration = info.duration
        for field, actual in (("sample_rate", info.samplerate), ("channels", info.channels)):
            if field in p and (type(p[field]) is not int or p[field] != actual):
                raise ValueError(f"manifest {field} differs from file for {identity}")
        if abs(audio_duration - duration) > .02:
            raise ValueError(f"manifest audio duration differs from file for {identity}")
        group = p["group_id"]
        if group in group_splits and group_splits[group] != p["split"]:
            raise ValueError(f"split leakage for composition/performance group: {group}")
        group_splits[group] = p["split"]
        # Identical labels cannot hide in separate splits under different names.
        previous = hashes_to_groups.get(p["reference_sha256"])
        if previous and previous != p["split"]:
            raise ValueError("identical MIDI/labels occur in multiple splits")
        hashes_to_groups[p["reference_sha256"]] = p["split"]
        previous_audio_split = audio_splits.get(p["audio_sha256"])
        if previous_audio_split and previous_audio_split != p["split"]:
            raise ValueError("identical audio occurs in multiple splits")
        audio_splits[p["audio_sha256"]] = p["split"]
        truth = shift_reference(load_performance(p["reference"], offset_semantics=p["reference_offset_semantics"]), alignment["offset_seconds"])
        if verify_hashes and sha256(p["reference"]) != p["reference_sha256"]:
            raise ValueError(f"changed reference bytes while parsing {identity}")
        truth.duration = duration
        if any(n.offset > duration + .02 for n in truth.notes):
            raise ValueError(f"reference beyond audio duration in {identity}; verify alignment")
        if any(pedal.offset > duration + .02 for pedal in truth.pedals):
            raise ValueError(f"reference pedal beyond audio duration in {identity}; verify alignment")
        if (len(truth.notes) == 0) != (p["difficulty_level"] == 0):
            raise ValueError(f"only no-note controls may use level 0: {identity}")
        result.append((p, truth))
    # Paths are transport details; immutable bytes and label conventions identify a suite.
    contract = [{k: p.get(k) for k in (
        "id", "dataset", "dataset_release", "audio_sha256", "reference_sha256", "duration_seconds",
        "group_id", "split", "kind", "difficulty_level", "difficulty_source", "alignment",
        "reference_offset_semantics", "tags")} for p, _ in result]
    return raw, result, canonical_hash(sorted(contract, key=lambda p: p["id"]))
