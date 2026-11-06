"""Host evidence checks with small synthetic files; no measured engine result."""
from pathlib import Path
import hashlib
import json
import sys
import importlib.util
import shutil
import numpy as np
import pytest
import soundfile as sf
from pianobench import BasicPitchRunner, CommandRunner, NativeRunner, Note, Performance, compare_runs, evaluate_version, verify_run
from pianobench.cli import main
from pianobench.io import load_json_bytes, read_csv, read_json, sha256, write_performance
from pianobench.manifest import load_manifest
from pianobench import integrity

@pytest.fixture
def fixed_suite(tmp_path):
    pieces = []
    for index in range(3):
        audio, truth = tmp_path / f"case{index}.wav", tmp_path / f"truth{index}.json"
        sf.write(audio, np.full(8000, index / 1000), 8000)
        write_performance(prediction(index), truth)
        pieces.append({"id": f"case{index}", "audio": audio.name, "reference": truth.name,
                       "audio_sha256": sha256(audio), "reference_sha256": sha256(truth),
                       "duration_seconds": 1, "sample_rate": 8000, "channels": 1,
                       "dataset": "TEST_DOUBLE", "dataset_release": "test-1",
                       "difficulty_level": 1 if index < 2 else 0, "group_id": f"group{index}",
                       "split": "test", "kind": "synthetic_toy", "reference_offset_semantics": "key_release",
                       "alignment": {"offset_seconds": 0, "status": "verified", "basis": "Designed test events"}})
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps({"schema_version": 1, "pieces": pieces}))
    return path, pieces

def prediction(index, semantics="key_release"):
    return Performance([Note(.1, .3, 60 + index, 72)] if index < 2 else [], duration=1,
                       offset_semantics=semantics, metadata={"engine": "test-double", "velocity_semantics": "midi_velocity"})

def perfect(audio):
    return prediction(int(audio.stem[-1]))

def evaluate(path, directory, **kwargs):
    return evaluate_version(path, version="test-double", output_dir=directory, bootstrap_samples=0, **kwargs)

def test_freezing_detects_change_between_preflight_and_copy(fixed_suite, tmp_path, monkeypatch):
    path, pieces = fixed_suite
    original_copy = integrity.shutil.copyfile
    calls = []
    def changed(source, target):
        if Path(source).name == pieces[0]["audio"]:
            Path(source).write_bytes(b"changed after preflight")
        return original_copy(source, target)
    monkeypatch.setattr(integrity.shutil, "copyfile", changed)
    with pytest.raises(ValueError, match="while freezing"):
        evaluate(path, tmp_path / "bad", transcriber=lambda audio: calls.append(audio))
    assert not calls and not (tmp_path / "bad/run_integrity.json").exists()

def test_original_files_can_change_after_snapshot_without_rebinding_results(fixed_suite, tmp_path):
    path, pieces = fixed_suite
    pinned = path.read_bytes()
    def mutate_original(audio):
        (path.parent / pieces[0]["audio"]).write_bytes(b"outside snapshot changed")
        path.write_text('{"new_version":true}')
        return perfect(audio)
    out = tmp_path / "run"
    report = evaluate(path, out, transcriber=mutate_original)
    assert report["summary"]["onset"]["macro_f1"] == 1
    assert report["manifest_sha256"] == hashlib.sha256(pinned).hexdigest()
    assert (out / "input_manifest.json").read_bytes() == pinned
    assert verify_run(out)["status"] == "verified"
    replay = evaluate(out / "replay_manifest.json", tmp_path / "replay", prediction_dir=out / "predictions")
    assert replay["dataset_fingerprint"] == report["dataset_fingerprint"]
    assert replay["summary"]["onset"]["macro_f1"] == 1

def test_mutating_snapshot_invalidates_run_instead_of_model_accuracy(fixed_suite, tmp_path):
    path, _ = fixed_suite
    def damaged(audio):
        audio.write_bytes(b"modified frozen input")
        return perfect(audio)
    with pytest.raises(ValueError, match="frozen audio changed"):
        evaluate(path, tmp_path / "bad", transcriber=damaged)
    assert not (tmp_path / "bad/run_integrity.json").exists()

