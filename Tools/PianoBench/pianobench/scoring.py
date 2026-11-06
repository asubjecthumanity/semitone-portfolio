"""Maximum-cardinality note scoring and interpretable piano diagnostics.

Sparse onset neighborhoods avoid the all-pairs matrices that are costly on
long/dense piano pieces. Threshold rounding follows mir_eval 0.8.2 (4 decimals).
"""
from dataclasses import asdict, dataclass
from collections import defaultdict
import math
import numpy as np
from scipy.sparse import csr_matrix
from scipy.sparse.csgraph import maximum_bipartite_matching
from .models import Note, Performance, pedal_extended
from .difficulty import complexity, note_slices

@dataclass(frozen=True)
class ScoreConfig:
    onset_tolerance: float = .05
    pitch_tolerance_cents: float = 50.0
    offset_ratio: float = .2
    offset_min_tolerance: float = .05
    strict: bool = False
    window_seconds: float = 10.0

    def __post_init__(self):
        for key, value in asdict(self).items():
            if key != "strict" and (not math.isfinite(value) or value <= 0):
                raise ValueError(f"{key} must be finite and positive")
        if not isinstance(self.strict, bool):
            raise ValueError("strict must be boolean")

def match_notes(reference, prediction, *, config=None, offsets=False,
                onset_tolerance=None, ignore_pitch=False):
    """Return optimal one-to-one (reference index, prediction index) pairs."""
    cfg = config or ScoreConfig()
    tolerance = onset_tolerance if onset_tolerance is not None else cfg.onset_tolerance
    if not reference or not prediction:
        return []
    pred_onsets = np.asarray([n.onset for n in prediction])
    order = np.argsort(pred_onsets, kind="stable")
    times = pred_onsets[order]
    rows, cols = [], []
    cmp = (lambda a, b: a < b) if cfg.strict else (lambda a, b: a <= b)
    for i, ref in enumerate(reference):
        # Include values that mir_eval's four-decimal rounding can accept.
        lo = np.searchsorted(times, ref.onset - tolerance - .000051, side="left")
        hi = np.searchsorted(times, ref.onset + tolerance + .000051, side="right")
        for j in order[lo:hi]:
            est = prediction[int(j)]
            if not cmp(float(np.round(abs(ref.onset - est.onset), 4)), tolerance):
                continue
            if not ignore_pitch and not cmp(abs(ref.pitch - est.pitch) * 100.0, cfg.pitch_tolerance_cents):
                continue
            if offsets:
                bound = max(cfg.offset_min_tolerance, cfg.offset_ratio * (ref.offset - ref.onset))
                if not cmp(float(np.round(abs(ref.offset - est.offset), 4)), bound):
                    continue
            rows.append(i)
            cols.append(int(j))
    graph = csr_matrix((np.ones(len(rows), dtype=np.int8), (rows, cols)),
                       shape=(len(reference), len(prediction)))
    pairs = maximum_bipartite_matching(graph, perm_type="column")
    return [(i, int(j)) for i, j in enumerate(pairs) if j >= 0]

def counts_score(tp, fp, fn):
    tp, fp, fn = int(tp), int(fp), int(fn)
    # No reference notes is a negative-control task; do not award 100% note F1.
    if tp + fn == 0:
        return {"tp": tp, "fp": fp, "fn": fn, "precision": 0.0 if fp else None,
                "recall": None, "f1": None}
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn)
    f1 = 2 * tp / (2 * tp + fp + fn)
    return {"tp": tp, "fp": fp, "fn": fn, "precision": precision, "recall": recall, "f1": f1}

def event_score(reference, prediction, pairs):
    return counts_score(len(pairs), len(prediction) - len(pairs), len(reference) - len(pairs))

def _stats(values, scale=1.0):
    if not values:
        return {"count": 0, "mean": None, "median": None, "p95": None}
    values = np.asarray(values) * scale
    return {"count": len(values), "mean": float(values.mean()),
            "median": float(np.median(values)), "p95": float(np.percentile(values, 95))}

def _union(intervals):
    result = []
    for start, end in sorted(intervals):
        if result and start <= result[-1][1]:
            result[-1] = (result[-1][0], max(result[-1][1], end))
        else:
            result.append((start, end))
    return result

def _intersection(a, b):
    i = j = 0
    total = 0.0
    while i < len(a) and j < len(b):
        total += max(0, min(a[i][1], b[j][1]) - max(a[i][0], b[j][0]))
        if a[i][1] < b[j][1]:
            i += 1
        else:
            j += 1
    return total

