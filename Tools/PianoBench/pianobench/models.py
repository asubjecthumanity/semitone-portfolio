"""Explicit event contracts. Times are seconds on the original audio timeline."""
from dataclasses import dataclass, field, replace
import math

SEMANTICS = {"key_release", "pedal_extended", "unspecified"}

def finite(value, name):
    if isinstance(value, bool):
        raise ValueError(f"{name} must be numeric, not boolean")
    try:
        value = float(value)
    except (TypeError, ValueError, OverflowError) as error:
        raise ValueError(f"{name} must be a finite number") from error
    if not math.isfinite(value):
        raise ValueError(f"{name} must be finite")
    return value

@dataclass(frozen=True)
class Note:
    onset: float
    offset: float
    pitch: int
    velocity: float | None = None
    channel: int = 0

    def __post_init__(self):
        for name in ("onset", "offset"):
            object.__setattr__(self, name, finite(getattr(self, name), name))
        if self.onset < 0 or self.offset <= self.onset:
            raise ValueError(f"invalid note interval [{self.onset}, {self.offset}]")
        if isinstance(self.pitch, bool) or int(self.pitch) != self.pitch or not 0 <= self.pitch <= 127:
            raise ValueError(f"invalid MIDI pitch: {self.pitch}")
        object.__setattr__(self, "pitch", int(self.pitch))
        if isinstance(self.channel, bool) or int(self.channel) != self.channel or not 0 <= self.channel <= 15:
            raise ValueError("channel must be 0..15")
        if self.velocity is not None:
            object.__setattr__(self, "velocity", finite(self.velocity, "velocity"))
            if not 0 <= self.velocity <= 127:
                raise ValueError("velocity must be 0..127")

@dataclass(frozen=True)
class Pedal:
    onset: float
    offset: float
    controller: int = 64
    channel: int = 0

    def __post_init__(self):
        object.__setattr__(self, "onset", finite(self.onset, "pedal onset"))
        object.__setattr__(self, "offset", finite(self.offset, "pedal offset"))
        if self.onset < 0 or self.offset <= self.onset:
            raise ValueError("invalid pedal interval")
        if self.controller not in (64, 67):
            raise ValueError("only CC64 sustain and CC67 soft pedal are supported")
        if isinstance(self.channel, bool) or int(self.channel) != self.channel or not 0 <= self.channel <= 15:
            raise ValueError("pedal channel must be 0..15")

@dataclass
class Performance:
    notes: list[Note]
    pedals: list[Pedal] = field(default_factory=list)
    duration: float | None = None
    offset_semantics: str = "unspecified"
    metadata: dict = field(default_factory=dict)
    # None means pedal annotations were not supplied, rather than pedal always up.
    pedal_controllers: set[int] = field(default_factory=set)

    def __post_init__(self):
        if self.offset_semantics not in SEMANTICS:
            raise ValueError(f"unknown offset semantics: {self.offset_semantics}")
        if self.duration is not None:
            self.duration = finite(self.duration, "duration")
            if self.duration <= 0:
                raise ValueError("duration must be positive")
        self.notes = sorted(self.notes, key=lambda n: (n.onset, n.pitch, n.offset))
        self.pedals = sorted(self.pedals, key=lambda p: (p.onset, p.controller))
        self.pedal_controllers = set(self.pedal_controllers) | {p.controller for p in self.pedals}
        if not self.pedal_controllers <= {64, 67}:
            raise ValueError("invalid pedal controller coverage")

def pedal_extended(performance: Performance) -> Performance:
    """Derive MIDI sustain occupancy; key release and acoustic decay stay distinct.

    Extend only if CC64 is down at release, and cap at the next same-key attack.
    This binary-controller view does not model half-pedal, resonance, or decay.
    """
    if performance.offset_semantics == "pedal_extended":
        return performance
    if performance.offset_semantics != "key_release":
        raise ValueError("pedal extension requires key-release notes")
    from bisect import bisect_right
    spans, onsets = {}, {}
    for p in performance.pedals:
        if p.controller == 64:
            spans.setdefault(p.channel, []).append(p)
    for n in performance.notes:
        onsets.setdefault((n.channel, n.pitch), []).append(n.onset)
    notes = []
    for n in performance.notes:
        end = n.offset
        for p in spans.get(n.channel, []):
            if p.onset <= n.offset < p.offset:
                end = max(end, p.offset)
        times = onsets[(n.channel, n.pitch)]
        next_index = bisect_right(times, n.onset)
        if end > n.offset and next_index < len(times):
            # Never shorten the original key-release interval.
            end = max(n.offset, min(end, times[next_index]))
        notes.append(replace(n, offset=end))
    return Performance(notes, performance.pedals, performance.duration, "pedal_extended",
                       dict(performance.metadata), performance.pedal_controllers)
