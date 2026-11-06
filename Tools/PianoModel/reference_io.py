"""Clip reference events exactly at the app's audio end before host checks."""
import math
from numbers import Real

try:
    from .event_contracts import validate_intervals, validate_notes
except ImportError:
    from event_contracts import validate_intervals, validate_notes


def clipped_reference_events(events, audio_end):
    if isinstance(audio_end, bool) or not isinstance(audio_end, (int, float)) or not math.isfinite(audio_end) or audio_end < 0:
        raise ValueError("audio duration must be finite and nonnegative")
    notes, sustain = [], []
    for event in events:
        # Match PianoTranscriber's documented hard-stop clipping: discard
        # starts at/after EOF and cap ends. Do not shift onsets or waive other
        # timing/dynamic differences to make a port appear equivalent.
        def finite(value):
            if isinstance(value, bool) or not isinstance(value, Real):
                raise ValueError("reference events must contain numeric values")
            try:
                converted = float(value)
            except (OverflowError, ValueError) as error:
                raise ValueError("reference events must be finite") from error
            if not math.isfinite(converted):
                raise ValueError("reference events must be finite")
            return converted
        start, end, pitch = (finite(value) for value in [event.start, event.end, event.pitch])
        if start >= audio_end:
            continue
        end = min(end, audio_end)
        if pitch == -64:
            sustain.append((start, end))
        elif pitch == -67:
            # The current app/harness do not expose soft pedal (SEM-030).
            continue
        else:
            notes.append((start, end, pitch, finite(event.velocity)))
    validate_notes(notes, pitch_min=21, pitch_max=108, duration=audio_end, context="clipped Python notes")
    validate_intervals(sustain, duration=audio_end, context="clipped Python sustain")
    return sorted(notes), sorted(sustain)