def activity_score(reference, prediction, duration):
    """Exact time-weighted pitch activity, not a discretized frame-F1 claim."""
    a, b = defaultdict(list), defaultdict(list)
    for collection, notes in ((a, reference), (b, prediction)):
        for n in notes:
            start, end = max(0, n.onset), min(duration, n.offset)
            if end > start:
                collection[n.pitch].append((start, end))
    ref_time = pred_time = common = 0.0
    for pitch in a.keys() | b.keys():
        aa, bb = _union(a[pitch]), _union(b[pitch])
        ref_time += sum(e - s for s, e in aa)
        pred_time += sum(e - s for s, e in bb)
        common += _intersection(aa, bb)
    return {"true_positive_pitch_seconds": common, "reference_pitch_seconds": ref_time,
            "prediction_pitch_seconds": pred_time,
            "precision": common / pred_time if pred_time else (0.0 if ref_time else None),
            "recall": common / ref_time if ref_time else None,
            "f1": 2 * common / (ref_time + pred_time) if ref_time else None}

def _offset_view(ref, pred, cfg, duration):
    pairs = match_notes(ref.notes, pred.notes, config=cfg, offsets=True)
    return {"note": event_score(ref.notes, pred.notes, pairs),
            "pitch_activity": activity_score(ref.notes, pred.notes, duration)}

def _diagnostics(ref, pred, pairs, cfg):
    matched_ref, matched_pred = {i for i, _ in pairs}, {j for _, j in pairs}
    ri = [i for i in range(len(ref.notes)) if i not in matched_ref]
    pi = [i for i in range(len(pred.notes)) if i not in matched_pred]
    remaining_r = [ref.notes[i] for i in ri]
    remaining_p = [pred.notes[i] for i in pi]
    wrong = match_notes(remaining_r, remaining_p, config=cfg, ignore_pitch=True)
    hist = defaultdict(int)
    for i, j in wrong:
        hist[str(remaining_p[j].pitch - remaining_r[i].pitch)] += 1
    pitch_errors = [{"reference_index": ri[i], "prediction_index": pi[j],
                     "semitones": remaining_p[j].pitch - remaining_r[i].pitch} for i, j in wrong]
    loose = match_notes(ref.notes, pred.notes, config=cfg, onset_tolerance=.15)
    merges = []
    # Heuristic evidence only: a missing attack within an estimated same-key span.
    for i in ri:
        n = ref.notes[i]
        candidates = [j for j, p in enumerate(pred.notes)
                      if p.pitch == n.pitch and p.onset + cfg.onset_tolerance < n.onset < p.offset]
        if candidates:
            merges.append({"reference_index": i, "prediction_indices": candidates})
    return {"missed_note_indices": ri, "extra_note_indices": pi,
            "possible_pitch_errors": pitch_errors, "pitch_error_semitone_histogram": dict(hist),
            "possible_octave_errors": sum(v for k, v in hist.items() if abs(int(k)) == 12),
            "possible_semitone_errors": sum(v for k, v in hist.items() if abs(int(k)) == 1),
            "additional_matches_at_150ms": len(loose) - len(pairs) if cfg.onset_tolerance <= .15 else None,
            "possible_merged_restrikes": merges,
            "out_of_piano_range_predictions": [i for i, n in enumerate(pred.notes) if not 21 <= n.pitch <= 108],
            "diagnostic_note": "Error pairings and merge explanations are hypotheses; matching ties need not be unique."}

