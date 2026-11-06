"""Enforce declared note, optional sustain, and optional feature parity limits."""

import argparse
import json
import math
import sys
from array import array
from statistics import fmean
from bisect import bisect_left, bisect_right
from collections import defaultdict
try:
    from .event_contracts import load_interval_csv, load_note_csv, validate_intervals, validate_notes
except ImportError:  # Direct script invocation.
    from event_contracts import load_interval_csv, load_note_csv, validate_intervals, validate_notes

DEFAULT_OFFSET_TOLERANCE = 0.005
DEFAULT_VELOCITY_TOLERANCE = 1.0
DEFAULT_PEDAL_TOLERANCE = 0.005
DEFAULT_FEATURE_MAX_ABS = 2e-5
DEFAULT_FEATURE_MEAN_ABS = 1e-5
PARITY_POLICY_VERSION = "note-sustain-features-v1"


def limit(value, name, *, positive=False):
    try:
        valid = not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value)
    except OverflowError:
        valid = False
    if not valid or value < 0 or (positive and value == 0):
        raise ValueError(f"{name}: expected a finite {'positive' if positive else 'nonnegative'} limit")
    return value


def within_time(distance, tolerance):
    # Inclusive time boundaries permit only 1 ps of binary-float roundoff.
    # A requested zero tolerance still requires exact numeric equality.
    return distance <= tolerance or (tolerance > 0 and math.isclose(distance, tolerance, rel_tol=0, abs_tol=1e-12))


def load(path):
    return load_note_csv(path)


def maximum_matching(adjacency, right_count, order=None):
    """Maximum-cardinality bipartite matching via iterative augmenting paths.

    Neighbor/root ordering resolves ambiguity deterministically; it does not
    promise minimum total onset error among equally large matchings.
    """
    matched_left = [-1] * len(adjacency)
    matched_right = [-1] * right_count
    seen_left = [0] * len(adjacency)
    seen_right = [0] * right_count
    parent_right = [-1] * right_count
    for stamp, root in enumerate(range(len(adjacency)) if order is None else order, 1):
        queue, head, free_right = [root], 0, -1
        seen_left[root] = stamp
        while head < len(queue) and free_right == -1:
            left = queue[head]
            head += 1
            for right in adjacency[left]:
                if seen_right[right] == stamp:
                    continue
                seen_right[right] = stamp
                parent_right[right] = left
                previous_left = matched_right[right]
                if previous_left == -1:
                    free_right = right
                    break
                if seen_left[previous_left] != stamp:
                    seen_left[previous_left] = stamp
                    queue.append(previous_left)
        right = free_right
        while right != -1:
            left = parent_right[right]
            previous_right = matched_left[left]
            matched_left[left] = right
            matched_right[right] = left
            right = previous_right
    return [(left, right) for left, right in enumerate(matched_left) if right != -1]


def match_notes(python_notes, swift_notes, *, onset_tolerance=0.03,
                offset_tolerance=None, velocity_tolerance=None):
    """Maximize eligible pairs; include every enabled limit in the graph."""
    by_pitch = defaultdict(list)
    for index, note in enumerate(swift_notes):
        by_pitch[note[2]].append(index)
    indexed = {}
    for pitch, indices in by_pitch.items():
        indices.sort(key=lambda i: (swift_notes[i][0], i))
        indexed[pitch] = ([swift_notes[i][0] for i in indices], indices)
    adjacency = [[] for _ in python_notes]
    for left, note in enumerate(python_notes):
        times, indices = indexed.get(note[2], ([], []))
        start = bisect_left(times, note[0] - onset_tolerance)
        stop = bisect_right(times, note[0] + onset_tolerance)
        eligible = [right for right in indices[start:stop]
                    if abs(swift_notes[right][0] - note[0]) < onset_tolerance
                    and (offset_tolerance is None or within_time(abs(swift_notes[right][1] - note[1]), offset_tolerance))
                    and (velocity_tolerance is None or abs(swift_notes[right][3] - note[3]) <= velocity_tolerance)]
        adjacency[left] = sorted(eligible, key=lambda right: (abs(swift_notes[right][0] - note[0]), right))
    order = sorted(range(len(python_notes)), key=lambda i: (python_notes[i][0], i))
    return maximum_matching(adjacency, len(swift_notes), order)


