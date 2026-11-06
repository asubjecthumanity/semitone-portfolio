"""Subprocess adapters use argument arrays; no shell interpolation."""
from pathlib import Path
import json
import subprocess
import shutil
import tempfile
import time
from .io import canonical_hash, load_json, load_performance, sha256
from .models import finite, SEMANTICS

def artifact_hash(path):
    path = Path(path).resolve()
    if path.is_file():
        return sha256(path)
    if not path.is_dir():
        raise FileNotFoundError(path)
    entries = [(p.relative_to(path).as_posix(), sha256(p)) for p in sorted(path.rglob("*")) if p.is_file()]
    if not entries:
        raise ValueError(f"empty model artifact: {path}")
    return canonical_hash(entries)

class CommandRunner:
    """Adapter for any audio -> JSON/MIDI/CSV executable.

    Example argv: ['/path/predict', '--input', '{audio}', '--output', '{output}'].
    Output times must refer to the supplied audio. No lag fitting is performed.
    """
    def __init__(self, argv, *, timeout_seconds=1800, output_suffix=".json", offset_semantics=None):
        if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
            raise ValueError("runner argv must be a nonempty string array")
        if not any("{audio}" in a for a in argv) or not any("{output}" in a for a in argv):
            raise ValueError("runner argv must include {audio} and {output}")
        timeout_seconds = finite(timeout_seconds, "timeout_seconds")
        if timeout_seconds <= 0 or output_suffix not in (".json", ".mid", ".midi", ".csv"):
            raise ValueError("invalid timeout/output format")
        if offset_semantics is not None and offset_semantics not in SEMANTICS:
            raise ValueError("unknown runner offset semantics")
        resolved = shutil.which(argv[0])
        if resolved:
            argv = [resolved, *argv[1:]]
        self.argv, self.timeout_seconds = tuple(argv), timeout_seconds
        self.output_suffix, self.offset_semantics = output_suffix, offset_semantics
        self.metadata = {"runner": "command", "argv_template": list(argv),
                         "output_suffix": output_suffix, "offset_semantics": offset_semantics}
        self.artifacts = {}
        for item in argv:
            if "{audio}" not in item and "{output}" not in item and Path(item).is_file():
                self.artifacts[str(Path(item).resolve())] = artifact_hash(item)
        self.metadata["artifact_sha256"] = dict(self.artifacts)
        if Path(argv[0]).is_file():
            self.metadata["executable_sha256"] = sha256(argv[0])

    def verify_artifacts(self):
        for path, digest in self.artifacts.items():
            if artifact_hash(path) != digest:
                raise ValueError(f"runner artifact changed: {path}")

    def __call__(self, audio):
        self.verify_artifacts()
        with tempfile.TemporaryDirectory(prefix="pianobench-") as tmp:
            output = Path(tmp) / ("prediction" + self.output_suffix)
            argv = [a.replace("{audio}", str(Path(audio).resolve())).replace("{output}", str(output)) for a in self.argv]
            start = time.perf_counter()
            process = subprocess.run(argv, capture_output=True, text=True, timeout=self.timeout_seconds,
                                     check=False)
            elapsed = time.perf_counter() - start
            self.verify_artifacts()
            if process.returncode:
                raise RuntimeError(f"runner exited {process.returncode}: {process.stderr[-4000:]}")
            if not output.is_file():
                raise RuntimeError("runner completed without writing its prediction file")
            result = load_performance(output, offset_semantics=self.offset_semantics)
            result.metadata["subprocess_wall_seconds"] = elapsed
            result.metadata["runner_stderr_tail"] = process.stderr[-4000:]
            return result

class NativeRunner(CommandRunner):
    """Run the fork's actual Swift PianoTranscriber with explicit artifacts."""
    def __init__(self, executable, model, weights, *, compute="ane", offset_semantics="unspecified",
                 timeout_seconds=1800):
        if compute not in ("ane", "cpu"):
            raise ValueError("compute must be ane or cpu")
        super().__init__([str(Path(executable).resolve()), "{audio}", str(Path(model).resolve()),
                          str(Path(weights).resolve()), "{output}", compute, offset_semantics],
                         timeout_seconds=timeout_seconds)
        build_info = Path(executable).resolve().parent / "build_info.json"
        for artifact in (model, weights):
            self.artifacts[str(Path(artifact).resolve())] = artifact_hash(artifact)
        if build_info.is_file():
            self.artifacts[str(build_info)] = sha256(build_info)
        self.metadata = {**self.metadata, "runner": "semitone-native-piano", "compute": compute,
                         "artifact_sha256": dict(self.artifacts),
                         "model_sha256": artifact_hash(model), "weights_sha256": artifact_hash(weights),
                         "native_build": load_json(build_info) if build_info.is_file() else None,
                         "offset_semantics": offset_semantics}
        self._check_build_receipt()

    def _check_build_receipt(self):
        receipt = self.metadata.get("native_build")
        recorded = receipt.get("executable_sha256") if isinstance(receipt, dict) else None
        if recorded is not None and recorded != self.metadata.get("executable_sha256"):
            raise ValueError("native build receipt belongs to a different executable")
        self.metadata["native_build_executable_verified"] = recorded is not None
        models = receipt.get("compiled_artifact_sha256", {}) if isinstance(receipt, dict) else {}
        model = Path(self.argv[2]).resolve()
        model_digest = models.get(model.name)
        model_matches = model_digest is not None and model_digest == self.metadata.get("model_sha256")
        if model_digest is not None and not model_matches and model.parent == Path(self.argv[0]).resolve().parent:
            raise ValueError("native build receipt belongs to a different compiled model")
        self.metadata["native_build_model_verified"] = model_matches
        if "weights_sha256" in self.metadata:
            inputs = receipt.get("input_artifact_sha256", {}) if isinstance(receipt, dict) else {}
            self.metadata["native_build_weights_verified"] = inputs.get("TranskunWeights.bin") == self.metadata["weights_sha256"]

class BasicPitchRunner(CommandRunner):
    """The same native harness, with the fork's fixed piano quick-pass preset.

    Activation is not MIDI velocity, and no pedal/offset convention is invented.
    Native compilation/inference still require a compatible Mac.
    """
    def __init__(self, executable, model, *, offset_semantics="unspecified", timeout_seconds=1800):
        super().__init__([str(Path(executable).resolve()), "{audio}", str(Path(model).resolve()),
                          "-", "{output}", "default", offset_semantics, "basic-pitch"],
                         timeout_seconds=timeout_seconds, offset_semantics=offset_semantics)
        self.artifacts[str(Path(model).resolve())] = artifact_hash(model)
        build_info = Path(executable).resolve().parent / "build_info.json"
        if build_info.is_file():
            self.artifacts[str(build_info)] = sha256(build_info)
        self.metadata.update({"runner": "semitone-native-basic-pitch", "compute": "CoreML default",
                              "artifact_sha256": dict(self.artifacts), "model_sha256": artifact_hash(model),
                              "native_build": load_json(build_info) if build_info.is_file() else None,
                              "offset_semantics": offset_semantics, "detection_preset": "piano",
                              "velocity_semantics": "activation"})
        NativeRunner._check_build_receipt(self)
