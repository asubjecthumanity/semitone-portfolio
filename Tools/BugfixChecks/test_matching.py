"""Independent regression checks for the production augmenting-path matcher."""
import importlib.util
import json
from pathlib import Path
import random
import sys
import unittest

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parent / "PianoModel"))
spec = importlib.util.spec_from_file_location("semitone_compare", ROOT.parent / "PianoModel" / "compare.py")
compare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compare)


def exhaustive_count(adjacency):
    """Enumerate all assignments; intentionally independent of augmenting paths."""
    def search(left, used):
        if left == len(adjacency):
            return 0
        best = search(left + 1, used)
        for right in adjacency[left]:
            if right not in used:
                best = max(best, 1 + search(left + 1, used | {right}))
        return best
    return search(0, set())


class MaximumMatchingTests(unittest.TestCase):
    def assert_matching(self, adjacency, right_count, expected, order=None):
        pairs = compare.maximum_matching(adjacency, right_count, order)
        self.assertEqual(len(pairs), expected)
        self.assertEqual(len({left for left, _ in pairs}), len(pairs))
        self.assertEqual(len({right for _, right in pairs}), len(pairs))
        self.assertTrue(all(right in adjacency[left] for left, right in pairs))

    def test_all_three_by_three_graphs_against_exhaustive_search(self):
        for mask in range(512):
            adjacency = [[right for right in range(3) if mask & (1 << (left * 3 + right))] for left in range(3)]
            expected = exhaustive_count(adjacency)
            for order in (None, [2, 1, 0]):
                self.assert_matching(adjacency, 3, expected, order)

    def test_long_augmenting_path_without_recursion(self):
        count = 5_000
        adjacency = [[i + 1, i] for i in range(count - 1)] + [[count - 1]]
        self.assert_matching(adjacency, count, count)

    def test_random_note_matching_against_exhaustive_search(self):
        rng = random.Random(20261002)
        for _ in range(400):
            def notes():
                return [(rng.randrange(20) * 0.008, 1.0, rng.choice([21, 60, 61, 108]), 64)
                        for _ in range(rng.randrange(8))]
            left, right = notes(), notes()
            adjacency = [[j for j, b in enumerate(right) if a[2] == b[2] and abs(a[0] - b[0]) < 0.03]
                         for a in left]
            expected = exhaustive_count(adjacency)
            pairs = compare.match_notes(left, right)
            self.assertEqual(len(pairs), expected)
            self.assertTrue(all(j in adjacency[i] for i, j in pairs))
            self.assertEqual(len({j for _, j in pairs}), len(pairs))
            self.assertEqual(len(compare.match_notes(list(reversed(left)), list(reversed(right)))), expected)

    def test_committed_mir_eval_reference_counts(self):
        oracle = json.loads((ROOT / "scoring_oracle.json").read_text(encoding="utf-8"))
        self.assertEqual(oracle["mir_eval_version"], "0.8.2")
        for case in oracle["cases"]:
            adjacency = []
            for i, onset in enumerate(case["pred"]):
                candidates = []
                for j, reference in enumerate(case["ref"]):
                    distance = abs(onset - reference)
                    if case["kind"] == "note":
                        # NumPy/mir_eval use scaling and ties-to-even; Python's
                        # round(x, 4) differs for some binary half-unit values.
                        distance = round(distance * 10_000) / 10_000
                        if case["predPitch"][i] != case["refPitch"][j]:
                            continue
                    if distance <= case["tolerance"]:
                        candidates.append(j)
                adjacency.append(candidates)
            with self.subTest(case=case["name"]):
                self.assert_matching(adjacency, len(case["ref"]), case["expectedTP"])


if __name__ == "__main__":
    unittest.main()
