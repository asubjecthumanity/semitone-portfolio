"""Exercise byte verification, label contracts and the real launch wrapper."""
import copy
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import wave

BENCH = Path(__file__).resolve().parents[1] / "MusicBench"
sys.path.insert(0, str(BENCH))
from asset_registry import sha256_file
from dataset_manifest import run_benchmark, verify_manifest
from test_asset_registry import asset


def fixture(folder, count=1):
    records, performances = [], []
    for i in range(count):
        split = "dev" if i == 0 else "test"
        name = split + "01"
        audio = folder / (name + ".wav")
        with wave.open(str(audio), "wb") as out:
            out.setparams((1, 2, 8_000, 0, "NONE", "not compressed"))
            out.writeframes(struct.pack("<h", i + 1) * 8_000)
        truth = dict(name=name, style="unit-test", bpm=120, beatsPerBar=4, duration=1,
                     keyRoot=0, keyMode="major", reverb=False,
                     notes=[dict(pitch=60, on=0.1, off=0.5, velocity=64, role="melody", program=0)],
                     drums=[], beats=[0, 0.5], downbeats=[0],
                     chords=[dict(start=0, end=1, root=0, quality="maj", label="C")])
        labels = folder / (name + ".json")
        labels.write_text(json.dumps(truth))
        for ident, path, kind in [(name + "-audio", audio, "audio"), (name + "-truth", labels, "song_truth")]:
            record = asset(ident, path.name, kind)
            record["sha256"] = sha256_file(path)
            records.append(record)
        performances.append(dict(performance_id=name, composition_id="piece-" + name,
                                 session_id="session-" + name, lineage_id="source-" + name,
                                 parent_performance_id=None, split=split,
                                 instruments=["piano"], microphone="not_applicable_synthetic",
                                 transforms=[], audio_asset=name + "-audio", truth_asset=name + "-truth",
                                 audio=dict(sample_rate=8_000, channels=1, frames=8_000),
                                 annotation=dict(format="song_truth_v1", source_uri="generated:unit-test",
                                                 onset="sampler_note_on", offset="key_release",
                                                 timing_offset_seconds=0, pitch_min=21, pitch_max=108)))
    manifest = dict(schema_version=1, dataset_id="unit-fixtures", dataset_version="v1",
                    assets=records, performances=performances)
    path = folder / "manifest.json"
    path.write_text(json.dumps(manifest))
    return path, manifest


def fake_bench(folder, code=None):
    script = folder / "fake-bench"
    script.write_text("#!" + sys.executable + "\n" + (code or
        "import json,pathlib,sys\n"
        "songs=pathlib.Path(sys.argv[1]); selected=sys.argv[sys.argv.index('--set')+1]\n"
        "assert sorted(p.name for p in songs.iterdir()) == ['dev01.json','dev01.wav']\n"
        "assert selected == 'dev'\n"
        "out=pathlib.Path(sys.argv[sys.argv.index('--json')+1])\n"
        "out.write_text(json.dumps({'pipeline':{'f1':0.5},'scoringVersion':'test-stub'}))\n"))
    script.chmod(0o755)
    return script


