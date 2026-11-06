"""Host event contracts. Times are seconds; note dynamics are MIDI velocity.

These validators reject malformed events without silently clipping or merging.
They do not change the app's runtime NoteEvent type or its commit boundaries.
"""

import csv
import math


def _number(value, context):
    try:
        valid = not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value)
    except OverflowError:
        valid = False
    if not valid:
        raise ValueError(f"{context}: expected a finite number")
    return value


def validate_intervals(intervals, *, duration=None, context="intervals"):
    if duration is not None:
        _number(duration, f"{context} duration")
        if duration < 0:
            raise ValueError(f"{context}: duration must be nonnegative")
    for index, interval in enumerate(intervals):
        where = f"{context}[{index}]"
        if len(interval) != 2:
            raise ValueError(f"{where}: expected start,end")
        start, end = (_number(value, where) for value in interval)
        if start < 0 or end <= start:
            raise ValueError(f"{where}: require 0 <= start < end")
        if duration is not None and end > duration:
            raise ValueError(f"{where}: end exceeds declared duration {duration}")
    return intervals


def validate_notes(notes, *, pitch_min=0, pitch_max=127, duration=None,
                   overlap_policy="allow", context="notes"):
    if (type(pitch_min) is not int or type(pitch_max) is not int or
            not 0 <= pitch_min <= pitch_max <= 127):
        raise ValueError(f"{context}: invalid supported MIDI pitch range")
    if overlap_policy not in {"allow", "reject_same_pitch"}:
        raise ValueError(f"{context}: unknown overlap policy {overlap_policy!r}")
    intervals = []
    by_pitch = {}
    for index, note in enumerate(notes):
        where = f"{context}[{index}]"
        if len(note) != 4:
            raise ValueError(f"{where}: expected start,end,pitch,velocity")
        start, end, pitch, velocity = (_number(value, where) for value in note)
        if pitch != int(pitch) or not pitch_min <= pitch <= pitch_max:
            raise ValueError(f"{where}: pitch must be an integer in {pitch_min}...{pitch_max}")
        if velocity != int(velocity) or not 0 <= velocity <= 127:
            raise ValueError(f"{where}: velocity must be an integer in 0...127 (not amplitude)")
        intervals.append((start, end))
        by_pitch.setdefault(int(pitch), []).append((start, end, index))
    validate_intervals(intervals, duration=duration, context=context)
    if overlap_policy == "reject_same_pitch":
        for pitch, spans in by_pitch.items():
            latest_end = -1.0
            for start, end, index in sorted(spans):
                if start < latest_end:
                    raise ValueError(f"{context}[{index}]: overlapping pitch {pitch}")
                latest_end = max(latest_end, end)
    return notes


def load_note_csv(path, *, pitch_min=21, pitch_max=108, duration=None):
    notes = []
    with open(path, encoding="utf-8", newline="") as source:
        for line_number, fields in enumerate(csv.reader(source), 1):
            if not fields or (len(fields) == 1 and not fields[0].strip()):
                continue
            where = f"{path}:{line_number}"
            try:
                note = tuple(float(value) for value in fields)
                validate_notes([note], pitch_min=pitch_min, pitch_max=pitch_max,
                               duration=duration, context=where)
            except ValueError as error:
                raise ValueError(f"{where}: invalid note: {error}") from error
            notes.append(note)
    return notes


def load_interval_csv(path, *, duration=None):
    intervals = []
    with open(path, encoding="utf-8", newline="") as source:
        for line_number, fields in enumerate(csv.reader(source), 1):
            if not fields or (len(fields) == 1 and not fields[0].strip()):
                continue
            where = f"{path}:{line_number}"
            try:
                span = tuple(float(value) for value in fields)
                validate_intervals([span], duration=duration, context=where)
            except ValueError as error:
                raise ValueError(f"{where}: invalid interval: {error}") from error
            intervals.append(span)
    return intervals