def compare(python_notes, swift_notes, *, onset_tolerance=0.03,
            offset_tolerance=DEFAULT_OFFSET_TOLERANCE, velocity_tolerance=DEFAULT_VELOCITY_TOLERANCE,
            max_unmatched_python=0, max_unmatched_swift=0):
    limit(onset_tolerance, "onset tolerance", positive=True)
    for name, value in [("offset tolerance", offset_tolerance), ("velocity tolerance", velocity_tolerance)]:
        if value is not None:
            limit(value, name)
    for name, value in [("max_unmatched_python", max_unmatched_python), ("max_unmatched_swift", max_unmatched_swift)]:
        if type(value) is not int or value < 0:
            raise ValueError(f"{name}: expected a nonnegative integer")
    validate_notes(python_notes, pitch_min=21, pitch_max=108, context="Python notes")
    validate_notes(swift_notes, pitch_min=21, pitch_max=108, context="Swift notes")
    base = match_notes(python_notes, swift_notes, onset_tolerance=onset_tolerance)
    eligible = match_notes(python_notes, swift_notes, onset_tolerance=onset_tolerance,
                           offset_tolerance=offset_tolerance, velocity_tolerance=velocity_tolerance)
    # Use a fully gate-eligible maximum pairing for diagnostics when it exists.
    # This avoids false failures from arbitrary choices among repeated notes.
    selected = eligible if len(eligible) == len(base) else base
    pairs = [(python_notes[left], swift_notes[right]) for left, right in selected]
    failures = []
    if len(python_notes) - len(base) > max_unmatched_python:
        failures.append("unmatched_python_notes")
    if len(swift_notes) - len(base) > max_unmatched_swift:
        failures.append("unmatched_swift_notes")
    if len(eligible) < len(base):
        if offset_tolerance is not None and len(match_notes(python_notes, swift_notes, onset_tolerance=onset_tolerance,
                                                            offset_tolerance=offset_tolerance)) < len(base):
            failures.append("note_offset_limit")
        if velocity_tolerance is not None and len(match_notes(python_notes, swift_notes, onset_tolerance=onset_tolerance,
                                                              velocity_tolerance=velocity_tolerance)) < len(base):
            failures.append("note_velocity_limit")
        if not any(reason in failures for reason in ["note_offset_limit", "note_velocity_limit"]):
            failures.append("joint_note_limits")

    only_python = len(python_notes) - len(pairs)
    only_swift = len(swift_notes) - len(pairs)
    status = ("both_empty" if not python_notes and not swift_notes else
              "no_matches" if not pairs else
              "unmatched_notes" if only_python or only_swift else "all_notes_matched")
    report = dict(status=status, policy_version=PARITY_POLICY_VERSION,
                  matcher="maximum_cardinality", onset_tolerance_ms=onset_tolerance * 1000,
                  onset_boundary="strict", pitch_match="exact",
                  python_notes=len(python_notes), swift_notes=len(swift_notes),
                  matched=len(pairs), only_python=only_python, only_swift=only_swift,
                  onset_max_ms=None, onset_mean_ms=None, offset_max_ms=None,
                  velocity_identical_fraction=None, velocity_max_diff=None,
                  offset_tolerance_ms=None if offset_tolerance is None else offset_tolerance * 1000,
                  velocity_tolerance=velocity_tolerance, max_unmatched_python=max_unmatched_python,
                  max_unmatched_swift=max_unmatched_swift, gate_matched=len(eligible),
                  diagnostics_pairing="gate_eligible" if len(eligible) == len(base) else "onset_only",
                  evaluation_scope="notes" if offset_tolerance is not None or velocity_tolerance is not None else "onset_only",
                  passed=not failures, failures=failures)
    if pairs:
        onsets = [abs(a[0] - b[0]) * 1000 for a, b in pairs]
        offsets = [abs(a[1] - b[1]) * 1000 for a, b in pairs]
        velocities = [abs(a[3] - b[3]) for a, b in pairs]
        report.update(onset_max_ms=max(onsets), onset_mean_ms=fmean(onsets),
                      offset_max_ms=max(offsets),
                      velocity_identical_fraction=fmean(value == 0 for value in velocities),
                      velocity_max_diff=max(velocities))
    return report