def test_imported_unknown_audio_binding_stays_unknown_after_replay(fixed_suite, tmp_path):
    path, _ = fixed_suite
    source = tmp_path / "predictions"
    for index in range(3):
        write_performance(prediction(index), source / f"case{index}.json")
    out = tmp_path / "run"
    report = evaluate(path, out, prediction_dir=source)
    assert report["imported_predictions_without_audio_hash"] == 3
    for row in report["pieces"]:
        assert row["source_audio_identity_verified"] is False
        assert "audio_sha256" not in row["prediction_metadata"]
        assert row["prediction_metadata"]["evaluation_audio_sha256"] == row["piece"]["audio_sha256"]
    replay = evaluate(out / "replay_manifest.json", tmp_path / "replay", prediction_dir=out / "predictions")
    assert replay["imported_predictions_without_audio_hash"] == 3
    assert replay["summary"]["onset"]["macro_f1"] == 1

def test_explicit_source_audio_hash_is_retained(fixed_suite, tmp_path):
    path, pieces = fixed_suite
    source = tmp_path / "predictions"
    for index, piece in enumerate(pieces):
        value = prediction(index)
        value.metadata["audio_sha256"] = piece["audio_sha256"]
        write_performance(value, source / f"case{index}.json")
    report = evaluate(path, tmp_path / "run", prediction_dir=source)
    assert report["imported_predictions_without_audio_hash"] == 0
    assert all(row["source_audio_identity_verified"] for row in report["pieces"])

def test_integrity_cli_rejects_changed_report(fixed_suite, tmp_path, capsys):
    path, _ = fixed_suite
    out = tmp_path / "run"
    evaluate(path, out, transcriber=perfect)
    assert main(["verify-run", str(out)]) == 0
    report = json.loads((out / "report.json").read_text())
    report["summary"]["onset"]["macro_f1"] = .123
    (out / "report.json").write_text(json.dumps(report))
    assert main(["verify-run", str(out)]) == 2
    assert "missing or changed: report.json" in capsys.readouterr().err

def test_integrity_rejects_missing_prediction_and_completion_marker(fixed_suite, tmp_path):
    path, _ = fixed_suite
    out = tmp_path / "run"
    evaluate(path, out, transcriber=perfect)
    (out / "predictions/case0.json").unlink()
    with pytest.raises(ValueError, match="predictions/case0.json"):
        verify_run(out)
    (out / "run_integrity.json").unlink()
    with pytest.raises(FileNotFoundError):
        verify_run(out)

def test_later_snapshot_manifest_change_prevents_completion(fixed_suite, tmp_path):
    path, _ = fixed_suite
    out = tmp_path / "run"
    def changed(audio):
        (out / "replay_manifest.json").write_text('{"edited":true}')
        return perfect(audio)
    with pytest.raises(ValueError, match="manifest changed"):
        evaluate(path, out, transcriber=changed)
    assert not (out / "run_integrity.json").exists()

@pytest.mark.parametrize("payload", ['{"x":1,"x":2}', '{"x":NaN}', '{"x":1e999}'])
def test_strict_json_rejects_ambiguous_or_nonfinite_numbers(payload):
    with pytest.raises(ValueError):
        load_json_bytes(payload)

def test_manifest_boolean_schema_and_case_colliding_ids_rejected(fixed_suite):
    path, pieces = fixed_suite
    path.write_text(json.dumps({"schema_version": True, "pieces": pieces}))
    with pytest.raises(ValueError, match="schema_version"):
        load_manifest(path)
    pieces[1]["id"] = "CASE0"
    path.write_text(json.dumps({"schema_version": 1, "pieces": pieces}))
    with pytest.raises(ValueError, match="duplicate/invalid"):
        load_manifest(path)

