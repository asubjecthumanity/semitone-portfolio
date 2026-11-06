"""Exercise the actual comparison CLI, including its empty/no-match paths."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "PianoModel" / "compare.py"


class ComparisonCLITests(unittest.TestCase):
    def run_comparison(self, python_csv, swift_csv, json_output=True):
        with tempfile.TemporaryDirectory() as directory:
            a, b = Path(directory) / "python.csv", Path(directory) / "swift.csv"
            a.write_text(python_csv, encoding="utf-8")
            b.write_text(swift_csv, encoding="utf-8")
            return subprocess.run([sys.executable, str(SCRIPT), str(a), str(b)] +
                                  (["--json"] if json_output else []),
                                  text=True, capture_output=True, check=False)

    def assert_no_statistics(self, result):
        report = json.loads(result.stdout)
        self.assertEqual(report["matched"], 0)
        for field in ("onset_max_ms", "onset_mean_ms", "offset_max_ms",
                      "velocity_identical_fraction", "velocity_max_diff"):
            self.assertIsNone(report[field])
        return report

    def test_empty_pair_is_valid_silence(self):
        result = self.run_comparison("", "\n \n")
        self.assertEqual(result.returncode, 0, result.stderr)
        report = self.assert_no_statistics(result)
        self.assertEqual(report["status"], "both_empty")

    def test_empty_pair_text_output(self):
        result = self.run_comparison("", "", json_output=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("both_empty", result.stdout)
        self.assertNotIn("nan", result.stdout.lower())

    def test_one_empty_side_reports_unmatched_notes(self):
        for python_csv, swift_csv in [("", "0,1,60,64\n"), ("0,1,60,64\n", "")]:
            with self.subTest(python_csv=python_csv):
                result = self.run_comparison(python_csv, swift_csv)
                self.assertEqual(result.returncode, 1)
                report = self.assert_no_statistics(result)
                self.assertEqual(report["only_python"] + report["only_swift"], 1)

    def test_zero_matches_is_reported(self):
        for swift_csv in ["0,1,61,64\n", "1,2,60,64\n"]:
            with self.subTest(swift_csv=swift_csv):
                result = self.run_comparison("0,1,60,64\n", swift_csv)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(self.assert_no_statistics(result)["status"], "no_matches")

    def test_positive_match_retains_differences(self):
        result = self.run_comparison("0,1,60,64\n", "0.001,1.002,60,65\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["matched"], 1)
        self.assertAlmostEqual(report["onset_max_ms"], 1)
        self.assertAlmostEqual(report["offset_max_ms"], 2)
        self.assertEqual(report["velocity_max_diff"], 1)

    def test_partial_match_does_not_hide_extra_notes(self):
        result = self.run_comparison("0,1,60,64\n2,3,62,80\n", "0,1,60,64\n")
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertEqual((report["matched"], report["only_python"], report["only_swift"]), (1, 1, 0))

    def test_invalid_rows_fail_cleanly(self):
        for row in ["0,1,60\n", "nan,1,60,64\n", "bad,1,60,64\n"]:
            with self.subTest(row=row):
                result = self.run_comparison(row, "")
                self.assertEqual(result.returncode, 2)
                self.assertNotIn("Traceback", result.stderr)

    def test_maximum_matching_reassigns_a_greedy_pair(self):
        result = self.run_comparison("0.02,0.2,60,64\n0.05,0.3,60,64\n",
                                     "0,0.2,60,64\n0.03,0.3,60,64\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["matched"], 2)
        self.assertEqual(report["matcher"], "maximum_cardinality")

    def test_parity_boundary_stays_strict(self):
        result = self.run_comparison("0,1,60,64\n", "0.03,1,60,64\n")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout)["matched"], 0)


if __name__ == "__main__":
    unittest.main()
