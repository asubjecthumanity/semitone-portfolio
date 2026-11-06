"""Reference-only transcription complexity, not an examination/pianist grade."""
from collections import defaultdict
import numpy as np

LEVELS = {0: "negative control", 1: "very simple", 2: "simple two-hand music",
          3: "intermediate", 4: "advanced", 5: "exceptionally complex"}
POLICY = "reference-complexity-v1"

def complexity(notes):
    if not notes:
        return {"level": 0, "label": LEVELS[0], "policy": POLICY, "note_count": 0}
    ordered = sorted(notes, key=lambda n: n.onset)
    times = np.asarray([n.onset for n in ordered])
    # Attacks in forward one-second windows, anchored at every actual attack.
    density = np.searchsorted(times, times + 1.0, side="left") - np.arange(len(times))
    groups, i = [], 0
    while i < len(times):
        j = int(np.searchsorted(times, times[i] + .035, side="right"))
        groups.append(j - i)
        i = j
    events = []
    for n in ordered:
        events.extend([(n.onset, 1), (n.offset, -1)])
    active, previous, occupancies, durations = 0, events[0][0], [], []
    for t, change in sorted(events):
        if t > previous and active:
            occupancies.append(active)
            durations.append(t - previous)
        active += change
        previous = t
    def weighted_percentile(values, weights, percentile):
        if not values:
            return 0
        order = np.argsort(values)
        cumulative = np.cumsum(np.asarray(weights)[order])
        idx = min(np.searchsorted(cumulative, percentile * cumulative[-1]), len(order) - 1)
        return int(np.asarray(values)[order][idx])
    d95 = float(np.percentile(density, 95))
    cmax = max(groups)
    p95 = weighted_percentile(occupancies, durations, .95)
    def tier(value, boundaries):
        return 1 + sum(value > threshold for threshold in boundaries)
    level = max(tier(d95, [2, 4, 8, 14]), tier(cmax, [1, 3, 5, 7]),
                tier(p95, [1, 3, 5, 8]))
    gaps = []
    last = {}
    for n in ordered:
        if n.pitch in last:
            gaps.append(n.onset - last[n.pitch])
        last[n.pitch] = n.onset
    return {"level": level, "label": LEVELS[level], "policy": POLICY,
            "note_count": len(notes), "attacks_per_second_p95": round(d95, 3),
            "largest_35ms_chord": cmax, "active_keys_p95": p95,
            "pitch_span_semitones": max(n.pitch for n in notes) - min(n.pitch for n in notes),
            "short_note_fraction": sum(n.offset - n.onset <= .1 for n in notes) / len(notes),
            "rapid_same_pitch_attack_fraction": sum(g <= .15 for g in gaps) / max(len(gaps), 1)}

def note_slices(notes):
    groups = defaultdict(list)
    last = {}
    for i, n in enumerate(notes):
        groups["bass_21_47" if n.pitch < 48 else "middle_48_83" if n.pitch < 84 else "treble_84_108"].append(i)
        if n.velocity is not None and n.velocity <= 40:
            groups["quiet_velocity_le_40"].append(i)
        if n.offset - n.onset <= .1:
            groups["short_duration_le_100ms"].append(i)
        if n.pitch in last and n.onset - notes[last[n.pitch]].onset <= .15:
            groups["rapid_same_pitch_le_150ms"].append(i)
        last[n.pitch] = i
        step = 353280 / 44100  # native segment start lattice, with eight-second leading pad
        phase = (n.onset + 8.0) % step
        if min(phase, step - phase) <= .1:
            groups["near_native_segment_start_100ms"].append(i)
    return dict(groups)