def test_declared_audio_header_and_pedal_bounds_rejected(fixed_suite):
    path, pieces = fixed_suite
    pieces[0]["sample_rate"] = 44100
    path.write_text(json.dumps({"schema_version": 1, "pieces": pieces}))
    with pytest.raises(ValueError, match="sample_rate"):
        load_manifest(path)
    pieces[0]["sample_rate"] = 8000
    truth = path.parent / pieces[0]["reference"]
    raw = json.loads(truth.read_text())
    raw["pedals"] = [{"onset": .2, "offset": 1.5}]
    truth.write_text(json.dumps(raw))
    pieces[0]["reference_sha256"] = sha256(truth)
    path.write_text(json.dumps({"schema_version": 1, "pieces": pieces}))
    with pytest.raises(ValueError, match="pedal beyond"):
        load_manifest(path)

def test_activation_needs_explicit_normalized_velocity_contract(tmp_path):
    path = tmp_path / "notes.json"
    raw = {"notes": [{"onset": 0, "offset": 1, "pitch": 60, "amplitude": .5}]}
    path.write_text(json.dumps(raw))
    assert read_json(path).notes[0].velocity is None
    raw["metadata"] = {"velocity_semantics": "activation"}
    path.write_text(json.dumps(raw))
    assert read_json(path).notes[0].velocity is None
    raw["metadata"] = {"velocity_semantics": "normalized_midi_velocity"}
    path.write_text(json.dumps(raw))
    result = read_json(path)
    assert result.notes[0].velocity == 63.5
    assert result.metadata["velocity_semantics"] == "midi_velocity"

def test_csv_extra_fields_are_not_silently_ignored(tmp_path):
    path = tmp_path / "notes.csv"
    path.write_text("0,1,60,72,wrong-contract\n")
    with pytest.raises(ValueError, match="expected onset"):
        read_csv(path)
    path.write_text("0,1,60.5,72\n")
    with pytest.raises(ValueError, match="MIDI pitch"):
        read_csv(path)

def test_cross_engine_onset_comparison_does_not_invent_offset_agreement(fixed_suite, tmp_path):
    path, _ = fixed_suite
    known = evaluate(path, tmp_path / "known", transcriber=perfect)
    def unspecified(audio):
        return prediction(int(audio.stem[-1]), semantics="unspecified")
    unknown = evaluate(path, tmp_path / "unknown", transcriber=unspecified)
    with pytest.raises(ValueError, match="offset conventions"):
        compare_runs(known, unknown, bootstrap_samples=0)
    comparison = compare_runs(known, unknown, metrics=("onset",), bootstrap_samples=0)
    assert comparison["compared_metrics"] == ["onset"]
    assert comparison["metrics"]["onset"]["macro_f1_delta"] == 0
    assert "onset_offset" not in comparison["metrics"]

def test_command_artifact_change_is_detected_before_and_after_launch(tmp_path):
    script = tmp_path / "predict.py"
    script.write_text('import pathlib,sys\npathlib.Path(sys.argv[2]).write_text(\'{"notes":[]}\')\n')
    audio = tmp_path / "input.wav"
    audio.touch()
    runner = CommandRunner([sys.executable, str(script), "{audio}", "{output}"])
    script.write_text("changed predictor")
    with pytest.raises(ValueError, match="artifact changed"):
        runner(audio)
    script.write_text('import pathlib,sys\npathlib.Path(sys.argv[2]).write_text(\'{"notes":[]}\')\npathlib.Path(__file__).write_text("changed during launch")\n')
    runner = CommandRunner([sys.executable, str(script), "{audio}", "{output}"])
    with pytest.raises(ValueError, match="artifact changed"):
        runner(audio)

@pytest.mark.parametrize("value", [float("nan"), float("inf"), True, -1])
def test_invalid_timeout_rejected_before_child(value):
    with pytest.raises(ValueError):
        CommandRunner([sys.executable, "{audio}", "{output}"], timeout_seconds=value)