class DatasetManifestTests(unittest.TestCase):
    def test_actual_cli_and_verified_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary); path, document = fixture(folder)
            verified = verify_manifest(path, split="dev", use="local_evaluation")[0]
            self.assertEqual(verified["manifest_sha256"], sha256_file(path))
            self.assertEqual(verified["performances"][0]["audio_sha256"], document["assets"][0]["sha256"])
            self.assertEqual((verified["independent_sessions"], verified["independent_lineages"]), (1, 1))
            result = subprocess.run([sys.executable, str(BENCH / "dataset_manifest.py"), str(path), "--set", "dev"],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["status"], "verified")

    def test_audio_and_label_hash_changes_are_rejected(self):
        for index in [0, 1]:
            with tempfile.TemporaryDirectory() as temporary:
                folder = Path(temporary); path, document = fixture(folder)
                file = folder / document["assets"][index]["path"]
                file.write_bytes(file.read_bytes() + b"changed")
                with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                    verify_manifest(path)

    def test_header_and_annotation_validation_after_correct_hashing(self):
        changes = [("notes", [dict(pitch=60.5, on=0.1, off=0.5, velocity=64, role="melody", program=0)]),
                   ("notes", [dict(pitch=60, on=0.5, off=0.1, velocity=64, role="melody", program=0)]),
                   ("duration", 2), ("bpm", 0), ("bpm", 10 ** 400), ("beats", [0.5, 0]),
                   ("drums", [dict(time=2, gmNote=36, velocity=64)])]
        for field, value in changes:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                folder = Path(temporary); path, document = fixture(folder)
                labels = folder / "dev01.json"
                truth = json.loads(labels.read_text()); truth[field] = value
                labels.write_text(json.dumps(truth))
                document["assets"][1]["sha256"] = sha256_file(labels)
                path.write_text(json.dumps(document))
                with self.assertRaises(ValueError):
                    verify_manifest(path)
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary); path, document = fixture(folder)
            document["performances"][0]["audio"]["sample_rate"] = 16_000
            path.write_text(json.dumps(document))
            with self.assertRaisesRegex(ValueError, "header"):
                verify_manifest(path)

    def test_symlink_escape_and_truncated_wav_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary); root = folder / "data"; root.mkdir()
            path, document = fixture(root)
            original = root / "dev01.wav"; outside = folder / "outside.wav"
            original.rename(outside); original.symlink_to(outside)
            with self.assertRaisesRegex(ValueError, "inside the dataset root"):
                verify_manifest(path)
            original.unlink(); original.write_bytes(outside.read_bytes()[:-10])
            document["assets"][0]["sha256"] = sha256_file(original)
            path.write_text(json.dumps(document))
            with self.assertRaisesRegex(ValueError, "truncated WAV"):
                verify_manifest(path)

    def test_group_and_content_split_leakage(self):
        for field in ["composition_id", "session_id", "lineage_id", "audio_sha256"]:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                folder = Path(temporary); path, document = fixture(folder, 2)
                if field == "audio_sha256":
                    document["assets"][2]["sha256"] = document["assets"][0]["sha256"]
                else:
                    document["performances"][1][field] = document["performances"][0][field]
                path.write_text(json.dumps(document))
                with self.assertRaisesRegex(ValueError, "cross.*split"):
                    verify_manifest(path, split="dev")

    def test_parent_cycle_and_changed_lineage(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary); path, document = fixture(folder)
            p = document["performances"][0]
            p.update(parent_performance_id="dev01", transforms=[dict(name="crop", parameters={})])
            path.write_text(json.dumps(document))
            with self.assertRaisesRegex(ValueError, "cyclic"):
                verify_manifest(path)
            p["parent_performance_id"] = "missing-parent"
            path.write_text(json.dumps(document))
            with self.assertRaisesRegex(ValueError, "missing/cyclic"):
                verify_manifest(path)

    def test_csv_alignment_and_empty_note_controls(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary); path, document = fixture(folder)
            labels = folder / "dev01.csv"; labels.write_text("0.1,0.9,21,64\n")
            document["assets"][1].update(kind="notes_csv", path=labels.name, sha256=sha256_file(labels))
            p = document["performances"][0]
            p["annotation"].update(format="note_csv_v1", timing_offset_seconds=0.1)
            path.write_text(json.dumps(document))
            self.assertEqual(verify_manifest(path)[0]["performances"][0]["notes"], 1)
            p["annotation"]["timing_offset_seconds"] = 0.2
            path.write_text(json.dumps(document))
            with self.assertRaisesRegex(ValueError, "exceeds declared duration"):
                verify_manifest(path)
            labels.write_text(""); document["assets"][1]["sha256"] = sha256_file(labels)
            path.write_text(json.dumps(document))
            self.assertEqual(verify_manifest(path)[0]["performances"][0]["notes"], 0)

    def test_snapshot_launch_excludes_manifest_and_preserves_provenance(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary); path, document = fixture(folder, 2)
            (folder / "unrelated.json").write_text("{}")
            result_path = folder / "result.json"
            result = subprocess.run([sys.executable, str(BENCH / "dataset_manifest.py"), str(path), "--set", "dev",
                                     "--bench", str(fake_bench(folder)), "--json", str(result_path)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result_path.read_text())
            self.assertEqual(report["pipeline"]["f1"], 0.5)
            self.assertEqual(report["verified_dataset"]["manifest_sha256"], sha256_file(path))
            self.assertEqual(len(report["verified_dataset"]["performances"]), 1)

    def test_invalid_input_prevents_child_and_failed_child_preserves_old_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary); path, document = fixture(folder)
            marker = folder / "called"; report = folder / "result.json"; report.write_text("old report")
            binary = fake_bench(folder, f"import pathlib,sys\npathlib.Path({str(marker)!r}).write_text('called')\nsys.exit(7)\n")
            command = [sys.executable, str(BENCH / "dataset_manifest.py"), str(path), "--set", "dev",
                       "--bench", str(binary), "--json", str(report)]
            changed = folder / "dev01.wav"; original = changed.read_bytes(); changed.write_bytes(b"bad")
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(marker.exists())
            changed.write_bytes(original)
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 7)
            self.assertEqual(report.read_text(), "old report")

    def test_held_out_sweep_rejected_before_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary); path, _ = fixture(folder, 2)
            marker = folder / "called"
            binary = fake_bench(folder, f"import pathlib\npathlib.Path({str(marker)!r}).write_text('bad')\n")
            result = subprocess.run([sys.executable, str(BENCH / "dataset_manifest.py"), str(path), "--set", "test",
                                     "--bench", str(binary), "--sweep", "notes", "--json", str(folder / "out.json")],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(marker.exists())

    def test_snapshot_copy_detects_change(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary); path, _ = fixture(folder)
            verified = verify_manifest(path)
            binary = fake_bench(folder)
            with patch("dataset_manifest.shutil.copyfile", side_effect=lambda src, dst: Path(dst).write_bytes(b"changed")):
                with self.assertRaisesRegex(ValueError, "source changed"):
                    run_benchmark(verified, binary=binary, split="dev")

    def test_output_cannot_replace_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary); path, _ = fixture(folder)
            original = path.read_bytes()
            result = subprocess.run([sys.executable, str(BENCH / "dataset_manifest.py"), str(path), "--json", str(path)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(path.read_bytes(), original)

    def test_native_launch_refuses_unapplied_alignment_or_acoustic_labels(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary); path, document = fixture(folder)
            binary = fake_bench(folder)
            document["performances"][0]["annotation"]["onset"] = "acoustic_onset"
            path.write_text(json.dumps(document))
            with self.assertRaisesRegex(ValueError, "scheduled SongTruth"):
                run_benchmark(verify_manifest(path), binary=binary, split="dev")