def compare_sustain(python_spans, swift_spans, *, tolerance=DEFAULT_PEDAL_TOLERANCE):
    limit(tolerance, "sustain tolerance")
    validate_intervals(python_spans, context="Python sustain")
    validate_intervals(swift_spans, context="Swift sustain")
    adjacency = [[j for j, b in enumerate(swift_spans)
                  if within_time(abs(a[0] - b[0]), tolerance) and within_time(abs(a[1] - b[1]), tolerance)]
                 for a in python_spans]
    pairs = maximum_matching(adjacency, len(swift_spans))
    passed = len(pairs) == len(python_spans) == len(swift_spans)
    return dict(checked=True, passed=passed, python_spans=len(python_spans), swift_spans=len(swift_spans),
                matched=len(pairs), tolerance_ms=tolerance * 1000, boundary="inclusive",
                onset_max_ms=max((abs(python_spans[i][0] - swift_spans[j][0]) * 1000 for i, j in pairs), default=None),
                offset_max_ms=max((abs(python_spans[i][1] - swift_spans[j][1]) * 1000 for i, j in pairs), default=None))


def load_features(path):
    with open(path, "rb") as source:
        payload = source.read()
    if len(payload) % 4:
        raise ValueError(f"{path}: incomplete little-endian float32 value")
    values = array("f")
    if values.itemsize != 4:
        raise ValueError("this host does not provide 32-bit C floats")
    values.frombytes(payload)
    if sys.byteorder != "little":
        values.byteswap()
    if any(not math.isfinite(value) for value in values):
        raise ValueError(f"{path}: features must be finite")
    return values


