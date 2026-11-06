"""Portable capture/finalization for the native builder's source/artifact record.

This checks identities, not Swift compilation or the acoustic model's lineage.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

def digest(path):
    path = Path(path)
    if path.is_file():
        return hashlib.sha256(path.read_bytes()).hexdigest()
    files = [(p.relative_to(path).as_posix(), digest(p)) for p in sorted(path.rglob("*")) if p.is_file()]
    if not files:
        raise ValueError(f"empty artifact: {path}")
    return hashlib.sha256(json.dumps(files, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

def main(argv=None):
    phase, repo_path, output_path, harness_path, *sources = argv or sys.argv[1:]
    repo, output, harness = Path(repo_path).resolve(), Path(output_path).resolve(), Path(harness_path).resolve()
    identity = {str(Path(p).resolve().relative_to(repo)): digest(p) for p in sources}
    inputs = {name: digest(repo / "Semitone" / name) for name in
              ["TranskunBackbone.mlpackage", "NMP.mlpackage", "TranskunWeights.bin"]}
    capture = output / "source_capture.json"
    if phase == "capture":
        def git(*args):
            p = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
            return p.stdout.strip() if p.returncode == 0 else None
        value = {"commit": git("rev-parse", "HEAD"), "working_tree_status": git("status", "--porcelain"),
                 "source_sha256": identity, "harness_sha256": digest(harness), "input_artifact_sha256": inputs}
        capture.write_text(json.dumps(value, indent=2) + "\n")
    elif phase == "finalize":
        value = json.loads(capture.read_text())
        if (value["source_sha256"] != identity or value["harness_sha256"] != digest(harness)
                or value["input_artifact_sha256"] != inputs or digest(output / "main.swift") != digest(harness)):
            raise ValueError("native build sources/artifacts changed during compilation")
        value.update({"executable_sha256": digest(output / "pianobench-native"),
                      "compiled_artifact_sha256": {name: digest(output / name) for name in
                                                  ["TranskunBackbone.mlmodelc", "NMP.mlmodelc"]},
                      "swift_version": subprocess.check_output(["xcrun", "swiftc", "--version"], text=True)})
        (output / "build_info.json").write_text(json.dumps(value, indent=2) + "\n")
    else:
        raise ValueError("unknown build receipt phase")

if __name__ == "__main__":
    main()