def evaluate_performance(reference: Performance, prediction: Performance, *, config=None,
                         duration_seconds=None):
    """Judge one performance; scores are fractions, not percentage labels.

    The headline onset F1 requires exact MIDI pitch at the default 50-cent
    tolerance. Offset F1 is withheld if the label convention is undeclared.
    """
    cfg = config or ScoreConfig()
    duration = duration_seconds or reference.duration
    if not duration or not math.isfinite(duration) or duration <= 0:
        raise ValueError("supply the original audio duration for evaluation")
    if any(n.offset > duration + .02 for n in reference.notes):
        raise ValueError("reference note extends beyond audio; check pairing/alignment")
    pairs = match_notes(reference.notes, prediction.notes, config=cfg)
    onset = event_score(reference.notes, prediction.notes, pairs)
    timing = _stats([abs(prediction.notes[j].onset - reference.notes[i].onset) for i, j in pairs], 1000)
    signed = [prediction.notes[j].onset - reference.notes[i].onset for i, j in pairs]
    timing["signed_bias_ms"] = float(np.mean(signed) * 1000) if signed else None
    timing["matched_residual_drift_ms_per_minute"] = float(np.polyfit(
        [reference.notes[i].onset / 60 for i, _ in pairs], np.asarray(signed) * 1000, 1)[0]) if len(pairs) >= 3 and len({reference.notes[i].onset for i, _ in pairs}) >= 2 else None
    timing["conditioning"] = "correct-pitch matches within the headline onset tolerance"
    strict_scores = {f"{ms}ms": event_score(reference.notes, prediction.notes,
                     match_notes(reference.notes, prediction.notes, config=cfg, onset_tolerance=ms / 1000))
                     for ms in (10, 25, 50, 100)}
    target = None
    if prediction.offset_semantics == reference.offset_semantics != "unspecified":
        target = reference
    elif prediction.offset_semantics == "pedal_extended" and reference.offset_semantics == "key_release" and 64 in reference.pedal_controllers:
        target = pedal_extended(reference)
    offset_diagnostics = {}
    if reference.offset_semantics == "key_release":
        offset_diagnostics["raw_prediction_vs_key_release"] = _offset_view(reference, prediction, cfg, duration)
        if 64 in reference.pedal_controllers:
            extended = pedal_extended(reference)
            offset_diagnostics["raw_prediction_vs_pedal_extended"] = _offset_view(extended, prediction, cfg, duration)
            if prediction.offset_semantics == "key_release" and 64 in prediction.pedal_controllers:
                offset_diagnostics["both_sides_pedal_extended"] = _offset_view(extended, pedal_extended(prediction), cfg, duration)
    compatible = _offset_view(target, prediction, cfg, duration) if target else None
    offsets = _stats([abs(prediction.notes[j].offset - target.notes[i].offset) for i, j in pairs], 1000) if target else None
    velocities = [abs(prediction.notes[j].velocity - reference.notes[i].velocity) for i, j in pairs
                  if prediction.notes[j].velocity is not None and reference.notes[i].velocity is not None]
    velocity = _stats(velocities) if prediction.metadata.get("velocity_semantics") == "midi_velocity" else None
    if velocity:
        velocity["fraction_within_10_midi_units"] = sum(v <= 10 for v in velocities) / len(velocities) if velocities else None
    matched = {i for i, _ in pairs}
    slices = {name: {"reference_notes": len(indices), "matched": sum(i in matched for i in indices),
                     "recall": sum(i in matched for i in indices) / len(indices)}
              for name, indices in note_slices(reference.notes).items()}
    pedal_scores = {}
    for cc in (64, 67):
        annotated, supported = cc in reference.pedal_controllers, cc in prediction.pedal_controllers
        r = [Note(p.onset, p.offset, 60) for p in reference.pedals if p.controller == cc]
        p = [Note(p.onset, p.offset, 60) for p in prediction.pedals if p.controller == cc]
        pp = match_notes(r, p, config=cfg, offsets=True)
        pedal_scores[str(cc)] = {"reference_annotated": annotated, "prediction_supported": supported,
                                 "event": event_score(r, p, pp) if annotated else None,
                                 "down_activity": activity_score(r, p, duration) if annotated else None}
    paired_predictions = {j for _, j in pairs}
    fp_onsets = [n.onset for j, n in enumerate(prediction.notes) if j not in paired_predictions]
    windows = []
    for start in np.arange(0, duration, cfg.window_seconds):
        end = min(duration, float(start + cfg.window_seconds))
        indices = [i for i, n in enumerate(reference.notes) if start <= n.onset < end]
        if not indices:
            continue
        tp = sum(i in matched for i in indices)
        fp = sum(start <= t < end for t in fp_onsets)
        windows.append({"start_seconds": float(start), "end_seconds": end,
                        "complexity": complexity([reference.notes[i] for i in indices]),
                        "onset": counts_score(tp, fp, len(indices) - tp)})
    return {"onset": onset, "onset_tolerance_sweep": strict_scores,
            "onset_offset": compatible["note"] if compatible else None,
            "pitch_activity": compatible["pitch_activity"] if compatible else None,
            "offset_semantics": {"reference": reference.offset_semantics, "prediction": prediction.offset_semantics,
                                 "headline_comparable": target is not None},
            "offset_diagnostics": offset_diagnostics, "onset_timing_ms": timing,
            "offset_error_ms_on_onset_matches": offsets, "velocity_error_midi": velocity,
            "pedals": pedal_scores, "reference_note_slices": slices, "windows": windows,
            "negative_control": {"duration_seconds": duration, "false_notes": len(prediction.notes),
                                 "false_notes_per_minute": len(prediction.notes) * 60 / duration} if not reference.notes else None,
            "diagnostics": _diagnostics(reference, prediction, pairs, cfg),
            "matched_note_pairs": [list(x) for x in pairs],
            "prediction_outside_audio": sum(n.onset >= duration or n.offset > duration + .02 for n in prediction.notes)}
