"""Tempo-aware performance MIDI and Semitone JSON/CSV readers."""
from collections import defaultdict, deque
from dataclasses import asdict, replace
from pathlib import Path
import csv
import hashlib
import json
import math
import mido
from .models import Note, Pedal, Performance

def load_json_bytes(payload):
    """Reject ambiguous/nonfinite JSON before interpreting event contracts."""
    def pairs(values):
        out = {}
        for key, value in values:
            if key in out:
                raise ValueError(f"duplicate JSON key: {key}")
            out[key] = value
        return out
    def number(value):
        result = float(value)
        if not math.isfinite(result):
            raise ValueError("nonfinite JSON number")
        return result
    def constant(value):
        raise ValueError(f"nonfinite JSON number: {value}")
    return json.loads(payload, object_pairs_hook=pairs, parse_float=number, parse_constant=constant)

def load_json(path):
    return load_json_bytes(Path(path).read_bytes())

def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()

def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     allow_nan=False).encode()).hexdigest()

def read_midi(path, *, offset_semantics="key_release"):
    midi = mido.MidiFile(path)
    if midi.type == 2 or midi.ticks_per_beat <= 0:
        raise ValueError("asynchronous type-2 and SMPTE MIDI are not supported")
    active, down = defaultdict(deque), {}
    notes, pedals, warnings = [], [], []
    now, tempo = 0.0, 500000
    for msg in mido.merge_tracks(midi.tracks):
        now += mido.tick2second(msg.time, midi.ticks_per_beat, tempo)
        if msg.type == "set_tempo":
            tempo = msg.tempo
        elif msg.type in ("note_on", "note_off") and msg.channel != 9:
            key = (msg.channel, msg.note)
            if msg.type == "note_on" and msg.velocity > 0:
                active[key].append((now, msg.velocity))
            elif active[key]:
                start, velocity = active[key].popleft()
                if now > start:
                    notes.append(Note(start, now, msg.note, velocity, msg.channel))
                else:
                    warnings.append("zero-duration MIDI note omitted")
            else:
                warnings.append("unmatched MIDI note-off")
        elif msg.type == "control_change" and msg.control in (64, 67) and msg.channel != 9:
            key = (msg.channel, msg.control)
            if msg.value >= 64:
                down.setdefault(key, now)
            elif key in down:
                start = down.pop(key)
                if now > start:
                    pedals.append(Pedal(start, now, msg.control, msg.channel))
    if any(active.values()):
        raise ValueError("MIDI contains unterminated notes; repair labels before evaluation")
    for (channel, cc), start in down.items():
        if now > start:
            pedals.append(Pedal(start, now, cc, channel))
            warnings.append("pedal down at MIDI end; closed at end-of-track")
    return Performance(notes, pedals, now if now > 0 else None, offset_semantics,
                       {"source": str(path), "warnings": warnings, "velocity_semantics": "midi_velocity"}, {64, 67})

def read_json(path):
    raw = load_json(path)
    if not isinstance(raw, dict) or type(raw.get("schema_version", 1)) is not int or raw.get("schema_version", 1) != 1:
        raise ValueError("expected prediction object with schema_version 1")
    def field(row, *keys, default=None):
        for key in keys:
            if key in row:
                return row[key]
        return default
    if "notes" not in raw or not isinstance(raw["notes"], list):
        raise ValueError("prediction JSON must contain a notes array")
    meta = {**raw.get("metadata", {}), **raw.get("prediction", {})}
    normalized_velocity = meta.get("velocity_semantics") == "normalized_midi_velocity"
    notes = []
    for row in raw["notes"]:
        velocity = field(row, "velocity", "velocity_midi")
        if velocity is None and "amplitude" in row and normalized_velocity:
            velocity = float(row["amplitude"]) * 127
        notes.append(Note(field(row, "onset", "onset_seconds", "startTime"),
                          field(row, "offset", "offset_seconds", "endTime"),
                          field(row, "pitch", "pitch_midi"), velocity, row.get("channel", 0)))
    pedals = [Pedal(field(p, "onset", "start_seconds", "startTime"),
                    field(p, "offset", "end_seconds", "endTime"),
                    p.get("controller", 64), p.get("channel", 0)) for p in raw.get("pedals", [])]
    if normalized_velocity:
        meta["velocity_semantics"] = "midi_velocity"
    if isinstance(raw.get("audio"), dict):
        meta["audio_sha256"] = raw["audio"].get("sha256")
    coverage = raw.get("pedal_controllers")
    if coverage is None:
        coverage = [64] if "pedals" in raw else []
    return Performance(notes, pedals, raw.get("duration_seconds", raw.get("duration")),
                       raw.get("offset_semantics", meta.get("offset_semantics", "unspecified")),
                       meta, set(coverage))

def read_csv(path, *, offset_semantics="unspecified", sustain_path=None):
    # Semitone's existing harness writes headerless onset,offset,pitch,velocity.
    with Path(path).open(newline="") as stream:
        rows = list(csv.reader(stream))
    if rows and rows[0] and rows[0][0].strip().lower() in ("onset", "onset_seconds", "starttime"):
        rows = rows[1:]
    notes = []
    for index, row in enumerate(rows, 1):
        if not row or not any(x.strip() for x in row):
            continue
        if len(row) not in (3, 4):
            raise ValueError(f"{path}:{index}: expected onset,offset,pitch[,velocity]")
        notes.append(Note(float(row[0]), float(row[1]), float(row[2]), float(row[3]) if len(row) == 4 else None))
    pedals = []
    if sustain_path:
        with Path(sustain_path).open(newline="") as stream:
            for index, row in enumerate(csv.reader(stream), 1):
                if row:
                    if len(row) != 2:
                        raise ValueError(f"{sustain_path}:{index}: expected onset,offset")
                    pedals.append(Pedal(float(row[0]), float(row[1])))
    return Performance(notes, pedals, offset_semantics=offset_semantics,
                       pedal_controllers={64} if sustain_path else set())

def load_performance(path, *, offset_semantics=None):
    path = Path(path)
    if path.suffix.lower() in (".mid", ".midi"):
        return read_midi(path, offset_semantics=offset_semantics or "unspecified")
    if path.suffix.lower() == ".csv":
        return read_csv(path, offset_semantics=offset_semantics or "unspecified")
    if path.suffix.lower() != ".json":
        raise ValueError(f"unsupported prediction/label format: {path.suffix}")
    result = read_json(path)
    if offset_semantics:
        if result.offset_semantics not in ("unspecified", offset_semantics):
            raise ValueError("offset semantics override conflicts with file declaration")
        result.offset_semantics = offset_semantics
    return result

def write_performance(performance, path):
    value = {"schema_version": 1, "offset_semantics": performance.offset_semantics,
             "duration_seconds": performance.duration, "notes": [asdict(n) for n in performance.notes],
             "pedals": [asdict(p) for p in performance.pedals],
             "pedal_controllers": sorted(performance.pedal_controllers), "metadata": performance.metadata}
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")

def shift_reference(performance, seconds):
    """Apply a predeclared label-to-audio offset. Never align to predictions."""
    shifted = []
    for n in performance.notes:
        if n.onset + seconds < 0:
            raise ValueError("alignment shifts a reference onset before audio start")
        shifted.append(replace(n, onset=n.onset + seconds, offset=n.offset + seconds))
    pedals = [replace(p, onset=p.onset + seconds, offset=p.offset + seconds)
              for p in performance.pedals]
    return Performance(shifted, pedals, performance.duration, performance.offset_semantics,
                       performance.metadata, performance.pedal_controllers)