def test_native_model_and_build_receipt_identity_contracts(tmp_path):
    executable = tmp_path / "native"
    executable.write_text("test executable, not native inference")
    model = tmp_path / "model.mlmodelc"
    model.mkdir()
    (model / "weights").write_bytes(b"model bytes")
    weights = tmp_path / "weights.bin"
    weights.write_bytes(b"decoder bytes")
    receipt = tmp_path / "build_info.json"
    receipt.write_text(json.dumps({"executable_sha256": sha256(executable)}))
    runner = NativeRunner(executable, model, weights)
    assert runner.metadata["native_build_executable_verified"] is True
    quick = BasicPitchRunner(executable, model)
    assert quick.argv[-1] == "basic-pitch"
    assert quick.metadata["velocity_semantics"] == "activation"
    assert quick.metadata["offset_semantics"] == "unspecified"
    (model / "weights").write_bytes(b"changed model")
    with pytest.raises(ValueError, match="artifact changed"):
        runner.verify_artifacts()
    receipt.write_text(json.dumps({"executable_sha256": "0" * 64}))
    with pytest.raises(ValueError, match="different executable"):
        NativeRunner(executable, model, weights)
    receipt.write_text(json.dumps({"executable_sha256": sha256(executable),
                                  "compiled_artifact_sha256": {model.name: "0" * 64}}))
    with pytest.raises(ValueError, match="different compiled model"):
        NativeRunner(executable, model, weights)

def test_saved_run_can_move_and_replay_without_original_paths(fixed_suite, tmp_path):
    path, _ = fixed_suite
    out = tmp_path / "run"
    original = evaluate(path, out, transcriber=perfect)
    moved = tmp_path / "moved"
    shutil.move(out, moved)
    assert verify_run(moved)["status"] == "verified"
    replay = evaluate(moved / "replay_manifest.json", tmp_path / "replay", prediction_dir=moved / "predictions")
    assert replay["dataset_fingerprint"] == original["dataset_fingerprint"]
    assert compare_runs(original, replay, bootstrap_samples=0)["metrics"]["onset"]["macro_f1_delta"] == 0

@pytest.fixture
def receipt_inputs(tmp_path):
    spec = importlib.util.spec_from_file_location("pianobench_build_receipt", Path(__file__).parents[1] / "native/build_receipt.py")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    repo, output = tmp_path / "repo with spaces", tmp_path / "build with spaces"
    output.mkdir()
    (repo / "Semitone").mkdir(parents=True)
    source = repo / "Semitone/Engine.swift"
    source.write_text("// source identity fixture, not a compiled engine")
    harness = tmp_path / "main.swift"
    harness.write_text("// harness identity fixture")
    shutil.copyfile(harness, output / "main.swift")
    for name in ["NMP.mlpackage", "TranskunBackbone.mlpackage"]:
        (repo / "Semitone" / name).mkdir()
        (repo / "Semitone" / name / "weights.bin").write_bytes(b"source model fixture")
    (repo / "Semitone/TranskunWeights.bin").write_bytes(b"decoder fixture")
    (output / "pianobench-native").write_bytes(b"binary identity fixture")
    for name in ["NMP.mlmodelc", "TranskunBackbone.mlmodelc"]:
        (output / name).mkdir()
        (output / name / "compiled.bin").write_bytes(b"compiled artifact identity fixture")
    args = [str(repo), str(output), str(harness), str(source)]
    helper.main(["capture", *args])
    return helper, args, source, output, repo

def test_build_receipt_captures_binary_models_and_compiler_inputs(receipt_inputs, monkeypatch):
    helper, args, _, output, _ = receipt_inputs
    monkeypatch.setattr(helper.subprocess, "check_output", lambda *a, **k: "stub toolchain; no compilation")
    helper.main(["finalize", *args])
    info = json.loads((output / "build_info.json").read_text())
    assert info["executable_sha256"] == hashlib.sha256(b"binary identity fixture").hexdigest()
    assert set(info["compiled_artifact_sha256"]) == {"NMP.mlmodelc", "TranskunBackbone.mlmodelc"}
    assert set(info["source_sha256"]) == {"Semitone/Engine.swift"}
    assert info["swift_version"] == "stub toolchain; no compilation"

@pytest.mark.parametrize("changed", ["source", "model"])
def test_build_receipt_refuses_changed_compile_inputs(receipt_inputs, changed):
    helper, args, source, output, repo = receipt_inputs
    target = source if changed == "source" else repo / "Semitone/NMP.mlpackage/weights.bin"
    target.write_bytes(b"changed during build")
    with pytest.raises(ValueError, match="changed during compilation"):
        helper.main(["finalize", *args])
    assert not (output / "build_info.json").exists()
