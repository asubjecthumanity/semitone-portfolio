"""Exercise actual declared parity gates and reference clipping without models."""
import json
from pathlib import Path
import random
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest

PIANO = Path(__file__).resolve().parents[1] / "PianoModel"
sys.path.insert(0, str(PIANO))
import compare
from reference_io import clipped_reference_events
from test_matching import exhaustive_count


class ParityGateTests(unittest.TestCase):
    def run_cli(self, left="0,1,60,64\n", right="0,1,60,64\n", options=(), sustain=None, features=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); a, b = root / "a.csv", root / "b.csv"
            a.write_text(left); b.write_text(right)
            arguments = [sys.executable, str(PIANO / "compare.py"), str(a), str(b), "--json", *options]
            if sustain is not None:
                p, s = root / "p_pedal.csv", root / "s_pedal.csv"
                p.write_text(sustain[0]); s.write_text(sustain[1])
                arguments += ["--python-sustain", str(p), "--swift-sustain", str(s)]
            if features is not None:
                p, s = root / "p.f32", root / "s.f32"
                for path, values in [(p, features[0]), (s, features[1])]:
                    path.write_bytes(struct.pack("<" + "f" * len(values), *values))
                arguments += ["--python-features", str(p), "--swift-features", str(s)]
            return subprocess.run(arguments, capture_output=True, text=True)

    def test_default_offset_and_velocity_limits_fail(self):
        for right, reason in [("0,1.02,60,64\n", "note_offset_limit"), ("0,1,60,90\n", "note_velocity_limit")]:
            result = self.run_cli(right=right)
            self.assertEqual(result.returncode, 1, result.stderr)
            report = json.loads(result.stdout)
            self.assertFalse(report["passed"])
            self.assertIn(reason, report["failures"])
            self.assertEqual((report["matched"], report["gate_matched"]), (1, 0))

    def test_custom_limits_onset_only_and_zero_limits(self):
        result = self.run_cli(right="0,1.02,60,90\n", options=["--onset-only"])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["evaluation_scope"], "onset_only")
        result = self.run_cli(right="0,1.02,60,90\n", options=["--offset-tolerance-ms", "25", "--velocity-tolerance", "26"])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.run_cli(options=["--offset-tolerance-ms", "0", "--velocity-tolerance", "0"]).returncode, 0)

    def test_inclusive_time_boundary_roundoff_and_exact_zero(self):
        result = self.run_cli(left="0.1,0.5,60,64\n", right="0.1,0.505,60,64\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(compare.compare([(0, 1, 60, 64)], [(0, 1 + 1e-13, 60, 64)], offset_tolerance=0)["passed"])
        self.assertFalse(compare.compare_sustain([(0, 1)], [(0, 1 + 1e-13)], tolerance=0)["passed"])

    def test_gate_matching_can_reassign_ambiguous_repeated_notes(self):
        # Onsets are identical; nearest-only matching by index swaps dynamics.
        left = [(0, 1, 60, 30), (0, 1, 60, 90)]
        right = list(reversed(left))
        report = compare.compare(left, right, offset_tolerance=0, velocity_tolerance=0)
        self.assertTrue(report["passed"])
        self.assertEqual(report["gate_matched"], 2)
        self.assertEqual(report["velocity_max_diff"], 0)

    def test_individual_limits_can_pass_but_joint_pairing_fail(self):
        left = [(0, 1, 60, 30), (0, 2, 60, 90)]
        right = [(0, 1, 60, 90), (0, 2, 60, 30)]
        report = compare.compare(left, right, offset_tolerance=0, velocity_tolerance=0)
        self.assertFalse(report["passed"])
        self.assertEqual(report["failures"], ["joint_note_limits"])

    def test_random_joint_graphs_agree_with_exhaustive_search(self):
        rng = random.Random(20261003)
        for _ in range(200):
            def notes():
                return [(rng.randrange(8) * 0.01, 1 + rng.randrange(3) * 0.02,
                         rng.choice([60, 61]), rng.choice([30, 60, 90])) for _ in range(rng.randrange(7))]
            left, right = notes(), notes()
            adjacency = [[j for j, b in enumerate(right) if a[2] == b[2] and abs(a[0] - b[0]) < 0.03
                          and abs(a[1] - b[1]) <= 0.005 and abs(a[3] - b[3]) <= 1] for a in left]
            report = compare.compare(left, right)
            self.assertEqual(report["gate_matched"], exhaustive_count(adjacency))

    def test_unmatched_allowance_does_not_waive_bad_matched_offsets(self):
        left = "0,1,60,64\n2,3,61,64\n"
        result = self.run_cli(left=left, options=["--max-unmatched-python", "1"])
        self.assertEqual(result.returncode, 0)
        result = self.run_cli(left=left, right="0,1.02,60,64\n", options=["--max-unmatched-python", "1"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("note_offset_limit", json.loads(result.stdout)["failures"])

    def test_sustain_count_both_boundaries_and_silence(self):
        for pair in [("0,1\n", "0,1.02\n"), ("0,1\n", "0.02,1\n"), ("0,1\n", "")]:
            result = self.run_cli(sustain=pair)
            self.assertEqual(result.returncode, 1)
            self.assertIn("sustain_limit_or_count", json.loads(result.stdout)["failures"])
        self.assertEqual(self.run_cli(left="", right="", sustain=("", "")).returncode, 0)

    def test_sustain_matching_reassigns_to_maximize_both_endpoint_matches(self):
        report = compare.compare_sustain([(0.02, 1), (0.05, 1)], [(0, 1), (0.03, 1)], tolerance=0.03)
        self.assertTrue(report["passed"])
        self.assertEqual(report["matched"], 2)

    def test_feature_maximum_mean_shape_and_empty_gates(self):
        for left, right, reason in [([0, 0], [0, 0.001], "feature_error_limit"),
                                    ([0], [0, 0], "feature_shape"), ([], [], "empty_features")]:
            result = self.run_cli(features=(left, right))
            self.assertEqual(result.returncode, 1)
            self.assertIn(reason, json.loads(result.stdout)["failures"])
        # The peak is within 2e-5; the average exceeds 1e-5.
        result = self.run_cli(features=([0, 0], [1.5e-5, 1.5e-5]))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.run_cli(features=([0, 0], [5e-6, 5e-6])).returncode, 0)

    def test_missing_required_inputs_invalid_limits_and_nan_fail_cleanly(self):
        for options in [["--require-sustain"], ["--require-features"], ["--python-sustain", "missing.csv"],
                        ["--onset-tolerance-ms", "0"], ["--offset-tolerance-ms", "nan"],
                        ["--velocity-tolerance", "-1"], ["--max-unmatched-python", "-1"],
                        ["--feature-max-abs", "inf"]]:
            result = self.run_cli(options=options)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn("Traceback", result.stderr)
        result = self.run_cli(features=([float("nan")], [0]))
        self.assertEqual(result.returncode, 2)

    def test_float32_loader_rejects_truncated_values_and_direct_bool(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "bad.f32"; path.write_bytes(b"123")
            with self.assertRaises(ValueError):
                compare.load_features(path)
        with self.assertRaises(ValueError):
            compare.compare_features([True], [1])

    def test_reference_policy_rejected_before_loading_model(self):
        for options, reason in [(["--feature-max-abs", "nan"], "feature maximum error"),
                                (["--feature-mean-abs", "-1"], "feature mean error"), (["-1"], "segment")]:
            result = subprocess.run([sys.executable, str(PIANO / "reference.py"), "unused", *options],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn(reason, result.stderr)
            self.assertNotIn("Traceback", result.stderr)

    def test_reference_clipping_and_pedal_extraction_match_documented_policy(self):
        def note(start, end, pitch, velocity=64):
            return SimpleNamespace(start=start, end=end, pitch=pitch, velocity=velocity)
        notes, sustain = clipped_reference_events([note(0.1, 2, 60), note(1, 2, 61),
                                                    note(0.2, 2, -64), note(0.3, 0.8, -67)], 1)
        self.assertEqual(notes, [(0.1, 1, 60, 64)])
        self.assertEqual(sustain, [(0.2, 1)])
        for event in [note(-0.1, 1, 60), note(0.1, 0.1, 60), note(0.1, 1, 999), note(0.1, 1, -1)]:
            with self.assertRaises(ValueError):
                clipped_reference_events([event], 1)