def compare_features(python_values, swift_values, *, max_abs=DEFAULT_FEATURE_MAX_ABS,
                     mean_abs=DEFAULT_FEATURE_MEAN_ABS):
    limit(max_abs, "feature maximum error")
    limit(mean_abs, "feature mean error")
    for values in [python_values, swift_values]:
        for value in values:
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise ValueError("features must be finite numeric values")
            limit(abs(value), "feature magnitude")
    same_shape = len(python_values) == len(swift_values)
    report = dict(checked=True, passed=False, python_values=len(python_values), swift_values=len(swift_values),
                  shape_equal=same_shape, max_abs=None, mean_abs=None,
                  max_abs_limit=max_abs, mean_abs_limit=mean_abs, failure=None)
    if not same_shape:
        report["failure"] = "feature_shape"
    elif not python_values:
        report["failure"] = "empty_features"
    else:
        report["max_abs"] = max(abs(a - b) for a, b in zip(python_values, swift_values))
        report["mean_abs"] = math.fsum(abs(a - b) for a, b in zip(python_values, swift_values)) / len(python_values)
        report["passed"] = report["max_abs"] <= max_abs and report["mean_abs"] <= mean_abs
        if not report["passed"]:
            report["failure"] = "feature_error_limit"
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("python_csv")
    parser.add_argument("swift_csv")
    parser.add_argument("--json", action="store_true", help="print a machine-readable report")
    parser.add_argument("--onset-tolerance-ms", type=float, default=30)
    parser.add_argument("--offset-tolerance-ms", type=float, default=5)
    parser.add_argument("--velocity-tolerance", type=float, default=1)
    parser.add_argument("--max-unmatched-python", type=int, default=0)
    parser.add_argument("--max-unmatched-swift", type=int, default=0)
    parser.add_argument("--onset-only", action="store_true", help="disable note offset/velocity gates explicitly")
    parser.add_argument("--python-sustain")
    parser.add_argument("--swift-sustain")
    parser.add_argument("--require-sustain", action="store_true")
    parser.add_argument("--pedal-tolerance-ms", type=float, default=5)
    parser.add_argument("--python-features")
    parser.add_argument("--swift-features")
    parser.add_argument("--require-features", action="store_true")
    parser.add_argument("--feature-max-abs", type=float, default=DEFAULT_FEATURE_MAX_ABS)
    parser.add_argument("--feature-mean-abs", type=float, default=DEFAULT_FEATURE_MEAN_ABS)
    args = parser.parse_args(argv)
    for name, a, b, required in [("sustain", args.python_sustain, args.swift_sustain, args.require_sustain),
                                  ("features", args.python_features, args.swift_features, args.require_features)]:
        if bool(a) != bool(b) or (required and not (a and b)):
            parser.error(f"{name} comparison requires both Python and Swift files")
    try:
        for name, value in [("offset tolerance", args.offset_tolerance_ms), ("velocity tolerance", args.velocity_tolerance),
                            ("pedal tolerance", args.pedal_tolerance_ms), ("feature maximum error", args.feature_max_abs),
                            ("feature mean error", args.feature_mean_abs)]:
            limit(value, name)
        report = compare(load(args.python_csv), load(args.swift_csv), onset_tolerance=args.onset_tolerance_ms / 1000,
                         offset_tolerance=None if args.onset_only else args.offset_tolerance_ms / 1000,
                         velocity_tolerance=None if args.onset_only else args.velocity_tolerance,
                         max_unmatched_python=args.max_unmatched_python, max_unmatched_swift=args.max_unmatched_swift)
        report["sustain"] = dict(checked=False, passed=None, status="not_supplied")
        report["features"] = dict(checked=False, passed=None, status="not_supplied")
        if args.python_sustain:
            report["sustain"] = compare_sustain(load_interval_csv(args.python_sustain), load_interval_csv(args.swift_sustain),
                                                  tolerance=args.pedal_tolerance_ms / 1000)
            if not report["sustain"]["passed"]:
                report["failures"].append("sustain_limit_or_count")
        if args.python_features:
            report["features"] = compare_features(load_features(args.python_features), load_features(args.swift_features),
                                                    max_abs=args.feature_max_abs, mean_abs=args.feature_mean_abs)
            if not report["features"]["passed"]:
                report["failures"].append(report["features"]["failure"])
        report["passed"] = not report["failures"]
    except (OSError, ValueError) as error:
        parser.error(str(error))
    if args.json:
        print(json.dumps(report, sort_keys=True, allow_nan=False))
    else:
        print(f"python {report['python_notes']} / swift {report['swift_notes']} notes; "
              f"matched {report['matched']}; only-python {report['only_python']}, "
              f"only-swift {report['only_swift']}")
        if report["matched"]:
            print(f"  onset |diff| ms: max {report['onset_max_ms']:.3f} "
                  f"mean {report['onset_mean_ms']:.4f} | offset |diff| ms: "
                  f"max {report['offset_max_ms']:.3f} | velocity identical "
                  f"{report['velocity_identical_fraction']:.1%} "
                  f"(max diff {report['velocity_max_diff']:.0f})")
        else:
            print(f"  {report['status']}: timing and velocity statistics are not applicable")
        print(f"  {'PASS' if report['passed'] else 'FAIL'}: {report['evaluation_scope']} "
              f"(sustain checked: {report['sustain']['checked']}; features checked: {report['features']['checked']})")
        if report["failures"]:
            print("  failed gates: " + ", ".join(report["failures"]))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
