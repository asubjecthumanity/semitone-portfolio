"""Freeze evaluated inputs and check saved-run bytes; no inference is performed."""
from pathlib import Path
import json
import re
import shutil
from .io import canonical_hash, load_json, sha256

REQUIRED = {"input_manifest.json", "replay_manifest.json", "report.json", "report.md", "pieces.csv"}

def snapshot_cases(manifest, cases, directory):
    frozen, portable = [], []
    for original, truth in cases:
        piece = dict(original)
        for role in ("audio", "reference"):
            source = Path(piece[role])
            target = directory / "inputs" / piece["id"] / role / source.name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            if sha256(target) != piece[role + "_sha256"]:
                raise ValueError(f"changed {role} bytes while freezing {piece['id']}")
            piece[role] = str(target)
        frozen.append((piece, truth))
        portable.append({**piece, **{role: Path(piece[role]).relative_to(directory).as_posix()
                                   for role in ("audio", "reference")}})
    (directory / "input_manifest.json").write_bytes(manifest.source_bytes)
    (directory / "replay_manifest.json").write_text(json.dumps({**manifest, "pieces": portable}, indent=2, allow_nan=False) + "\n")
    return frozen

def verify_inputs(cases):
    for piece, _ in cases:
        for role in ("audio", "reference"):
            if sha256(piece[role]) != piece[role + "_sha256"]:
                raise ValueError(f"frozen {role} changed during evaluation: {piece['id']}")

def write_receipt(directory):
    # The receipt is a completion marker, written after report generation.
    # It catches missing/changed bytes, not deliberate fabrication of evidence.
    files = {p.relative_to(directory).as_posix(): sha256(p) for p in sorted(directory.rglob("*"))
             if p.is_file() and p != directory / "run_integrity.json"}
    report = load_json(directory / "report.json")
    if files.get("input_manifest.json") != report["manifest_sha256"] or files.get("replay_manifest.json") != report["replay_manifest_sha256"]:
        raise ValueError("pinned run manifest changed during evaluation")
    for row in report["pieces"]:
        for role in ("audio", "reference"):
            name = Path(row["piece"][role]).relative_to(directory).as_posix()
            if files.get(name) != row["piece"][role + "_sha256"]:
                raise ValueError("pinned run input changed before completion")
        for prefix in ("prediction", "imported_prediction"):
            name, expected = row.get(prefix + "_file"), row.get(prefix + "_sha256")
            if name is not None and expected is not None and files.get(name) != expected:
                raise ValueError("saved prediction changed before completion")
    (directory / "run_integrity.json").write_text(json.dumps({"schema_version": 1, "files": files}, indent=2) + "\n")

def verify_run(directory):
    """Validate a portable run's receipt, input identity and canonical outputs."""
    from .manifest import load_manifest
    directory = Path(directory).resolve()
    receipt = load_json(directory / "run_integrity.json")
    if (not isinstance(receipt, dict) or type(receipt.get("schema_version")) is not int
            or receipt["schema_version"] != 1 or not isinstance(receipt.get("files"), dict)):
        raise ValueError("invalid run integrity receipt")
    files = receipt["files"]
    if not REQUIRED <= files.keys():
        raise ValueError("run receipt lacks required report/manifest files")
    for name, digest in files.items():
        relative = Path(name)
        if (relative.is_absolute() or "\\" in name or any(x in {"", ".", ".."} for x in name.split("/"))
                or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)):
            raise ValueError("invalid run receipt file record")
        path = (directory / relative).resolve()
        if not path.is_relative_to(directory) or not path.is_file() or sha256(path) != digest:
            raise ValueError(f"run file missing or changed: {name}")
    report = load_json(directory / "report.json")
    if report.get("manifest_sha256") != sha256(directory / "input_manifest.json"):
        raise ValueError("report manifest fingerprint differs from pinned bytes")
    if report.get("replay_manifest_sha256") != sha256(directory / "replay_manifest.json"):
        raise ValueError("report replay manifest differs from pinned bytes")
    _, cases, fingerprint = load_manifest(directory / "replay_manifest.json",
                                          allow_unverified=report.get("exploratory_unverified_alignment", False))
    if fingerprint != report.get("dataset_fingerprint"):
        raise ValueError("replay manifest differs from evaluated contract")
    if canonical_hash(report["score_config"]) != report.get("score_config_sha256"):
        raise ValueError("score configuration identity differs")
    rows = {row["piece"]["id"]: row for row in report["pieces"]}
    if len(rows) != len(report["pieces"]) or rows.keys() != {p["id"] for p, _ in cases}:
        raise ValueError("report performance list differs from replay manifest")
    for piece, _ in cases:
        for role in ("audio", "reference"):
            name = Path(piece[role]).relative_to(directory).as_posix()
            if files.get(name) != piece[role + "_sha256"]:
                raise ValueError("input snapshot is not covered by receipt")
        row = rows[piece["id"]]
        if row["status"] == "ok":
            name = "predictions/" + piece["id"] + ".json"
            if row.get("prediction_file") != name or files.get(name) != row.get("prediction_sha256"):
                raise ValueError("canonical prediction is not covered by receipt")
    return {"status": "verified", "files_verified": len(files), "performances": len(cases),
            "failed_cases": report["summary"]["all_failed_cases"], "dataset_fingerprint": fingerprint,
            "scope": "Saved bytes/input contracts only; not a claim of real Semitone accuracy or authentic source attribution."}
