"""Run the real CSV boundary and reusable host validator, without iOS."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PIANO = Path(__file__).resolve().parents[1] / "PianoModel"
sys.path.insert(0, str(PIANO))
from event_contracts import load_interval_csv, validate_intervals, validate_notes


class EventContractTests(unittest.TestCase):
    def test_invalid_csv_events_are_rejected_by_actual_cli(self):
        invalid = ["-0.1,1,60,64", "1,1,60,64", "2,1,60,64", "0,1,60.5,64",
                   "0,1,20,64", "0,1,109,64", "0,1,60,-1", "0,1,60,128",
                   "0,1,60,0.5", "0,inf,60,64", "0,1,nan,64", "0,1,60,64,5"]
        with tempfile.TemporaryDirectory() as folder:
            a, b = Path(folder) / "a.csv", Path(folder) / "b.csv"
            b.write_text("0,1,60,64\n")
            for row in invalid:
                a.write_text("\n" + row + "\n")
                result = subprocess.run([sys.executable, str(PIANO / "compare.py"), str(a), str(b), "--json"],
                                        capture_output=True, text=True)
                with self.subTest(row=row):
                    self.assertEqual(result.returncode, 2)
                    self.assertIn("a.csv:2", result.stderr)
                    self.assertNotIn("Traceback", result.stderr)

    def test_direct_api_rejects_boolean_and_wrong_dynamics(self):
        for note in [(False, 1, 60, 64), (0, 1, True, 64), (0, 1, 60, 0.8), (0, 10 ** 400, 60, 64)]:
            with self.subTest(note=note), self.assertRaises(ValueError):
                validate_notes([note])

    def test_range_edges_velocity_edges_and_polyphony_are_preserved(self):
        notes = [(0, 1, 21, 0), (0, 1, 108, 127), (0, 1, 60, 64), (0.5, 2, 60, 65)]
        self.assertIs(validate_notes(notes, pitch_min=21, pitch_max=108), notes)
        self.assertEqual(len(notes), 4)

    def test_declared_duration_and_overlap_policies(self):
        notes = [(0, 1, 60, 64), (0.5, 2, 60, 65)]
        with self.assertRaisesRegex(ValueError, "overlapping pitch"):
            validate_notes(notes, overlap_policy="reject_same_pitch")
        validate_notes([(0, 1, 60, 64), (1, 2, 60, 64)], overlap_policy="reject_same_pitch")
        with self.assertRaisesRegex(ValueError, "exceeds declared duration"):
            validate_notes(notes, duration=1.5)
        for duration in [-1, float("nan"), True]:
            with self.assertRaises(ValueError):
                validate_intervals([], duration=duration)

    def test_pedal_csv_contract(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "pedal.csv"
            path.write_text("0,1\n\n1,2\n")
            self.assertEqual(load_interval_csv(path, duration=2), [(0, 1), (1, 2)])
            for text in ["-1,2", "1,1", "0,nan", "0,1,60"]:
                path.write_text(text)
                with self.assertRaises(ValueError):
                    load_interval_csv(path)

    def test_valid_overlap_and_silence_work_through_cli(self):
        with tempfile.TemporaryDirectory() as folder:
            a, b = Path(folder) / "a.csv", Path(folder) / "b.csv"
            for data in ["", "0,1,21,0\n0,1,108,127\n0.5,2,21,64\n"]:
                a.write_text(data); b.write_text(data)
                result = subprocess.run([sys.executable, str(PIANO / "compare.py"), str(a), str(b), "--json"],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["only_python"], 0)
