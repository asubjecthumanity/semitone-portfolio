"""Generate native scorer fixtures using the independent mir_eval 0.8.2 API."""
import json
from pathlib import Path
import random

import mir_eval
import numpy as np

if mir_eval.__version__ != "0.8.2":
    raise RuntimeError("Use mir_eval==0.8.2 to regenerate this versioned oracle")

cases = []


def add(name, pred, ref, kind="note", pred_pitch=None, ref_pitch=None, tolerance=0.05):
    pred_pitch = [60] * len(pred) if pred_pitch is None else pred_pitch
    ref_pitch = [60] * len(ref) if ref_pitch is None else ref_pitch
    if kind == "note":
        def intervals(times):
            return np.asarray([[t, t + 0.1] for t in times], dtype=float).reshape(-1, 2)
        def pitches(values):
            return 440 * 2 ** ((np.asarray(values, dtype=float) - 69) / 12)
        matches = mir_eval.transcription.match_notes(
            intervals(ref), pitches(ref_pitch), intervals(pred), pitches(pred_pitch),
            onset_tolerance=tolerance, offset_ratio=None, strict=False)
    else:
        matches = mir_eval.util.match_events(np.asarray(ref), np.asarray(pred), window=tolerance)
    cases.append(dict(name=name, kind=kind, pred=pred, ref=ref, predPitch=pred_pitch,
                      refPitch=ref_pitch, tolerance=tolerance, expectedTP=len(matches)))


add("greedy_two_note_counterexample", [0.04, 0.10], [0, 0.06])
add("empty_both", [], [])
add("empty_pred", [], [0.1])
add("empty_ref", [0.1], [])
add("duplicates", [0.1, 0.1, 0.1], [0.1, 0.1])
add("wrong_pitch", [0.1], [0.1], pred_pitch=[60], ref_pitch=[61])
add("piano_extremes", [0.1, 0.2], [0.1, 0.2], pred_pitch=[21, 108], ref_pitch=[21, 108])
add("inclusive_note_boundary", [0.05], [0])
add("note_rounds_inside", [0.05004], [0])
add("note_rounds_outside", [0.05006], [0])
add("note_half_unit_tie", [0.05005], [0])
add("note_just_below_tie", [0.050049999999], [0])
add("note_just_above_tie", [0.050050000001], [0])
add("custom_note_window_tie", [0.07005], [0], tolerance=0.07)
add("unrounded_event_outside", [0.05004], [0], kind="event")
add("inclusive_event_boundary", [0.05], [0], kind="event")
add("unordered_notes", [0.5, 0.04, 0.10], [0.06, 0.5, 0])
add("zero_event_window", [0.1, 0.1], [0.1, 0.2], kind="event", tolerance=0)
rng = random.Random(20261002)
for index in range(200):
    pred = [round(0.1 + rng.randrange(24) * 0.02 + rng.choice([0, 0.00004, 0.00006]), 8)
            for _ in range(rng.randrange(12))]
    ref = [round(0.1 + rng.randrange(24) * 0.02, 8) for _ in range(rng.randrange(12))]
    pred_pitch = [rng.choice([21, 60, 61, 108]) for _ in pred]
    ref_pitch = [rng.choice([21, 60, 61, 108]) for _ in ref]
    add(f"random_note_{index:03}", pred, ref, pred_pitch=pred_pitch, ref_pitch=ref_pitch)
    if index < 100:
        add(f"random_event_{index:03}", pred, ref, kind="event", tolerance=0.07 if index % 2 else 0.05)
oracle = dict(mir_eval_version=mir_eval.__version__, seed=20261002,
              note_contract="exact MIDI pitch; rounded 4-decimal distance <= tolerance; no offset gate",
              event_contract="unrounded distance <= tolerance", cases=cases)
destination = Path(__file__).with_name("scoring_oracle.json")
destination.write_text(json.dumps(oracle, indent=2, allow_nan=False) + "\n", encoding="utf-8")
print(f"Wrote {len(cases)} independent reference cases to {destination}")
