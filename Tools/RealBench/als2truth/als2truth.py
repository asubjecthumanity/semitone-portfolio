#!/usr/bin/env python3
"""als2truth: an Ableton Live set (.als) -> a RealBench answer key ("realbench-truth-1").

Python 3 standard library only. The set is only read (an .als file is gzip-compressed XML).

  python3 Tools/RealBench/als2truth/als2truth.py SONG.als --out DIR [options]

Writes into DIR:
  truth.json      realbench-truth-1 key: notes (part = role, instrument = track name), beats and
                  downbeats from the tempo map, chords (Harte labels, one per beat, from the
                  chord-role tracks), no drums section. Flagged notes go to "unreliableNotes"
                  (RealBench ignores that key). Same-pitch notes starting within 50 ms on different tracks
                  (layered unisons) are merged into one note unless --keep-unisons is given.
  roles.json      one entry per MIDI track: the suggested role (melody, countermelody, chords,
                  bass, ignore) and why. Edit it and run again: an existing DIR/roles.json (or
                  --roles FILE) is honoured.
  report.txt/.json per-track note counts, pitch range, polyphony, devices, transposes applied
                  and flags, plus the tracks that need post-FX MIDI.
  midi/<role>.mid one file per role (one MIDI track per Ableton track) on the set's tempo map;
                  midi/unreliable.mid holds the flagged raw notes.

What is read: tempo and tempo automation, time signature (and its automation), arrangement MIDI
clips (position, length, loop on/off, loop start/end, start marker, clip-local note times,
note probability, velocity, deactivated notes, deactivated clips), track mute (and mute
automation), solo, freeze, group tracks, and every device on the track (racks recursively, with
key/velocity/chain-selector zones, chain mutes, macro mappings and macro automation).

Sounding pitch: instrument and MIDI-effect transposes are applied (Operator, Simpler, Sampler,
Wavetable, Drift, Meld, Analog, Tension and other "Octave/Transpose" instruments; the Pitch and
Scale MIDI effects), with rack macros and automation evaluated at each note's onset. For a
multi-oscillator patch (Wavetable, Drift, Meld, Analog) see pick_voice(); for Operator's ratios
and pitch envelope see Resolver._operator(). Layered rack chains sounding at different pitches
give the lowest one. Every voice and chain is listed in the report, and roles.json can override a
track's transpose. Per-note (MPE) pitch bend at a note's onset is applied.

Unreliable notes are written separately (truth.json "unreliableNotes", midi/unreliable.mid):
- "post-FX MIDI needed": MIDI effects that make the played notes differ from the clip notes in
  ways this tool cannot reproduce (Arpeggiator, Chord, Random, Note Echo, Note Length in note-off
  mode, a Strum rack and other Max for Live MIDI effects);
- "check by ear": notes whose sound this tool cannot pin down, where recording post-FX MIDI would
  not help: an Operator pitch envelope that has not settled, a per-note bend between semitones,
  a channel pitch-bend clip envelope at the onset, and Max devices (Expression Control, LFO MIDI,
  ...) whose mappings, read from the set's object ids and followed through rack macros, reach a
  pitch parameter. roles.json "trust" keeps them after listening.
"""
import argparse
import bisect
import collections
import gzip
import json
import math
import os
import re
import statistics
import struct
import sys
import xml.etree.ElementTree as ET

TOOL_VERSION = 2
ROLES = ("melody", "countermelody", "chords", "bass", "ignore")
FAR_PAST = -63072000.0

# ---------------------------------------------------------------------------------------------
# XML helpers


def attr(el, path=None, default=None):
    """Value="..." of el (or of el.find(path))."""
    x = el.find(path) if path else el
    if x is None:
        return default
    v = x.get("Value")
    return default if v is None else v


def fnum(s, default=0.0):
    try:
        return float(s)
    except (TypeError, ValueError):
        return default


def parse_value(s):
    if s == "true":
        return True
    if s == "false":
        return False
    return fnum(s)


def load_set(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    root = ET.fromstring(data)
    if root.tag != "Ableton" or root.find("LiveSet") is None:
        raise SystemExit(f"{path}: not an Ableton Live set")
    return root


# ---------------------------------------------------------------------------------------------
# Automation and parameter values


class Automation:
    """Arrangement automation envelopes by target id, and parameter values at a beat.

    Float envelopes ramp linearly between breakpoints (curved segments are read as straight
    lines); bool and enum envelopes step. A parameter mapped to a rack macro (KeyMidi channel 16)
    takes the macro's value (itself possibly automated or mapped) through the mapping range."""

    def __init__(self, liveset):
        self.env = {}
        self.curved = set()
        for env in liveset.iter("AutomationEnvelope"):
            pid = attr(env, "EnvelopeTarget/PointeeId")
            evs = env.find("Automation/Events")
            if pid is None or evs is None:
                continue
            events, curved = parse_events(evs)
            if curved:
                self.curved.add(pid)
            if events:
                self.env[pid] = (events, [x[0] for x in events])
        self._macro_rack = {}

    def target_id(self, el):
        at = el.find("AutomationTarget")
        return at.get("Id") if at is not None else None

    def is_automated(self, el):
        return self.target_id(el) in self.env

    def events(self, el):
        tid = self.target_id(el)
        return self.env[tid][0] if tid in self.env else None

    @staticmethod
    def eval_events(env, beat):
        events, times = env
        i = bisect.bisect_right(times, beat) - 1
        if i < 0:
            return events[0][1]
        t0, v0, kind = events[i]
        if kind != "float" or i + 1 >= len(events):
            return v0
        t1, v1, _ = events[i + 1]
        if t1 <= t0:
            return v0
        return v0 + (v1 - v0) * (beat - t0) / (t1 - t0)

    def macro_source(self, el, racks):
        """(depth, macro element) of the rack macro that drives el, or None. A mapped parameter
        has <KeyMidi> on channel 16 with the macro index; the macro belongs to the innermost
        enclosing rack. (The stored Manual of a mapped parameter is stale, so the macro decides.)"""
        km = el.find("KeyMidi")
        if km is None or attr(km, "Channel") != "16" or not racks:
            return None
        key = id(el)
        if key not in self._macro_rack:
            k = int(fnum(attr(km, "NoteOrController")))
            found = None
            for depth in range(len(racks) - 1, -1, -1):
                macro = racks[depth].find(f"MacroControls.{k}")
                if macro is not None:
                    found = (depth, macro)
                    break
            self._macro_rack[key] = found
        return self._macro_rack[key]

    @staticmethod
    def _map(el, mv):
        rng = el.find("MidiControllerRange")
        lo, hi = (fnum(attr(rng, "Min")), fnum(attr(rng, "Max"))) if rng is not None else (0.0, 127.0)
        return lo + (hi - lo) * float(mv) / 127.0

    def value(self, el, beat, racks=()):
        if el is None:
            return None
        src = self.macro_source(el, racks)
        if src is not None:
            depth, macro = src
            mv = self.value(macro, beat, racks[:depth])
            manual = parse_value(attr(el, "Manual"))
            if isinstance(manual, bool):
                return float(mv) >= 63.5
            return self._map(el, mv)
        tid = self.target_id(el)
        if tid in self.env:
            return self.eval_events(self.env[tid], beat)
        return parse_value(attr(el, "Manual"))

    def varies(self, el, racks=()):
        """True when the parameter changes over the arrangement (automation or an automated macro)."""
        if el is None:
            return False
        src = self.macro_source(el, racks)
        if src is not None:
            depth, macro = src
            return self.varies(macro, racks[:depth])
        return self.is_automated(el)

    def false_spans(self, el, racks=()):
        """Beat spans where a bool parameter (track or chain activator) is off."""
        if el is None:
            return []
        if not self.varies(el, racks):
            return [(-math.inf, math.inf)] if self.value(el, 0.0, racks) is False else []
        events = self.events(el)
        if events is None:  # macro-driven: sample macro breakpoints
            depth, macro = self.macro_source(el, racks)
            events = self.events(macro) or []
            points = sorted({t for t, _, _ in events})
        else:
            points = sorted({t for t, _, _ in events})
        spans, start = [], None
        probe = [-math.inf] + points
        for i, t in enumerate(probe):
            at = (points[0] - 1.0) if t == -math.inf else t
            on = bool(self.value(el, at, racks))
            if not on and start is None:
                start = t
            elif on and start is not None:
                spans.append((start, t))
                start = None
        if start is not None:
            spans.append((start, math.inf))
        return spans


# ---------------------------------------------------------------------------------------------
# Tempo map and meter


class TempoMap:
    """Arrangement beats (quarter notes) <-> seconds. Tempo automation ramps linearly in beats."""

    def __init__(self, bpm, events=None):
        pts = []
        if events:
            first = bpm
            for t, v, _ in events:
                if t <= 0:
                    first = v
            pts.append((0.0, float(first)))
            for t, v, _ in events:
                if t > 0:
                    pts.append((t, float(v)))
        else:
            pts.append((0.0, float(bpm)))
        self.beats = [p[0] for p in pts]
        self.bpms = [p[1] for p in pts]
        self.secs = [0.0]
        for i in range(1, len(pts)):
            self.secs.append(self.secs[-1] + self._seg(i - 1, self.beats[i] - self.beats[i - 1]))

    def _slope(self, i):
        if i + 1 < len(self.beats) and self.beats[i + 1] > self.beats[i]:
            return (self.bpms[i + 1] - self.bpms[i]) / (self.beats[i + 1] - self.beats[i])
        return 0.0

    def _seg(self, i, db):
        v0, k = self.bpms[i], self._slope(i)
        if abs(k) < 1e-12:
            return 60.0 * db / v0
        return 60.0 / k * math.log((v0 + k * db) / v0)

    def seconds(self, beat):
        if beat <= 0:
            return 60.0 * beat / self.bpms[0]
        i = bisect.bisect_right(self.beats, beat) - 1
        return self.secs[i] + self._seg(i, beat - self.beats[i])

    def beat_after(self, beat, dsec):
        """The beat dsec seconds after beat."""
        target = self.seconds(beat) + dsec
        lo, hi = beat, beat + dsec * max(self.bpms) / 60.0 + 1e-9
        for _ in range(60):
            mid = (lo + hi) / 2.0
            if self.seconds(mid) < target:
                lo = mid
            else:
                hi = mid
        return hi

    def bpm_at(self, beat):
        i = max(0, bisect.bisect_right(self.beats, beat) - 1)
        return self.bpms[i] + self._slope(i) * (beat - self.beats[i])

    @property
    def constant(self):
        return len(set(round(b, 6) for b in self.bpms)) == 1


def decode_signature(v):
    v = int(round(v))
    return v % 99 + 1, 2 ** (v // 99)


def beat_grid(signatures, end_beat):
    """[(beat, is_downbeat)] up to end_beat; compound 6/8, 9/8, 12/8 count dotted quarters."""
    sigs = sorted(signatures) or [(0.0, 4, 4)]
    if sigs[0][0] > 0:
        sigs.insert(0, (0.0, 4, 4))
    out, beat, si = [], 0.0, 0
    per_bar_first = None
    while beat <= end_beat + 1e-9:
        while si + 1 < len(sigs) and sigs[si + 1][0] <= beat + 1e-9:
            si += 1
        _, num, den = sigs[si]
        compound = den == 8 and num % 3 == 0 and num > 3
        unit = 4.0 / den * (3 if compound else 1)
        per_bar = num // 3 if compound else num
        if per_bar_first is None:
            per_bar_first = per_bar
        for i in range(per_bar):
            b = beat + i * unit
            if b > end_beat + 1e-9:
                break
            out.append((b, i == 0))
        beat += per_bar * unit
    return out, per_bar_first or 4


# ---------------------------------------------------------------------------------------------
# Devices: sounding pitch and flags

INSTRUMENT_TAGS = {
    "Operator", "OriginalSimpler", "MultiSampler", "InstrumentVector", "Drift", "InstrumentMeld",
    "UltraAnalog", "StringStudio", "Collision", "LoungeLizard", "Tension", "Electric", "Bass",
    "InstrumentGranulator", "Poli", "DrumCell", "InstrumentImpulse", "MxDeviceInstrument",
    "PluginDevice", "AuPluginDevice", "Vst3PluginDevice", "VstPluginDevice",
}
DRUM_INSTRUMENTS = {"DrumGroupDevice", "InstrumentImpulse", "DrumCell"}
RACKS = {"InstrumentGroupDevice", "MidiEffectGroupDevice", "AudioEffectGroupDevice", "DrumGroupDevice"}
# Parameters whose automation changes the sounding pitch (flagged when they vary).
PITCH_PARAM = re.compile(r"transpose|octave|oct$|semi|coarse|detune|pitch|mapping|base$|shift|usecurrentscale", re.I)
# Pitch parameters that only wobble the pitch around the note (vibrato, glide): not a pitch change.
WOBBLE_PARAM = re.compile(r"lfo|vibrato|glide|portamento|slide", re.I)
# Max for Live MIDI effects that pass the notes through unchanged and map expression (or an LFO,
# envelope or shape) to device parameters. Their notes stay in the key unless a mapping reaches a
# pitch parameter; recording their post-FX MIDI would give back the same notes.
MAPPING_MAX = {"expression control", "expression control legacy", "envelope midi", "shaper midi", "lfo midi"}
# Expression Control slots, by the id of the slot's subpatcher in the device's id references
# (MxDIdRef "obj-25::..." is slot 1). Inferred from the demo sets: each mapped slot is the one
# whose settings were edited. A reference with another prefix counts as an unknown slot.
EXPRESSION_SLOTS = {"obj-25": 1, "obj-44": 2, "obj-48": 3, "obj-54": 4}
# Expression Control sources that move with every note (the others need expression data in the clips).
ALWAYS_SOURCES = {"velocity", "keytrack", "random", "increment"}
# A note that starts within this many beats of a clip or loop boundary is on it: Live stores
# some boundary notes at -2.6e-7 by float error.
ONSET_TOL = 1e-4
# A per-note bend at the onset this far (semitones) from a whole semitone sounds between keys.
BEND_OFF_PITCH = 0.25
# Notes shorter than this (seconds) are thumps or blips, not a line.
SHORT_NOTE_S = 0.1


def mx_name(dev):
    for p in ("PatchSlot/Value/MxPatchRef/FileRef/RelativePath", "PatchSlot/Value/MxPatchRef/FileRef/Path",
              "LastPresetRef/Value/AbletonDefaultPresetRef/FileRef/RelativePath"):
        v = attr(dev, p)
        if v:
            base = v.replace("\\", "/").rstrip("/").rsplit("/", 1)[-1]
            return re.sub(r"\.(amxd|adv|adg)$", "", base)
    return ""


def device_label(dev):
    user = attr(dev, "UserName") or ""
    if dev.tag.startswith("Mx"):
        name = mx_name(dev) or "Max device"
        return f"{dev.tag}[{name}]" + (f" '{user}'" if user and user != name else "")
    return dev.tag + (f" '{user}'" if user else "")


def chain_devices(branch):
    dc = branch.find("DeviceChain")
    if dc is None:
        return []
    for c in dc:
        if c.tag.endswith("DeviceChain"):
            devs = c.find("Devices")
            if devs is not None:
                return list(devs)
    devs = dc.find("Devices")
    return list(devs) if devs is not None else []


def zone(branch, name):
    z = branch.find(f"ZoneSettings/{name}")
    if z is None:
        z = branch.find(name)
    if z is None:
        return None
    return fnum(attr(z, "Min")), fnum(attr(z, "Max"))


def db(lin):
    return 20.0 * math.log10(lin) if lin and lin > 0 else -math.inf


def pick_voice(voices):
    """voices: [(name, semitones, gain_db, is_sub)] of the enabled oscillators. Returns (offset,
    layering kind or None, rule). Voices more than 18 dB below the loudest are ignored. When the
    voices share a pitch class, the lowest main (non-sub) voice sets the octave. When they do not
    (an interval patch), a voice at an octave of the played key wins, since such patches are
    tuned so the played key names the note; otherwise the lowest main voice."""
    loudest = max(v[2] for v in voices)
    audible = [v for v in voices if v[2] >= loudest - 18.0] or voices
    mains = [v for v in audible if not v[3]] or audible
    if len({v[1] % 12 for v in audible}) == 1:
        pick = min(v[1] for v in mains)
        kind = "octave-layered" if len({v[1] for v in mains}) > 1 else None
        return pick, kind, "the lowest main oscillator"
    octv = [v for v in audible if v[1] % 12 == 0]
    if octv:
        pool = [v for v in octv if not v[3]] or octv
        return min(v[1] for v in pool), "interval-layered", "the voice at an octave of the played key"
    return min(v[1] for v in mains), "interval-layered", "the lowest main oscillator; no voice at an octave of the key"


class Flag:
    """A note about a track. post_fx: the notes differ from the clip notes and are unreliable
    until post-FX MIDI is recorded. unreliable: every note is unreliable for a reason recording
    cannot fix (check by ear, then set trust). listen: the report lists it under CHECK BY EAR."""

    def __init__(self, kind, device, detail, post_fx=False, pitch_safe=True, timing_safe=True, listen=False,
                 unreliable=False):
        self.kind, self.device, self.detail = kind, device, detail
        self.post_fx, self.pitch_safe, self.timing_safe = post_fx, pitch_safe, timing_safe
        self.unreliable = unreliable and not post_fx
        self.listen = (listen or unreliable) and not post_fx

    def to_json(self):
        return {"kind": self.kind, "device": self.device, "detail": self.detail,
                "postFxMidiNeeded": self.post_fx, "checkByEar": self.listen,
                "notesUnreliable": self.post_fx or self.unreliable, "pitchSafe": self.pitch_safe}

    def key(self):
        return (self.kind, self.device, self.detail)


def iter_params(el, prefix=""):
    """(name, element) of every parameter (an element with an AutomationTarget or a KeyMidi
    mapping) under el, not descending into rack chains (they hold other devices). The name is
    the path below el; a Max parameter (MxD...Parameter/Timeable) is named by its own Name."""
    for c in el:
        if c.tag == "Branches" or not len(c):
            continue
        p = f"{prefix}/{c.tag}" if prefix else c.tag
        if c.tag.startswith("MxD") and c.tag.endswith("Parameter") and c.find("Timeable") is not None:
            yield (attr(c, "Name") or p), c.find("Timeable")
        elif c.find("AutomationTarget") is not None or c.find("KeyMidi") is not None:
            yield p, c
        else:
            yield from iter_params(c, p)


class LomIndex:
    """Device parameters by Live object id (LomId: what Max devices store in their id references)
    and by automation target id (what clip envelopes point at)."""

    def __init__(self, liveset):
        self.by_lom, self.by_target = {}, {}
        tracks = list(liveset.find("Tracks") if liveset.find("Tracks") is not None else [])
        tracks += [x for x in (liveset.find("MasterTrack"), liveset.find("MainTrack")) if x is not None]
        for tr in tracks:
            mixer = tr.find("DeviceChain/Mixer")
            if mixer is not None:
                self._add(mixer, mixer)
            devs = tr.find("DeviceChain/DeviceChain/Devices")
            if devs is not None:
                self._walk(list(devs))

    def _walk(self, devices):
        for dev in devices:
            self._add(dev, dev)
            if dev.tag in RACKS:
                for br in dev.findall("Branches/*"):
                    mixer = br.find("MixerDevice")
                    if mixer is not None:
                        self._add(mixer, dev, "chain mixer")
                    self._walk(chain_devices(br))

    def _add(self, el, dev, prefix=""):
        for name, p in iter_params(el, prefix):
            lom = attr(p, "LomId") if p.find("LomId") is not None else None
            if lom and lom != "0":
                self.by_lom[lom] = (p, dev, name)
            at = p.find("AutomationTarget")
            if at is not None and at.get("Id"):
                self.by_target[at.get("Id")] = (p, dev, name)

    def macro_targets(self, rack, k, depth=0):
        """[(device, parameter name, element)] mapped to macro k of rack: parameters of the
        devices in its chains (not inside nested racks' chains, whose mappings name the nested
        rack's macros); a nested rack's macro mapped here is followed."""
        out = []
        if depth > 4:
            return out

        def mapped(p):
            km = p.find("KeyMidi")
            return km is not None and attr(km, "Channel") == "16" and attr(km, "NoteOrController") == str(k)

        for br in rack.findall("Branches/*"):
            mixer = br.find("MixerDevice")
            if mixer is not None:
                out += [(rack, "chain mixer " + n, p) for n, p in iter_params(mixer) if mapped(p)]
            for dev in chain_devices(br):
                for path, p in iter_params(dev):
                    if not mapped(p):
                        continue
                    m = re.match(r"MacroControls\.(\d+)$", path)
                    if dev.tag in RACKS and m:
                        out += self.macro_targets(dev, int(m.group(1)), depth + 1) or [(dev, path, p)]
                    else:
                        out.append((dev, path, p))
        return out

    def targets_of(self, dev):
        """(resolved, unresolved count) of a Max device's parameter mappings (its MxDIdRef ids):
        resolved is [(slot, via, device, parameter name, element)] with rack macros expanded
        (via names the macro); slot is the Expression Control slot, or None."""
        resolved, unresolved = [], 0
        for ref in dev.iter("MxDIdRef"):
            if attr(ref, "Property") != "id" or attr(ref, "LomId", "0") == "0":
                continue
            slot = EXPRESSION_SLOTS.get((attr(ref, "Name") or "").split("::")[0])
            hit = self.by_lom.get(attr(ref, "LomId"))
            if hit is None:
                unresolved += 1
                continue
            p, owner, name = hit
            m = re.match(r"MacroControls\.(\d+)$", name)
            if owner.tag in RACKS and m:
                k = int(m.group(1))
                via = f"{device_label(owner)} macro {k + 1}" + (
                    f" '{attr(owner, f'MacroDisplayNames.{k}')}'" if attr(owner, f"MacroDisplayNames.{k}") else "")
                targets = self.macro_targets(owner, k)
                if not targets:
                    resolved.append((slot, via, None, None, None))
                for d, n, el in targets:
                    resolved.append((slot, via, d, n, el))
            else:
                resolved.append((slot, None, owner, name, p))
        return resolved, unresolved


def mx_params(dev):
    """A Max device's parameters: {Name: (value, enum name or None)}."""
    out = {}
    for p in dev.findall("ParameterList/ParameterList/*"):
        name = attr(p, "Name")
        if not name:
            continue
        v = fnum(attr(p, "Timeable/Manual"))
        names = [attr(n, "Name") for n in p.findall("Names/Name")]
        i = int(round(v))
        out[name] = (v, names[i] if names and 0 <= i < len(names) else None)
    return out


def is_pitch_param(name):
    return bool(name) and bool(PITCH_PARAM.search(name)) and not WOBBLE_PARAM.search(name)


class Resolver:
    """Follows notes through a track's device chain: MIDI effects, racks (zones, chain mutes,
    chain selector), instruments. resolve() returns the sounding pitches for one note."""

    def __init__(self, auto, track_name, index=None):
        self.auto = auto
        self.track_name = track_name
        self.index = index
        self.flags = collections.OrderedDict()
        self.descs = collections.Counter()
        self.layers = collections.Counter()
        self.has_instrument = False
        self.drums = False
        self.slicing = False
        self.devices = []
        self.dynamic = False
        self.note_len = None  # seconds, when a Note Length effect fixes the duration
        # instrument description -> seconds until its pitch envelope settles (inf: never)
        self.sweeps = {}
        # Max mappings that reach a pitch parameter: [(device label, source or None, targets)];
        # decided once the clips are read (a source with no data in the clips moves nothing)
        self.pitch_mappings = []
        self.mpe_bend_shaper = None  # label of an MPE Control that reshapes per-note pitch bend
        self.where = []  # rack chain names around the device being resolved (for flag labels)

    def flag(self, *a, **k):
        f = Flag(*a, **k)
        self.flags.setdefault(f.key(), f)

    def v(self, el, beat, racks):
        return self.auto.value(el, beat, racks)

    def p(self, dev, path, beat, racks, default=0.0, pitch=False):
        el = dev.find(path)
        if el is None:
            return default
        if self.auto.varies(el, racks):
            self.dynamic = True
            if pitch and PITCH_PARAM.search(path):
                via = "a rack macro" if self.auto.macro_source(el, racks) else "automation"
                self.flag("automation", device_label(dev), f"{path} changes over the song ({via}); "
                          "the value at each note's onset is used")
        x = self.v(el, beat, racks)
        return default if x is None else x

    def on(self, dev, beat, racks):
        el = dev.find("On")
        if el is None:
            return True
        if self.auto.varies(el, racks):
            self.dynamic = True
        return bool(self.v(el, beat, racks))

    # --- static scan (device list for the report, flags that do not depend on the note) -----

    def scan(self, devices, depth=0, racks=(), where="track"):
        for dev in devices:
            label = device_label(dev)
            on_el = dev.find("On")
            always_off = on_el is not None and not self.auto.varies(on_el, racks) and \
                self.auto.value(on_el, 0.0, racks) is False
            self.devices.append(("  " * depth) + label + (" (off)" if always_off else ""))
            if always_off:
                continue
            tag = dev.tag
            if tag in RACKS:
                if tag == "DrumGroupDevice":
                    self.drums = True
                    continue
                for bi, br in enumerate(dev.findall("Branches/*")):
                    name = attr(br, "Name/EffectiveName") or attr(br, "Name") or f"chain {bi + 1}"
                    self.devices.append(("  " * (depth + 1)) + f"[{name}]")
                    self.scan(chain_devices(br), depth + 2, racks + (dev,), where)
                continue
            if tag in DRUM_INSTRUMENTS:
                self.drums = True
            if tag in INSTRUMENT_TAGS:
                self.has_instrument = True
            self._scan_flags(dev, tag, label, racks)

    def _scan_flags(self, dev, tag, label, racks):
        P = lambda path, d=0.0: self.p(dev, path, 0.0, racks, d)
        if tag == "MidiArpeggiator":
            steps = int(P("TransposeSteps"))
            self.flag("arpeggiator", label, "Arpeggiator re-times the held notes" +
                      (f" and transposes them ({steps} steps)" if steps else ""), post_fx=True,
                      pitch_safe=steps == 0, timing_safe=False)
        elif tag == "MidiChord":
            shifts = [int(P(f"Shift{i}")) for i in range(1, 7)]
            shifts = [s for s in shifts if s]
            self.flag("chord", label, f"Chord adds notes at {shifts or 'no'} semitones", post_fx=bool(shifts),
                      pitch_safe=not shifts)
        elif tag == "MidiRandom":
            chance = P("Chance")
            if chance > 0:
                self.flag("random", label, f"Random changes pitches (chance {chance:.2f})", post_fx=True,
                          pitch_safe=False)
        elif tag == "MidiNoteLength":
            if P("Mode") is True:
                self.flag("note-length", label, "Note Length triggers on note-off", post_fx=True,
                          timing_safe=False)
            elif P("SyncState") is True:
                self.flag("note-length", label, "Note Length sets tempo-synced durations (not modelled; offsets "
                          "unreliable)", timing_safe=True)
            else:
                self.flag("note-length", label, f"Note Length sets every note to {P('TimeLength') * P('Gate', 100.0) / 100.0:.0f} ms "
                          "(applied)", timing_safe=True)
        elif tag == "MidiVelocity":
            if int(P("Mode")) == 1 and P("Random") > 0:
                self.flag("velocity", label, "Velocity gate with random velocity drops notes at random",
                          post_fx=True, pitch_safe=True)
            elif int(P("Mode")) == 1:
                self.flag("velocity", label, "Velocity gate (applied: notes outside its range dropped)")
            if P("Random") > 0 and int(P("Mode")) != 1:
                self.flag("velocity", label, "Velocity randomised (velocities approximate)")
        elif tag == "MidiPitcher":
            if P("UseCurrentScale") is True and int(P("PitchScaleDegrees")) != 0:
                self.flag("pitch", label, "Pitch moves by scale degrees (not modelled; semitone value used)",
                          post_fx=True, pitch_safe=False)
            if int(P("Lowest")) > 0 or int(P("Range", 127)) < 127:
                self.flag("pitch", label, "Pitch range limit approximated (notes outside the range are dropped)")
        elif tag == "MidiScale":
            if P("UseCurrentScale") is True:
                self.flag("scale", label, "Scale follows the clip/Set scale (not modelled)", post_fx=True,
                          pitch_safe=False)
            elif P("Fold") is True or int(P("Lowest")) > 0 or int(P("Range", 128)) < 128:
                self.flag("scale", label, "Scale fold/range approximated")
        elif tag.startswith("Mx") and "Midi" in tag:
            name = mx_name(dev)
            low = name.lower()
            if low in MAPPING_MAX:
                self._max_mappings(dev, label, name)
            elif low == "mpe control":
                bend = mx_params(dev).get("Pitch Bend On", (None, None))[1]
                if bend in (None, "On"):
                    self.mpe_bend_shaper = label
                self.flag("max-midi", label, "Max for Live 'MPE Control' passes the notes through and reshapes their MPE "
                          + ("pressure, slide and pitch bend (a note that starts bent is unreliable)"
                             if bend in (None, "On") else "pressure and slide"))
            elif low == "cc control":
                self.flag("max-midi", label, "Max for Live 'CC Control' sends MIDI controllers (and maybe pitch bend) to the "
                          "instrument; they are not read", pitch_safe=False, unreliable=True)
            else:
                self.flag("max-midi", label, f"Max for Live MIDI effect '{name or '?'}'", post_fx=True, pitch_safe=False,
                          timing_safe=False)
        elif tag == "MxDeviceAudioEffect":
            self._max_mappings(dev, label, mx_name(dev), audio=True)
        elif tag.startswith("Midi"):
            self.flag("midi-effect", label, f"unknown MIDI effect {tag}", post_fx=True, pitch_safe=False,
                      timing_safe=False)
        elif tag in ("PluginDevice", "AuPluginDevice", "Vst3PluginDevice", "VstPluginDevice", "MxDeviceInstrument"):
            self.flag("plugin", label, "plug-in/Max instrument: transposes unknown (MIDI pitch assumed)")
        elif tag == "OriginalSimpler" and int(fnum(attr(dev, "Globals/PlaybackMode"))) == 2:
            self.slicing = True
            self.flag("slicing", label, "Simpler in Slicing mode: notes pick slices, not pitches", pitch_safe=False)
        elif tag == "GrainDelay":
            pitch = P("Pitch")
            wet = P("NewDryWet", P("DryWet", 0.0))
            if abs(pitch) >= 0.5 and wet >= 0.5:
                self.flag("audio-pitch", label, f"Grain Delay shifts pitch {pitch:+.1f} st (wet {wet:.2f}); not applied")
        elif tag in ("FrequencyShifter", "Shifter", "PitchHack"):
            self.flag("audio-pitch", label, "audio pitch shifter on the track; not applied")
        elif tag == "Vocoder":
            self.flag("audio-pitch", label, "Vocoder on the track: sounding pitch may follow its carrier")

    def _max_mappings(self, dev, label, name, audio=False):
        """A Max device that maps a modulation source (expression, an LFO, an envelope, audio) to
        device parameters. Notes pass through unchanged; only a mapping that reaches a pitch
        parameter, directly or through a rack macro, can move the pitch. Those are kept in
        pitch_mappings and decided once the clips are read."""
        what = f"Max for Live '{name or '?'}'"
        if self.index is None:
            return
        resolved, unresolved = self.index.targets_of(dev)
        if unresolved:
            self.flag("max-mapping", label, f"{what} maps {unresolved} parameter(s) that are not in the set: check "
                      "what it moves, and set trust if none is a pitch parameter", pitch_safe=False, unreliable=True)
        sources = {}
        if name.lower().startswith("expression control"):
            for pname, (_, value) in mx_params(dev).items():
                m = re.match(r"Source (\d+)$", pname)
                if m and value:
                    sources[int(m.group(1))] = value
        pitch, other = [], []
        for slot, via, d, n, _ in resolved:
            text = (f"{via} -> " if via else "") + ("nothing" if d is None else f"{device_label(d)} {n}")
            if slot and slot in sources:
                text = f"slot {slot} ({sources[slot]}): " + text
            if d is not None and is_pitch_param(n):
                pitch.append((slot, text))
            elif text not in other:
                other.append(text)
        kind = "audio" if audio else ("expression" if name.lower().startswith("expression control") else "modulator")
        for slot, text in pitch:
            self.pitch_mappings.append((label, what, sources.get(slot) if slot else None, text, kind))
        if not audio and not pitch and not unresolved:
            self.flag("max-mapping", label, f"{what} passes the notes through and maps " +
                      ("; ".join(other) if other else "nothing") + ": no pitch parameter (notes kept)")

    # --- per-note resolution ------------------------------------------------------------------

    def resolve(self, devices, pitch, vel, beat):
        """Sounding pitches (with a description) for one clip note."""
        self.note_len = None
        outs = self._chain(devices, [(pitch, vel)], beat, ())
        return outs

    def _chain(self, devices, notes, beat, racks):
        outs = []
        for dev in devices:
            if not notes:
                break
            if not self.on(dev, beat, racks):
                continue
            tag = dev.tag
            if tag == "DrumGroupDevice":
                return outs + [(p, "drum rack") for p, _ in notes]
            if tag == "InstrumentGroupDevice":
                for p, vel in notes:
                    outs += self._rack(dev, p, vel, beat, racks, instrument=True)
                return outs
            if tag == "MidiEffectGroupDevice":
                new = []
                for p, vel in notes:
                    for q in self._rack(dev, p, vel, beat, racks, instrument=False):
                        new.append(q)
                notes = new
                continue
            if tag.startswith("Midi") or (tag.startswith("Mx") and "Midi" in tag):
                notes = self._midi_effect(dev, tag, notes, beat, racks)
                continue
            if tag in INSTRUMENT_TAGS:
                off, desc = self._instrument(dev, tag, beat, racks)
                if off is None:  # silent for this note range (sampler zones handled inside)
                    off = 0
                for p, vel in notes:
                    if tag == "MultiSampler" and not self._sampler_plays(dev, p, vel):
                        continue
                    outs.append((p + off, desc))
                return outs
            # audio effects: nothing to do for pitch
        # No instrument consumed the notes (MIDI-only chain): pass them through.
        return outs + [(p, None) for p, _ in notes]

    def _rack(self, rack, pitch, vel, beat, racks, instrument):
        branches = rack.findall("Branches/*")
        soloed = [b for b in branches if attr(b, "IsSoloed") == "true"]
        sel_el = rack.find("ChainSelector")
        sel = None
        if sel_el is not None:
            if self.auto.varies(sel_el, racks):
                self.dynamic = True
            sel = self.v(sel_el, beat, racks)
        outs = []
        for b in branches:
            if soloed and b not in soloed:
                continue
            spk = b.find("MixerDevice/Speaker")
            if spk is not None:
                if self.auto.varies(spk, racks + (rack,)):
                    self.dynamic = True
                if not self.v(spk, beat, racks + (rack,)):
                    continue
            kr, vr, sr = zone(b, "KeyRange"), zone(b, "VelocityRange"), zone(b, "BranchSelectorRange")
            if kr and not (kr[0] <= pitch <= kr[1]):
                continue
            if vr and not (vr[0] <= vel <= vr[1]):
                continue
            if sr and sel is not None and not (sr[0] <= sel <= sr[1]):
                continue
            name = attr(b, "Name/EffectiveName") or attr(b, "Name") or "chain"
            if instrument:
                self.where.append(name)
                try:
                    got = self._chain(chain_devices(b), [(pitch, vel)], beat, racks + (rack,))
                finally:
                    self.where.pop()
                for q, desc in got:
                    if desc is None:  # a chain without an instrument makes no sound
                        continue
                    full = f"[{name}] {desc}"
                    if desc in self.sweeps:
                        self.sweeps[full] = self.sweeps[desc]
                    outs.append((q, full))
            else:
                outs += self._chain_midi(chain_devices(b), [(pitch, vel)], beat, racks + (rack,))
        return outs

    def _chain_midi(self, devices, notes, beat, racks):
        for dev in devices:
            if not notes:
                break
            if not self.on(dev, beat, racks):
                continue
            if dev.tag == "MidiEffectGroupDevice":
                notes = [q for p, vel in notes for q in self._rack(dev, p, vel, beat, racks, instrument=False)]
            else:
                notes = self._midi_effect(dev, dev.tag, notes, beat, racks)
        return notes

    def _midi_effect(self, dev, tag, notes, beat, racks):
        P = lambda path, d=0.0: self.p(dev, path, beat, racks, d, pitch=True)
        if tag == "MidiPitcher":
            if P("UseCurrentScale") is True and int(round(P("PitchScaleDegrees"))) != 0:
                self.flag("pitch", device_label(dev), "Pitch moves by scale degrees (not modelled; semitone value used)",
                          post_fx=True, pitch_safe=False)
            shift = int(round(P("Pitch")))
            lo, rng = int(P("Lowest")), int(P("Range", 127))
            out = []
            for p, vel in notes:
                if (lo > 0 or rng < 127) and not (lo <= p <= lo + rng):
                    continue
                out.append((p + shift, vel))
            return out
        if tag == "MidiScale":
            if P("UseCurrentScale") is True:
                self.flag("scale", device_label(dev), "Scale follows the clip/Set scale (not modelled)",
                          post_fx=True, pitch_safe=False)
                return notes
            base = int(P("Base")) % 12
            mapping = [int(round(P(f"Mapping.{i}", i))) for i in range(12)]
            tr = int(round(P("Transpose")))
            lo, rng = int(P("Lowest")), int(P("Range", 128))
            out = []
            for p, vel in notes:
                d = (p - base) % 12
                q = p - d + mapping[d] + tr
                if rng < 128 and rng >= 11:
                    while q < lo:
                        q += 12
                    while q > lo + rng:
                        q -= 12
                out.append((q, vel))
            return out
        if tag == "MidiVelocity":
            if int(P("Mode")) == 1 and P("Random") <= 0:
                lo, rng = P("Lowest", 0.0), P("Range", 127.0)
                return [(p, vel) for p, vel in notes if lo <= vel <= lo + rng]
            return notes
        if tag == "MidiNoteLength" and P("Mode") is not True and P("SyncState") is not True:
            self.note_len = P("TimeLength") * P("Gate", 100.0) / 100.0 / 1000.0
            return notes
        # Arpeggiator, Chord, Random, synced Note Length, Max devices...: flagged, notes passed raw.
        return notes

    def _sampler_plays(self, dev, pitch, vel):
        parts = dev.findall("Player/MultiSampleMap/SampleParts/MultiSamplePart")
        if not parts:
            return True
        for part in parts:
            kr, vr = part.find("KeyRange"), part.find("VelocityRange")
            if kr is not None and not (fnum(attr(kr, "Min")) <= pitch <= fnum(attr(kr, "Max"), 127)):
                continue
            if vr is not None and not (fnum(attr(vr, "Min"), 1) <= vel <= fnum(attr(vr, "Max"), 127)):
                continue
            return True
        return False

    def _instrument(self, dev, tag, beat, racks):
        """(semitone offset, description) of the instrument's sounding pitch vs the MIDI note."""
        P = lambda path, d=0.0: self.p(dev, path, beat, racks, d, pitch=True)
        name = device_label(dev)
        glob, voices, extra = 0, [], ""
        sub, sweep = 0, None
        if tag == "Operator":
            glob = int(round(P("Globals/Transpose")))
            ratios = []
            for i in range(4):
                c = P(f"Operator.{i}/Tune/Coarse", 1.0)
                fixed = P(f"Operator.{i}/Tune/FixedFrequencyOn") is True
                ratios.append("fixed" if fixed else ("0.5" if c == 0 else f"{int(c)}"))
            extra = f"; osc ratios A-D {'/'.join(ratios)}, algorithm {int(P('Globals/Algorithm')) + 1} (carriers not modelled)"
            sub, sweep, more = self._operator(P, (f"[{'/'.join(self.where)}] " if self.where else "") + name)
            extra += more
        elif tag in ("OriginalSimpler", "MultiSampler"):
            glob = int(round(P("Pitch/TransposeKey") + P("Pitch/TransposeFine") / 100.0))
        elif tag == "InstrumentVector":
            glob = int(round(P("Voice_Global_Transpose")))
            for i in (1, 2):
                if P(f"Voice_Oscillator{i}_On") is True:
                    voices.append((f"osc{i}", int(round(P(f"Voice_Oscillator{i}_Pitch_Transpose"))),
                                   db(P(f"Voice_Oscillator{i}_Gain", 1.0)), False))
            if P("Voice_SubOscillator_On") is True:
                voices.append(("sub", -12 * (1 + int(P("Voice_SubOscillator_Transpose"))),
                               db(P("Voice_SubOscillator_Gain", 0.5)), True))
        elif tag == "Drift":
            glob = int(round(P("Global_Transpose")))
            if P("Mixer_OscillatorOn1", True) is True:
                voices.append(("osc1", 12 * int(round(P("Oscillator1_Transpose"))), db(P("Mixer_OscillatorGain1", 1.0)), False))
            if P("Mixer_OscillatorOn2", True) is True:
                det = P("Oscillator2_Detune")
                voices.append(("osc2", 12 * int(round(P("Oscillator2_Transpose"))) + (int(round(det)) if abs(det) >= 0.5 else 0),
                               db(P("Mixer_OscillatorGain2", 1.0)), False))
        elif tag == "InstrumentMeld":
            for e in ("A", "B"):
                pre = f"MeldVoice_Engine{e}_"
                if P(pre + "On", True) is not True:
                    continue
                if P(pre + "Oscillator_Pitch_Keytracking", True) is False:
                    self.flag("pitch", name, f"Meld engine {e} ignores the played key")
                if int(P(pre + "Oscillator_Pitch_TransposeScaleDegrees")) != 0:
                    self.flag("pitch", name, f"Meld engine {e} transposes by scale degrees (not modelled)",
                              post_fx=False, pitch_safe=False)
                st = int(round(P(pre + "Oscillator_Pitch_Transpose"))) + 12 * int(round(P(pre + "Oscillator_Pitch_TransposeOctaves")))
                voices.append((f"engine {e}", st, P(pre + "Volume", 0.0), False))
        elif tag == "UltraAnalog":
            glob = 12 * int(round(P("Octave"))) + int(round(P("Transpose")))
            for i in (1, 2):
                pre = f"SignalChain{i}/"
                if P(pre + "OscillatorToggle", True) is True:
                    voices.append((f"osc{i}", 12 * int(round(P(pre + "OscillatorOct"))) + int(round(P(pre + "OscillatorSemi"))),
                                   db(P(pre + "OscillatorLevel", 1.0)), False))
        else:
            # Generic: a top-level Octave/Transpose (Tension, Collision, Electric, ...).
            for path, mult in (("Octave", 12), ("Transpose", 1), ("Global_Transpose", 1), ("Globals/Transpose", 1)):
                if dev.find(path) is not None and dev.find(path + "/Manual") is not None:
                    glob += mult * int(round(P(path)))
        off, vdesc = glob + sub, ""
        if voices:
            pick, kind, rule = pick_voice(voices)
            off = glob + pick
            vdesc = ", ".join(f"{n} {st:+d}" + ("" if g == -math.inf else f" ({g:+.1f} dB)") + (" sub" if s else "")
                              for n, st, g, s in voices)
            if kind:
                self.flag("layered", name, f"{kind} oscillators ({vdesc}); using {pick:+d} ({rule})")
        desc = f"{name}: transpose {glob:+d}" + (f"; voices {vdesc} -> {off:+d}" if voices else "") + extra
        if sweep is not None:
            self.sweeps[desc] = sweep
        return off, desc

    def _operator(self, P, name):
        """Operator's pitch envelope and sub-octave ratios. Returns (semitones added, seconds until
        the pitch envelope settles or None, text for the description).

        Pitch envelope: levels are semitones (-48..48) times the amount (-1..1), read as straight
        lines. An oscillator that the envelope moves and that sounds (within 18 dB of the loudest)
        makes the patch sweep: a note shorter than the time the pitch takes to come within half a
        semitone of where it stays never sounds at its written pitch.

        Ratios: the oscillators that sound (within 18 dB) and do not die away at once (sustain
        above -40 dB, or longer than 150 ms) form the body of the sound. Whether they are carriers
        or modulators, its fundamental is the greatest common divisor of their ratios (a 1:0.5
        pair sounds at 0.5). When that is an octave of the key (0.5, 2, ...) and an oscillator at
        that ratio holds within 6 dB of the loudest, the octave is applied; otherwise it is
        flagged only. Fine-tuned and fixed-frequency oscillators stop the rule."""
        ops, off = [], []
        for i, letter in enumerate("ABCD"):
            o = f"Operator.{i}/"
            if P(o + "IsOn", True) is not True:
                off.append(letter)
                continue
            fixed = P(o + "Tune/FixedFrequencyOn") is True
            c, fine = P(o + "Tune/Coarse", 1.0), P(o + "Tune/Fine")
            ratio = None if fixed or abs(fine) > 1e-6 else (0.5 if c == 0 else float(int(c)))
            att, dec = P(o + "Envelope/AttackTime"), P(o + "Envelope/DecayTime")
            short = P(o + "Envelope/SustainLevel", 1.0) < 0.01 and att + dec <= 150.0 and \
                int(P(o + "Envelope/LoopMode")) == 0
            ops.append((letter, ratio, db(P(o + "Volume", 1.0)), short, att + dec, P(o + "PitchEnvOn") is True))
        if not ops:
            return 0, None, ""
        loudest = max(o[2] for o in ops)
        loud = [o for o in ops if o[2] >= loudest - 18.0]
        sub, sweep, text = 0, None, ""

        # the body's fundamental
        lasting = [o for o in loud if not o[3]] or loud
        if lasting and all(o[1] is not None for o in lasting):
            g = 0
            for o in lasting:
                g = math.gcd(g, int(round(2 * o[1])))
            body = g / 2.0
            names = ", ".join(f"{o[0]} {o[1]:g}" for o in lasting) + (f"; {'/'.join(off)} off" if off else "")
            octave = math.log2(body) if body > 0 else 0.0
            held = [o for o in lasting if o[1] == body and o[2] >= loudest - 6.0]
            dies = [o for o in loud if o[3] and o[1] == 1.0]
            gone = (f"; the ratio-1 oscillator {', '.join(o[0] for o in dies)} dies within "
                    f"{max(o[4] for o in dies):.0f} ms" if dies and body < 1.0 else "")
            if body != 1.0 and octave == int(octave) and held:
                sub = int(12 * octave)
                text = f"; body at ratio {body:g} -> {sub:+d}"
                level = "the loudest" if held[0][2] >= loudest - 0.05 else f"{loudest - held[0][2]:.1f} dB below the loudest"
                self.flag("operator-ratio", name, f"the oscillators that hold ({names}) share a fundamental at ratio "
                          f"{body:g}, and {held[0][0]} at that ratio is {level}{gone}: the patch sounds {sub:+d} st from "
                          f"its transpose; applied (addTranspose {-sub:+d} undoes it)", listen=True)
            elif body != 1.0:
                st = int(round(12 * octave))
                self.flag("operator-ratio", name, f"the oscillators that hold ({names}) share a fundamental at ratio "
                          f"{body:g}{gone}: the patch may sound about {st:+d} st from its transpose (not applied; check "
                          "by ear)", listen=True)

        # pitch envelope
        pe = "PitchEnv/PitchEnv/"
        amt = P(pe + "EnvelopeAmount")
        moved = [o[0] for o in loud if o[5]]
        if P("PitchEnv/PitchEnvOn") is True and abs(amt) > 1e-6 and moved:
            o0, o1, o2 = (amt * P(pe + k) for k in ("AttackLevel", "DecayLevel", "SustainLevel"))
            t1, t2 = P(pe + "AttackTime"), P(pe + "DecayTime")
            if max(abs(o0), abs(o1), abs(o2)) >= 0.5:
                shape = f"{o0:+.1f} st at the onset"
                if abs(o1 - o0) >= 0.05:
                    shape += f", {o1:+.1f} st after {t1:.0f} ms"
                if abs(o2 - o1) >= 0.05:
                    shape += f", {o2:+.1f} st after {t1 + t2:.0f} ms"
                if int(P(pe + "LoopMode")) != 0:
                    sweep, why = math.inf, "it loops, so the pitch keeps moving: every note is unreliable"
                elif abs(o2) >= 0.5:
                    sweep, why = math.inf, f"it holds {o2:+.1f} st away from the key: every note is unreliable"
                else:
                    # the last time the pitch is half a semitone or more from where it stays
                    settle = 0.0
                    for ta, va, tb, vb in ((0.0, o0, t1, o1), (t1, o1, t1 + t2, o2)):
                        da, dbb = va - o2, vb - o2
                        if abs(dbb) >= 0.5:
                            settle = max(settle, tb)
                        elif abs(da) >= 0.5:
                            edge = math.copysign(0.5, da)
                            settle = max(settle, ta + (tb - ta) * (da - edge) / (da - dbb))
                    sweep = settle / 1000.0
                    why = f"notes shorter than {settle:.0f} ms never reach their pitch and are unreliable"
                text += f"; pitch envelope {shape}"
                self.flag("pitch-envelope", name, f"pitch envelope on oscillator {'/'.join(moved)} (amount "
                          f"{100 * amt:+.0f}%): {shape} (levels read as semitones on straight lines); {why} when this "
                          "instrument sets the note's pitch")
        return sub, sweep, text


# ---------------------------------------------------------------------------------------------
# Clips


class ClipNote:
    __slots__ = ("on", "off", "pitch", "vel", "prob", "veldev", "chased", "bend0", "bendmax", "local", "flags")

    def __init__(self, on, off, pitch, vel, prob, veldev, chased, bend0=0.0, bendmax=0.0, local=0.0):
        self.on, self.off, self.pitch, self.vel = on, off, pitch, vel
        self.prob, self.veldev, self.chased = prob, veldev, chased
        self.bend0, self.bendmax = bend0, bendmax
        self.local = local  # onset in clip time (beats), for clip envelopes
        self.flags = []  # per-note reasons the pitch is unreliable (clip envelopes)


# Per-note (MPE) pitch bend in clips: PerNoteEventList CC="-2"; 8192 = 48 semitones (Live's MPE range).
BEND_PER_SEMITONE = 8192.0 / 48.0


def note_bends(clip):
    """NoteId -> (bend at the note's start, largest bend), in semitones."""
    out = {}
    lists = clip.find("Notes/PerNoteEventStore/EventLists")
    if lists is None:
        return out
    for lst in lists:
        if lst.get("CC") != "-2":
            continue
        evs = [(fnum(e.get("TimeOffset")), fnum(e.get("Value")) / BEND_PER_SEMITONE) for e in lst.iter("PerNoteEvent")]
        if not evs:
            continue
        evs.sort()
        start = evs[0][1] if evs[0][0] <= 1e-6 else 0.0
        out[lst.get("NoteId")] = (start, max((v for _, v in evs), key=abs))
    return out


def clip_notes(clip):
    """Every note event in a clip: (time, duration, pitch, velocity, probability, velDeviation, enabled,
    start bend, largest bend)."""
    out = []
    bends = note_bends(clip)
    for kt in clip.findall("Notes/KeyTracks/KeyTrack"):
        key = int(fnum(attr(kt, "MidiKey")))
        for n in kt.findall("Notes/MidiNoteEvent"):
            b0, bmax = bends.get(n.get("NoteId"), (0.0, 0.0))
            out.append((fnum(n.get("Time")), fnum(n.get("Duration")), key, fnum(n.get("Velocity"), 100.0),
                        fnum(n.get("Probability"), 1.0), fnum(n.get("VelocityDeviation"), 0.0),
                        n.get("IsEnabled", "true") != "false", b0, bmax))
    return out


def clip_segments(clip):
    """[(local_from, local_to, arrangement_shift)]: which clip-local spans play, and where."""
    cs, ce = fnum(attr(clip, "CurrentStart", clip.get("Time"))), fnum(attr(clip, "CurrentEnd"))
    length = ce - cs
    loop_on = attr(clip, "Loop/LoopOn") == "true"
    ls, le = fnum(attr(clip, "Loop/LoopStart")), fnum(attr(clip, "Loop/LoopEnd"))
    start = ls + fnum(attr(clip, "Loop/StartRelative"))
    if length <= 0:
        return []
    if not loop_on or le - ls <= 1e-9:
        return [(start, start + length, cs - start)]
    loop_len = le - ls
    if start >= le - 1e-9:
        start = ls + ((start - ls) % loop_len)
    segs, pos, arr, remaining = [], start, cs, length
    while remaining > 1e-9:
        seg_end = min(le, pos + remaining)
        d = seg_end - pos
        if d <= 1e-12:
            break
        segs.append((pos, seg_end, arr - pos))
        remaining -= d
        arr += d
        pos = ls
    return segs


def expand_clip(clip, chase=True):
    """Clip notes placed on the arrangement (beats), with loops unrolled and notes cut at the loop
    end and the clip end. Returns (notes, stats)."""
    stats = collections.Counter()
    if attr(clip, "Disabled") == "true":
        stats["clipDisabled"] += 1
        return [], stats
    raw = clip_notes(clip)
    stats["clipEvents"] += len(raw)
    segs = clip_segments(clip)
    out = []
    for si, (a, b, shift) in enumerate(segs):
        for t, dur, key, vel, prob, vdev, enabled, b0, bmax in raw:
            dur = max(dur, 0.0)
            if a - ONSET_TOL <= t < b - ONSET_TOL:
                chased = False
                on = max(t, a)  # a note stored a hair before the boundary starts on it
            elif chase and si == 0 and t < a - ONSET_TOL and t + dur > a + ONSET_TOL:
                chased = True
                on = a
            else:
                continue
            if not enabled:
                stats["disabled"] += 1
                continue
            off = min(t + dur, b)
            out.append(ClipNote(on + shift, off + shift, key, vel, prob, vdev, chased, b0, bmax, local=on))
            stats["chased" if chased else "played"] += 1
    return out, stats


def parse_events(evs):
    """[(time, value, kind)] of an Events element (float, bool and enum events), sorted by time
    (ties keep file order: a jump), and whether any segment is curved."""
    events, curved = [], False
    for e in evs:
        kind = {"FloatEvent": "float", "BoolEvent": "bool", "EnumEvent": "enum"}.get(e.tag)
        if kind is None:
            continue
        if e.get("CurveControl1X") is not None or e.get("CurveControl1Y") is not None:
            curved = True
        events.append((fnum(e.get("Time")), parse_value(e.get("Value")), kind))
    events.sort(key=lambda x: x[0])
    return events, curved


def clip_envelopes(clip):
    """[(target id, (events, times))] of a clip's envelopes, in clip time (beats)."""
    out = []
    for env in clip.findall("Envelopes/Envelopes/ClipEnvelope"):
        pid = attr(env, "EnvelopeTarget/PointeeId")
        evs = env.find("Automation/Events")
        if pid is None or evs is None:
            continue
        events, _ = parse_events(evs)
        if events:
            out.append((pid, (events, [x[0] for x in events])))
    return out


def env_range(env, a, b):
    """(value at a, largest |value| over [a, b]) of a float envelope."""
    v0 = Automation.eval_events(env, a)
    vals = [v0, Automation.eval_events(env, b)] + [v for t, v, _ in env[0] if a <= t <= b]
    return float(v0), max(abs(float(v)) for v in vals)


def per_note_expression(clip):
    """The kinds of per-note (MPE) expression a clip carries: pressure, slide, pitchbend."""
    kinds = set()
    for lst in clip.findall("Notes/PerNoteEventStore/EventLists/*"):
        if lst.find(".//PerNoteEvent") is None:
            continue
        kinds.add({"-1": "pressure", "-2": "pitchbend", "74": "slide"}.get(lst.get("CC"), "cc" + str(lst.get("CC"))))
    return kinds


# A channel pitch bend (of +-8192) this large at a note's onset makes its pitch unreliable.
BEND_ENV_MIN = 64


def read_clip_envelopes(clip, notes, track, index, envs):
    """Reads a clip's envelopes against its expanded notes (clip time, so loops repeat them).
    A pitch-bend envelope away from 0 at a note's onset, or any envelope on a pitch parameter,
    adds a per-note flag (note.flags). Tallies go to envs[target]. Returns the kinds of expression
    the controller envelopes carry (for Expression Control sources)."""
    kinds = set()
    for pid, env in clip_envelopes(clip):
        values = [float(v) for _, v, _ in env[0]]
        moving = any(abs(v) > 1e-9 for v in values)
        if pid in track.controllers:
            n = track.controllers[pid]
            label = {0: "pitch bend", 1: "channel pressure"}.get(n, f"MIDI controller {n}")
            kind = "bend" if n == 0 else "controller"
            if moving:
                kinds |= {"pitchbend"} if n == 0 else ({"pressure"} if n == 1 else
                                                       {"modwheel", "expression", "sustain", "slide"})
        elif pid in index.by_target:
            _, dev, name = index.by_target[pid]
            label, kind = f"{device_label(dev)} {name}", ("pitch" if is_pitch_param(name) else "param")
        else:
            label, kind = f"target {pid}", "param"
        e = envs[label]
        e["kind"], e["clips"] = kind, e["clips"] + 1
        if values:
            e["lo"], e["hi"] = min(e["lo"], min(values)), max(e["hi"], max(values))
        for note in notes:
            a = note.local
            b = a + (note.off - note.on)
            if kind == "bend":
                v0, vmax = env_range(env, a, b)
                if abs(v0) >= BEND_ENV_MIN:
                    note.flags.append("clip pitch bend")
                    e["onset"] += 1
                elif vmax >= BEND_ENV_MIN:
                    e["during"] += 1
            elif kind == "pitch":
                note.flags.append("clip envelope on a pitch parameter")
                e["onset"] += 1
    return kinds


def clip_envelope_flags(res, track_name, envs):
    for label, e in envs.items():
        rng = f"values {e['lo']:g}..{e['hi']:g}" if e["lo"] <= e["hi"] else "no values"
        if e["kind"] == "bend":
            detail = f"pitch-bend clip envelope in {e['clips']} clip(s) ({rng}, of +-8192): " + (
                f"{e['onset']} notes start under a bend (unreliable; the instrument's bend range is not read)"
                if e["onset"] else "no note starts under a bend")
            if e["during"]:
                detail += f"; {e['during']} notes are bent while they sound (onset pitch kept)"
            res.flag("clip-envelope", track_name, detail, pitch_safe=not e["onset"], listen=bool(e["onset"] or e["during"]))
        elif e["kind"] == "pitch":
            res.flag("clip-envelope", track_name, f"clip envelope on {label}, a pitch parameter, in {e['clips']} clip(s) "
                     f"({rng}): clip modulation is not modelled, so the {e['onset']} notes of those clips are unreliable",
                     pitch_safe=False, listen=True)
        else:
            res.flag("clip-envelope", track_name, f"clip envelope on {label} in {e['clips']} clip(s) ({rng}): not read")


def decide_pitch_mappings(res, expression):
    """A Max mapping that reaches a pitch parameter makes the track's notes unreliable, unless it
    is an Expression Control slot whose source has no data in the clips (it then stays put)."""
    grouped = collections.OrderedDict()
    for label, what, source, text, kind in res.pitch_mappings:
        grouped.setdefault((label, what, source, kind), []).append(text)
    for (label, what, source, kind), texts in grouped.items():
        text = "; ".join(texts)
        src = (source or "").lower()
        if kind == "expression" and source and src not in ALWAYS_SOURCES and src not in expression:
            res.flag("max-mapping", label, f"{what} maps {text} ({'a pitch parameter' if len(texts) == 1 else 'pitch parameters'}), "
                     f"but the clips carry no {source} data, so it stays at its stored value (notes kept; check by ear)",
                     listen=True)
            continue
        why = {"audio": "follows the audio", "modulator": "moves on its own"}.get(kind) or (
            "its slot's source is not known" if not source else
            (f"{source} changes with every note" if src in ALWAYS_SOURCES else f"the clips carry {source} data"))
        res.flag("max-mapping", label, f"{what} maps {text} ({'a pitch parameter' if len(texts) == 1 else 'pitch parameters'}), "
                 f"and {why}: pitches may move (unreliable; check by ear, then set trust)", pitch_safe=False, unreliable=True)


# ---------------------------------------------------------------------------------------------
# Tracks


class Track:
    def __init__(self, el, index):
        self.el = el
        self.index = index
        self.id = el.get("Id")
        self.kind = {"MidiTrack": "midi", "AudioTrack": "audio", "GroupTrack": "group"}.get(el.tag, el.tag)
        self.name = attr(el, "Name/EffectiveName") or attr(el, "Name/UserName") or f"Track {index + 1}"
        self.group_id = attr(el, "TrackGroupId", "-1")
        mixer = el.find("DeviceChain/Mixer")
        self.speaker = mixer.find("Speaker") if mixer is not None else None
        self.solo = attr(mixer, "SoloSink") == "true" if mixer is not None else False
        self.freeze = attr(el, "Freeze") == "true"
        self.monitoring = attr(el, "DeviceChain/MonitoringEnum", "1")
        self.midi_in = attr(el, "DeviceChain/MidiInputRouting/Target", "")
        self.midi_out = attr(el, "DeviceChain/MidiOutputRouting/Target", "")
        devs = el.find("DeviceChain/DeviceChain/Devices")
        self.devices = list(devs) if devs is not None else []
        self.midi_clips = el.findall("DeviceChain/MainSequencer/ClipTimeable/ArrangerAutomation/Events/MidiClip")
        self.audio_clips = el.findall("DeviceChain/MainSequencer/Sample/ArrangerAutomation/Events/AudioClip")
        self.session_clips = len(el.findall("DeviceChain/MainSequencer/ClipSlotList/ClipSlot/ClipSlot/Value/*"))
        self.display = self.name
        # clip-envelope targets for MIDI controllers: ControllerTargets.0 is pitch bend,
        # ControllerTargets.1 channel pressure, the rest MIDI CCs
        self.controllers = {}
        mc = el.find("DeviceChain/MainSequencer/MidiControllers")
        for c in (mc if mc is not None else []):
            m = re.match(r"ControllerTargets\.(\d+)$", c.tag)
            if m and c.get("Id"):
                self.controllers[c.get("Id")] = int(m.group(1))

    def content_end(self):
        ends = [fnum(attr(c, "CurrentEnd")) for c in self.midi_clips + self.audio_clips if attr(c, "Disabled") != "true"]
        return max(ends) if ends else 0.0


def span_union(spans):
    spans = sorted(s for s in spans if s[1] > s[0])
    out = []
    for a, b in spans:
        if out and a <= out[-1][1] + 1e-9:
            out[-1] = (out[-1][0], max(out[-1][1], b))
        else:
            out.append((a, b))
    return out


def in_spans(spans, t):
    for a, b in spans:
        if a - 1e-9 <= t < b - 1e-9:
            return True
    return False


def next_span_start(spans, t):
    starts = [a for a, b in spans if a > t + 1e-9]
    return min(starts) if starts else math.inf


# ---------------------------------------------------------------------------------------------
# Roles

DRUM_WORDS = re.compile(r"drum|kick|snare|hi.?hat|\bhats?\b|\bhh\b|perc|clap|cymbal|\bride\b|crash|\btoms?\b|shaker|"
                        r"tambourine|conga|bongo|breakbeat|\bbreak\b|rimshot|808 ?kit|909|beatbox", re.I)
FX_WORDS = re.compile(r"\bfx\b|sfx|noise|riser|impact|rain|storm|atmo|ambien|texture|sweep|foley|vinyl|crackle|"
                      r"whoosh|glitch|uplift|downlift|transition|drone|field ?rec", re.I)
BASS_WORDS = re.compile(r"bass|\bsub\b|808|reese|low ?end", re.I)
CHORD_WORDS = re.compile(r"chord|\bpads?\b|keys|piano|organ|strum|stab|rhodes|wurli|e-?piano|\bcomp\b|choir|harmon", re.I)
MELODY_WORDS = re.compile(r"lead|melod|vocal|\bvox\b|hook|solo|topline|flute|whistle|\bsax|trumpet|violin|voice|sing", re.I)


def track_features(notes, song_beats, velocities=()):
    """Pitch range, polyphony and rhythm of a list of (on_beat, off_beat, pitch)."""
    if not notes:
        return {"notes": 0}
    pitches = [n[2] for n in notes]
    quiet = sum(1 for v in velocities if v <= 10)
    ons = sorted(n[0] for n in notes)
    # polyphony: notes sounding at each onset (including itself)
    by_on = sorted(notes)
    offs = sorted(n[1] for n in notes)
    poly = []
    for n in by_on:
        started = bisect.bisect_right(ons, n[0] + 1e-6)
        ended = bisect.bisect_right(offs, n[0] + 1e-6)
        poly.append(started - ended)
    groups = 0
    chordal = 0
    i = 0
    while i < len(ons):
        j = i
        # a quarter beat catches rolled (hand-strummed) chords as one onset
        while j + 1 < len(ons) and ons[j + 1] - ons[i] <= 0.25:
            j += 1
        groups += 1
        if j - i + 1 >= 3:
            chordal += 1
        i = j + 1
    active = set()
    for a, b, _ in notes:
        for k in range(int(math.floor(a)), int(math.ceil(max(b, a + 1e-6)))):
            active.add(k)
    durs = [max(0.0, b - a) for a, b, _ in notes]
    return {
        "notes": len(notes),
        "pitchMin": min(pitches), "pitchMax": max(pitches), "pitchMedian": statistics.median(pitches),
        "polyphony": round(statistics.mean(poly), 2), "maxPolyphony": max(poly),
        "chordalOnsetShare": round(chordal / groups, 3) if groups else 0.0,
        "notesPerActiveBeat": round(len(notes) / max(1, len(active)), 2),
        "activeBeats": len(active),
        "coverage": round(len(active) / max(1.0, song_beats), 3),
        "medianDurationBeats": round(statistics.median(durs), 3),
        "velocityAtMost10": quiet,
    }


def suggest_roles(tracks_info, vocal_audio):
    """tracks_info: list of dicts with name, feats, drums, slicing, muted. Returns {index: (role, why)}."""
    out, melodic = {}, []
    for i, t in enumerate(tracks_info):
        name, f = t["name"], t["feats"]
        if t["drums"]:
            out[i] = ("ignore", "drum instrument (drums are not in the key)")
        elif DRUM_WORDS.search(name):
            out[i] = ("ignore", "name says drums/percussion")
        elif t["slicing"]:
            out[i] = ("ignore", "Simpler slicing: notes pick slices, not pitches")
        elif FX_WORDS.search(name):
            out[i] = ("ignore", "name says FX/noise/texture")
        elif f.get("notes", 0) == 0:
            out[i] = ("ignore", "no audible notes (muted, empty or soloed out)")
        elif f["notesPerActiveBeat"] > 8:
            out[i] = ("ignore", f"{f['notesPerActiveBeat']} notes per active beat: a texture, not a line")
        elif f.get("shortShare", 0.0) >= 0.8:
            out[i] = ("ignore", f"{int(round(100 * f['shortShare']))}% of its notes are shorter than "
                      f"{int(1000 * SHORT_NOTE_S)} ms (median {1000 * f.get('medianSeconds', 0):.0f} ms): thumps or "
                      "blips, not a line, and too short to set a chord's bass; give it a role if it carries a part")
        elif BASS_WORDS.search(name) and f["pitchMedian"] < 64:
            out[i] = ("bass", f"name says bass; median pitch {f['pitchMedian']:g}")
        elif CHORD_WORDS.search(name) and f["polyphony"] >= 1.5:
            out[i] = ("chords", f"name says chords/keys/pad; polyphony {f['polyphony']}")
        elif f["pitchMedian"] <= 47 and f["polyphony"] < 1.6:
            out[i] = ("bass", f"low and monophonic (median {f['pitchMedian']:g}, polyphony {f['polyphony']})")
        elif f["polyphony"] >= 2.0 or f["chordalOnsetShare"] >= 0.4:
            out[i] = ("chords", f"polyphonic (polyphony {f['polyphony']}, {int(100 * f['chordalOnsetShare'])}% chordal onsets)")
        else:
            melodic.append(i)
    if melodic:
        def score(i):
            f = tracks_info[i]["feats"]
            named = 1.0 if MELODY_WORDS.search(tracks_info[i]["name"]) else 0.0
            return named + f["coverage"] + 0.5 * f["pitchMedian"] / 127.0
        ranked = sorted(melodic, key=score, reverse=True)
        for rank, i in enumerate(ranked):
            f = tracks_info[i]["feats"]
            base = f"melodic line (polyphony {f['polyphony']}, median {f['pitchMedian']:g}, covers {int(100 * f['coverage'])}% of the song)"
            if vocal_audio:
                out[i] = ("countermelody", base + f"; the melody is probably the audio track(s) {', '.join(vocal_audio)}")
            elif rank == 0:
                out[i] = ("melody", base + ("; the most prominent one" if len(ranked) > 1 else ""))
            else:
                out[i] = ("countermelody", base + f"; less prominent than {tracks_info[ranked[0]]['name']}")
    return out


# ---------------------------------------------------------------------------------------------
# Chords

NOTE_NAMES = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
SHARP_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
FLAT_NAMES = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
CHORD_TEMPLATES = [
    ("maj", (0, 4, 7)), ("min", (0, 3, 7)), ("dim", (0, 3, 6)), ("aug", (0, 4, 8)),
    ("sus4", (0, 5, 7)), ("sus2", (0, 2, 7)), ("7", (0, 4, 7, 10)), ("maj7", (0, 4, 7, 11)),
    ("min7", (0, 3, 7, 10)), ("hdim7", (0, 3, 6, 10)), ("dim7", (0, 3, 6, 9)), ("minmaj7", (0, 3, 7, 11)),
    ("maj6", (0, 4, 7, 9)), ("min6", (0, 3, 7, 9)), ("5", (0, 7)),
]
# Small preferences between chords that explain the notes equally well (e.g. F#:min7 over A:maj6
# for the same four notes when the bass does not decide).
QUALITY_PRIOR = {"maj": 0.0, "min": 0.0, "7": 0.0, "maj7": 0.0, "min7": 0.0, "5": -0.3, "sus4": -0.05,
                 "sus2": -0.1, "dim": -0.1, "aug": -0.15, "hdim7": -0.05, "dim7": -0.1, "maj6": -0.1,
                 "min6": -0.1, "minmaj7": -0.2}
DEGREES = {1: "b2", 2: "2", 3: "b3", 4: "3", 5: "4", 6: "b5", 7: "5", 8: "#5", 9: "6", 10: "b7", 11: "7"}
# Krumhansl-Kessler key profiles (major, minor), tonic first.
KK_MAJOR = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
KK_MINOR = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]


def estimate_key(weights):
    """(tonic pitch class, 'major'|'minor', root spelling) from pitch-class weights."""
    def corr(a, b):
        ma, mb = sum(a) / 12.0, sum(b) / 12.0
        num = sum((x - ma) * (y - mb) for x, y in zip(a, b))
        den = math.sqrt(sum((x - ma) ** 2 for x in a) * sum((y - mb) ** 2 for y in b))
        return num / den if den else 0.0
    best = None
    for t in range(12):
        for mode, prof in (("major", KK_MAJOR), ("minor", KK_MINOR)):
            rot = [prof[(pc - t) % 12] for pc in range(12)]
            c = corr(weights, rot)
            if best is None or c > best[0]:
                best = (c, t, mode)
    _, tonic, mode = best
    major = tonic if mode == "major" else (tonic + 3) % 12
    if major in (7, 2, 9, 4, 11, 6):  # G D A E B F#: sharp keys
        names = SHARP_NAMES
    elif major in (5, 10, 3, 8, 1):  # F Bb Eb Ab Db: flat keys
        names = FLAT_NAMES
    else:
        names = NOTE_NAMES
    return tonic, mode, names


def _present(weights, bass_pc):
    mx = max(weights)
    present = {pc: w / mx for pc, w in enumerate(weights) if mx > 0 and w / mx >= 0.2}
    if bass_pc is not None:
        present[bass_pc] = max(present.get(bass_pc, 0.0), 0.5)
    return present


def chord_score(present, bass_pc, root, ivs, q):
    """How well chord (root, intervals) explains the sounding pitch classes."""
    tones = {(root + i) % 12 for i in ivs}
    hit = sum(w for pc, w in present.items() if pc in tones)
    extra = sum(w for pc, w in present.items() if pc not in tones)
    miss = len(tones - set(present))
    s = hit - 1.0 * extra - 0.6 * miss - 0.15 * max(0, len(ivs) - 3) + QUALITY_PRIOR.get(q, 0.0)
    if root not in present:
        s -= 0.5
    if bass_pc is not None and root == bass_pc:
        s += 0.35
    return s + 0.05 * present.get(root, 0.0)


def harte(root, q, bass_pc, names=NOTE_NAMES):
    ivs = dict(CHORD_TEMPLATES)[q]
    label = f"{names[root]}:{q}"
    if bass_pc is not None and bass_pc != root and (bass_pc - root) % 12 in ivs:
        label += "/" + DEGREES[(bass_pc - root) % 12]
    return label


def label_chord(weights, bass_pc, names=NOTE_NAMES):
    """Harte label for one span's pitch-class weights (and its lowest bass pitch class, if any)."""
    present = _present(weights, bass_pc)
    if len(present) < 2:
        return "N"
    best = None
    for root in range(12):
        for q, ivs in CHORD_TEMPLATES:
            tones = {(root + i) % 12 for i in ivs}
            if len(tones & set(present)) < 2 or root not in present:
                continue
            s = chord_score(present, bass_pc, root, ivs, q)
            if best is None or s > best[0] + 1e-9:
                best = (s, root, q)
    return "N" if best is None else harte(best[1], best[2], bass_pc, names)


def derive_chords(chord_notes, bass_notes, grid_beats, change_cost=0.4, names=NOTE_NAMES):
    """Chord labels per beat. Chord-role notes count by how long they sound in the beat; the lowest
    bass-role note sounding through a quarter of the beat names the inversion and helps pick the
    root. A Viterbi pass charges change_cost per chord change, so a rolled chord or a one-beat gap
    does not flip the label; silence longer than about a beat becomes N."""
    beats = []
    for k in range(len(grid_beats) - 1):
        a, b = grid_beats[k], grid_beats[k + 1]
        if b <= a + 1e-9:
            continue
        w = [0.0] * 12
        for on, off, p in chord_notes:
            o = min(off, b) - max(on, a)
            if o > 1e-6:
                w[p % 12] += o
        low = None
        for on, off, p in bass_notes:
            o = min(off, b) - max(on, a)
            if o > 0.25 * (b - a) and (low is None or p < low):
                low = p
        bass_pc = None if low is None else low % 12
        beats.append((a, b, w, bass_pc))
    if not beats:
        return []
    # Candidate chords: the best few of every beat. Viterbi states are tone sets, so chords that
    # share their notes (C:maj6 and A:min7, the sus2/sus4 pair, dim7 and aug rotations) are one
    # state, named per beat by the bass.
    templates = dict(CHORD_TEMPLATES)
    names_of = collections.defaultdict(list)
    for root in range(12):
        for q, ivs in CHORD_TEMPLATES:
            names_of[frozenset((root + i) % 12 for i in ivs)].append((root, q))
    cands = set()
    for _, _, w, bpc in beats:
        present = _present(w, bpc)
        if len(present) < 2:
            continue
        scored = sorted(((chord_score(present, bpc, r, ivs, q), r, q) for r in range(12) for q, ivs in CHORD_TEMPLATES),
                        reverse=True)
        cands.update(frozenset((r + i) % 12 for i in templates[q]) for _, r, q in scored[:4])
    states = [None] + sorted(cands, key=lambda x: sorted(x))

    def best_name(k, st):
        _, _, w, bpc = beats[k]
        present = _present(w, bpc) if max(w) > 0 else ({} if bpc is None else {bpc: 0.5})
        if st is None:
            return (0.5 if not present else (0.0 if len(present) < 2 else -1.0)), None
        if not present:
            r, q = names_of[st][0]
            return -0.2, (r, q)
        return max((chord_score(present, bpc, r, templates[q], q), (r, q)) for r, q in names_of[st])

    table = [[best_name(k, st) for st in states] for k in range(len(beats))]
    dp = [table[0][i][0] for i in range(len(states))]
    back = []
    for k in range(1, len(beats)):
        best_i = max(range(len(states)), key=lambda i: dp[i])
        ptr, nxt = [], []
        for i in range(len(states)):
            stay, switch = dp[i], dp[best_i] - change_cost
            ptr.append(i if stay >= switch else best_i)
            nxt.append(max(stay, switch) + table[k][i][0])
        back.append(ptr)
        dp = nxt
    i = max(range(len(states)), key=lambda j: dp[j])
    path = [i]
    for ptr in reversed(back):
        i = ptr[i]
        path.append(i)
    path.reverse()
    merged = []
    for k, ((a, b, _, bpc), si) in enumerate(zip(beats, path)):
        name = table[k][si][1]
        text = "N" if name is None else harte(name[0], name[1], bpc, names)
        if merged and merged[-1][2] == text and abs(merged[-1][1] - a) < 1e-9:
            merged[-1] = (merged[-1][0], b, text)
        else:
            merged.append((a, b, text))
    return merged


# ---------------------------------------------------------------------------------------------
# MIDI files


def vlq(n):
    out = [n & 0x7F]
    n >>= 7
    while n:
        out.append(0x80 | (n & 0x7F))
        n >>= 7
    return bytes(reversed(out))


def midi_track(events):
    """events: [(tick, order, bytes)] -> MTrk chunk."""
    events.sort(key=lambda e: (e[0], e[1]))
    data, last = bytearray(), 0
    for tick, _, msg in events:
        data += vlq(max(0, tick - last)) + msg
        last = max(last, tick)
    data += vlq(0) + b"\xff\x2f\x00"
    return b"MTrk" + struct.pack(">I", len(data)) + bytes(data)


def write_midi(path, tracks, tempo, signatures, origin, end_beat, ppq=480):
    """tracks: [(name, program, [(on_beat, off_beat, pitch, velocity)])]; beats are arrangement beats,
    written relative to `origin` (the export start)."""
    tick = lambda b: int(round((b - origin) * ppq))
    meta = [(0, 0, b"\xff\x03" + vlq(len(b"tempo")) + b"tempo")]
    # tempo: breakpoints, ramps sampled every 1/8 beat
    b, step = origin, 0.125
    last = None
    while b <= end_beat + 1e-9:
        nxt = b + step
        sec = tempo.seconds(nxt) - tempo.seconds(b)
        bpm = 60.0 * step / sec if sec > 0 else tempo.bpm_at(b)
        us = int(round(60000000.0 / bpm))
        if us != last:
            meta.append((tick(b), 1, b"\xff\x51\x03" + us.to_bytes(3, "big")))
            last = us
        b = nxt
    for sb, num, den in signatures:
        if sb >= origin - 1e-9:
            meta.append((tick(sb), 2, b"\xff\x58\x04" + bytes([num, int(math.log2(den)), 24, 8])))
    chunks = [midi_track(meta)]
    for ti, (name, program, notes) in enumerate(tracks):
        ch = ti % 16
        if ch == 9:
            ch = (ch + 1) % 16
        nm = name.encode("utf-8")[:120]
        ev = [(0, 0, b"\xff\x03" + vlq(len(nm)) + nm), (0, 1, bytes([0xC0 | ch, program & 0x7F]))]
        for on, off, p, v in notes:
            if on < origin - 1e-9 or not (0 <= p <= 127):
                continue
            t0, t1 = tick(on), max(tick(off), tick(on) + 1)
            ev.append((t0, 3, bytes([0x90 | ch, p, max(1, min(127, int(round(v))))])))
            ev.append((t1, 2, bytes([0x80 | ch, p, 64])))
        chunks.append(midi_track(ev))
    with open(path, "wb") as f:
        f.write(b"MThd" + struct.pack(">IHHH", 6, 1, len(chunks), ppq) + b"".join(chunks))


# ---------------------------------------------------------------------------------------------
# Conversion

PROGRAMS = {"melody": 81, "countermelody": 71, "chords": 0, "bass": 33, "ignore": 0, "unreliable": 4}


def roles_template(set_path):
    return {
        "format": "als2truth-roles-1",
        "set": os.path.basename(set_path),
        "help": ("role: melody | countermelody | chords | bass | ignore. transpose: 'auto' (instrument and "
                 "MIDI-effect transposes) or a whole number of semitones that replaces them. addTranspose: "
                 "semitones added on top (octave fixes). trust: true puts a flagged track's notes in the key "
                 "(post-FX and check-by-ear flags; chance is --probability). soundsLike: name of another track whose instrument chain plays these notes "
                 "(e.g. a track holding recorded post-FX MIDI); skipMidiEffects: true when the notes are "
                 "already post-FX. Re-run als2truth to apply."),
        "tracks": [],
    }


def convert(args):
    root = load_set(args.set)
    ls = root.find("LiveSet")
    creator = root.get("Creator", "")
    auto = Automation(ls)
    master = ls.find("MasterTrack")
    if master is None:
        master = ls.find("MainTrack")
    mixer = master.find("DeviceChain/Mixer")
    tempo_el, sig_el = mixer.find("Tempo"), mixer.find("TimeSignature")
    bpm0 = fnum(attr(tempo_el, "Manual"), 120.0)
    tempo_events = auto.events(tempo_el)
    real_tempo_events = [e for e in (tempo_events or []) if e[0] > FAR_PAST / 2]
    tempo = TempoMap(bpm0, tempo_events if len({round(e[1], 6) for e in (tempo_events or [])}) > 1 else None)
    notes_log = []
    if tempo_events and len({round(e[1], 6) for e in tempo_events}) > 1:
        notes_log.append(f"tempo automation: {len(real_tempo_events)} breakpoints")
        if auto.target_id(tempo_el) in auto.curved:
            notes_log.append("tempo automation has curved segments: read as straight ramps")
    sig_events = auto.events(sig_el)
    if sig_events:
        signatures = [(max(0.0, t), *decode_signature(v)) for t, v, _ in sig_events]
        # keep the last signature at each beat
        dedup = collections.OrderedDict()
        for b, n, d in signatures:
            dedup[round(b, 6)] = (b, n, d)
        signatures = list(dedup.values())
    else:
        signatures = [(0.0, *decode_signature(fnum(attr(sig_el, "Manual"), 201)))]
    tuning = ls.find("TuningSystems")
    if tuning is not None and len(tuning):
        notes_log.append("the Set uses a tuning system: pitches are 12-TET MIDI numbers, not retuned")

    tracks = [Track(el, i) for i, el in enumerate(ls.find("Tracks")) if el.tag in ("MidiTrack", "AudioTrack", "GroupTrack")]
    by_id = {t.id: t for t in tracks}
    names = collections.Counter(t.name for t in tracks if t.kind == "midi")
    seen = collections.Counter()
    for t in tracks:
        if t.kind == "midi" and names[t.name] > 1:
            seen[t.name] += 1
            t.display = f"{t.name} ({seen[t.name]})"

    def ancestors(t):
        out, g = [], t.group_id
        while g and g != "-1" and g in by_id:
            out.append(by_id[g])
            g = by_id[g].group_id
        return out

    any_solo = any(t.solo for t in tracks)

    def solo_ok(t):
        if not any_solo or args.ignore_solo:
            return True
        chain = [t] + ancestors(t)
        if any(x.solo for x in chain):
            return True
        # a soloed child keeps its group audible (but not the group's other children)
        return False

    def muted_spans(t):
        spans = []
        for x in [t] + ancestors(t):
            spans += auto.false_spans(x.speaker)
        return span_union(spans)

    if not any(attr(c, "Disabled") != "true" for t in tracks if t.kind == "midi" for c in t.midi_clips):
        sess = sum(t.session_clips for t in tracks)
        raise SystemExit(f"{args.set}: no arrangement MIDI clips" +
                         (f"; the set keeps its music in {sess} Session View clips. Record them into the "
                          "Arrangement, save, and run again" if sess else "") + ". Nothing written.")

    origin = args.export_start
    origin_sec = tempo.seconds(origin)
    to_sec = lambda b: round(tempo.seconds(b) - origin_sec + args.offset, 5)
    beat_after = tempo.beat_after

    # roles file
    out_dir = args.out
    os.makedirs(out_dir, exist_ok=True)
    roles_path = args.roles or os.path.join(out_dir, "roles.json")
    roles_doc = None
    if os.path.exists(roles_path) and not args.fresh_roles:
        with open(roles_path) as f:
            roles_doc = json.load(f)
        print(f"honouring roles from {roles_path}")

    def role_entry(t):
        if roles_doc is None:
            return None
        entries = roles_doc.get("tracks", [])
        for e in entries:
            if str(e.get("id")) == t.id and e.get("track") == t.name:
                return e
        for e in entries:
            if str(e.get("id")) == t.id:
                return e
        same = [e for e in entries if e.get("track") in (t.name, t.display)]
        return same[0] if len(same) == 1 else None

    midi_tracks = [t for t in tracks if t.kind == "midi"]
    resolvers = {}
    per_track = {}
    song_end = max([t.content_end() for t in tracks] + [0.0])
    index = LomIndex(ls)

    # pass 1: expand clips, resolve pitches
    for t in midi_tracks:
        entry = role_entry(t) or {}
        res = Resolver(auto, t.display, index)
        res.scan(t.devices)
        # Notes that sound through another track's instrument: a roles-file "soundsLike", or a
        # MIDI track without an instrument whose MIDI goes to (or was recorded from) another track.
        target, skip_fx, why = None, bool(entry.get("skipMidiEffects", False)), "soundsLike"
        sounds_like = entry.get("soundsLike")
        if sounds_like:
            cands = [x for x in midi_tracks if x.name == sounds_like or x.display == sounds_like]
            if cands:
                target = cands[0]
            else:
                print(f"warning: {t.display}: soundsLike '{sounds_like}' is not a MIDI track in the set")
        elif not res.has_instrument and not res.drums:
            m_out = re.search(r"Track\.(\d+)", t.midi_out or "")
            m_in = re.search(r"Track\.(\d+)", t.midi_in or "")
            if m_out and m_out.group(1) in by_id:
                target, skip_fx, why = by_id[m_out.group(1)], False, "MIDI output goes to"
            elif m_in and m_in.group(1) in by_id:
                # recorded from another track: post-FX unless the routing says pre-FX
                target, skip_fx, why = by_id[m_in.group(1)], "pre" not in (t.midi_in or "").lower(), "MIDI input is"
        devices = list(t.devices)
        if target is not None:
            tdev = list(target.devices)
            if skip_fx:
                tdev = [d for d in tdev if not (d.tag.startswith("Midi") or (d.tag.startswith("Mx") and "Midi" in d.tag))]
            res.devices.append(f"(sounds through '{target.display}'" + (", its MIDI effects skipped)" if skip_fx else ")"))
            res.scan(tdev, depth=1)
            devices += tdev
            if why != "soundsLike":
                res.flag("routing", t.display, f"{why} '{target.display}': that track's instrument is used")
        if not res.has_instrument and not res.drums:
            res.flag("instrument", t.display, "no known instrument on the track: MIDI pitches used as is")

        stats = collections.Counter()
        notes = []
        expression = set()  # expression data the clips carry (per-note MPE, controller envelopes)
        envs = collections.defaultdict(lambda: {"clips": 0, "lo": math.inf, "hi": -math.inf, "onset": 0, "during": 0})
        for clip in t.midi_clips:
            got, st = expand_clip(clip, chase=not args.no_chase)
            stats.update(st)
            notes += got
            if attr(clip, "Disabled") != "true":
                expression |= per_note_expression(clip)
                expression |= read_clip_envelopes(clip, got, t, index, envs)
            if clip.find("Notes/NoteProbabilityGroups") is not None and len(clip.find("Notes/NoteProbabilityGroups")):
                res.flag("probability", t.display, "clip uses note probability groups", post_fx=True)
            if attr(clip, "Loop/LoopOn") != "true" and abs(fnum(attr(clip, "Loop/StartRelative"))) > 1e-9:
                res.flag("clip", t.display, "unlooped clip with a start offset (assumed start = LoopStart + StartRelative)")
            if attr(clip, "GrooveSettings/GrooveId", "-1") not in ("-1", None):
                res.flag("groove", t.display, "a groove is applied: timing approximate", post_fx=True)
        stats["clips"] = len(t.midi_clips)

        clip_envelope_flags(res, t.display, envs)
        decide_pitch_mappings(res, expression)

        mspans = [] if args.include_muted else muted_spans(t)
        audible = solo_ok(t) or args.include_muted
        static = None
        resolved = []
        glide_max = 0.0
        for n in notes:
            if not audible:
                stats["soloedOut"] += 1
                continue
            if in_spans(mspans, n.on):
                stats["muted"] += 1
                continue
            mute_cut = next_span_start(mspans, n.on)
            off = min(n.off, mute_cut)
            if t.monitoring == "0":
                stats["monitorIn"] += 1
                continue
            res.dynamic = False
            vel = int(round(n.vel))
            hit = static.get((n.pitch, vel)) if static is not None else None
            if hit is None:
                outs = res.resolve(devices, n.pitch, vel, n.on)
                note_len = res.note_len
                if not res.dynamic:
                    static = static or {}
                    static[(n.pitch, vel)] = (outs, note_len)
            else:
                outs, note_len = hit
            if not outs:
                stats["silent"] += 1
                continue
            pitches = sorted({q for q, _ in outs})
            primary = pitches[0]
            desc = next(d for q, d in outs if q == primary)
            if desc:
                res.descs[desc] += 1
            if len(pitches) > 1:
                res.layers[" / ".join(f"{q - n.pitch:+d}" for q in pitches)] += 1
            nflags = list(n.flags)  # per-note reasons the pitch is unreliable
            if abs(n.bend0) >= 0.5:  # per-note pitch bend already away from 0 at the onset
                primary += int(round(n.bend0))
                stats["bentAtOnset"] += 1
            if abs(n.bend0 - round(n.bend0)) > BEND_OFF_PITCH:
                nflags.append("bend between semitones")
                stats["bentOffPitch"] += 1
            elif res.mpe_bend_shaper and abs(n.bend0) >= 0.5:
                nflags.append("bend reshaped by MPE Control")
                stats["bendReshaped"] += 1
            if abs(n.bendmax) >= 1.0:
                stats["glides"] += 1
                glide_max = max(glide_max, abs(n.bendmax))
            if note_len is not None:  # Note Length: off = onset + fixed time
                off = min(beat_after(n.on, note_len), mute_cut)
                stats["noteLength"] += 1
            settle = res.sweeps.get(desc)
            if settle is not None and tempo.seconds(off) - tempo.seconds(n.on) < settle:
                nflags.append("pitch envelope")
                stats["pitchEnvelope"] += 1
            stats["clipEnvelopeNotes"] += bool(n.flags)
            resolved.append((n, primary, off, nflags))
        if stats["bentAtOnset"]:
            res.flag("expression", t.display, f"{stats['bentAtOnset']} notes start with a per-note pitch bend "
                     "(applied to the onset pitch, rounded to a semitone)")
        if stats["bentOffPitch"]:
            res.flag("expression", t.display, f"{stats['bentOffPitch']} notes start with a per-note pitch bend more than "
                     f"{BEND_OFF_PITCH} st from a semitone (unreliable: they sound between keys)", pitch_safe=False,
                     listen=True)
        if stats["bendReshaped"]:
            res.flag("expression", t.display, f"{stats['bendReshaped']} notes start with a per-note pitch bend that "
                     f"{res.mpe_bend_shaper} reshapes (unreliable)", pitch_safe=False, listen=True)
        if stats["pitchEnvelope"]:
            res.flag("pitch-envelope", t.display, f"{stats['pitchEnvelope']} notes end before the pitch envelope settles "
                     "(unreliable; set trust if they sound at their written pitch)", pitch_safe=False, listen=True)
        if stats["glides"]:
            res.flag("expression", t.display, f"{stats['glides']} notes glide up to {glide_max:.1f} semitones "
                     "with per-note pitch bend (onset pitch kept)")
        if t.monitoring == "0":
            res.flag("monitoring", t.display, "track monitors 'In': its arrangement clips do not play")
        per_track[t.id] = {"track": t, "res": res, "stats": stats, "resolved": resolved, "entry": entry,
                           "devices": devices}
        resolvers[t.id] = res

    # audio tracks that probably carry pitched content
    vocal_audio, pitched_audio = [], []
    for t in tracks:
        if t.kind != "audio" or not t.audio_clips:
            continue
        if not solo_ok(t) or auto.false_spans(t.speaker) == [(-math.inf, math.inf)]:
            continue
        if any(auto.false_spans(g.speaker) == [(-math.inf, math.inf)] for g in ancestors(t)):
            continue
        path = "/".join([g.name for g in reversed(ancestors(t))] + [t.name])
        if DRUM_WORDS.search(path) or FX_WORDS.search(t.name) or re.search(r"impact|loop|granular", t.name, re.I):
            continue
        pitched_audio.append(t.name)
        if re.search(r"vocal|\bvox\b|lead|voice|sing", path, re.I) and not re.search(r"hum|adlib|harmony|delay", t.name, re.I):
            vocal_audio.append(t.name)

    # pass 2: features, roles
    song_beats = max(1.0, song_end - origin)
    infos = []
    for t in midi_tracks:
        d = per_track[t.id]
        feats = track_features([(n.on, off, p) for n, p, off, _ in d["resolved"]], song_beats,
                               [n.vel for n, _, _, _ in d["resolved"]])
        secs = [tempo.seconds(off) - tempo.seconds(n.on) for n, _, off, _ in d["resolved"]]
        if secs:
            feats["medianSeconds"] = round(statistics.median(secs), 3)
            feats["shortShare"] = round(sum(x < SHORT_NOTE_S for x in secs) / len(secs), 3)
        d["feats"] = feats
        infos.append({"name": t.display, "feats": feats, "drums": d["res"].drums, "slicing": d["res"].slicing})
    suggested = suggest_roles(infos, vocal_audio)

    new_roles = roles_template(args.set) if roles_doc is None else roles_doc
    added = 0
    for i, t in enumerate(midi_tracks):
        d = per_track[t.id]
        s_role, s_why = suggested[i]
        entry = d["entry"]
        if not entry:
            entry = {"track": t.name, "id": int(t.id) if t.id and t.id.isdigit() else t.id, "role": s_role,
                     "suggested": s_role, "why": s_why, "transpose": "auto", "addTranspose": 0,
                     "trust": False, "soundsLike": None, "skipMidiEffects": False}
            new_roles.setdefault("tracks", []).append(entry)
            added += 1
        else:
            entry["suggested"], entry["why"] = s_role, s_why
        role = entry.get("role", s_role)
        if role not in ROLES:
            print(f"warning: {t.display}: unknown role '{role}', using ignore")
            role = "ignore"
        d["role"] = role
        d["suggested"] = (s_role, s_why)
    if roles_doc is None or added or args.fresh_roles:
        with open(roles_path, "w") as f:
            json.dump(new_roles, f, indent=1)
        print(f"wrote {roles_path} ({len(midi_tracks)} MIDI tracks; edit roles and run again)")
    else:
        # keep the user's file, but refresh suggestions in memory only
        pass

    # pass 3: notes
    truth_notes, unreliable, role_midi, unrel_midi = [], [], collections.defaultdict(list), []
    chord_src, bass_src = [], []
    post_fx_tracks, check_tracks = [], []
    any_offset_flag = False
    for t in midi_tracks:
        d = per_track[t.id]
        res, entry, role = d["res"], d["entry"], d["role"]
        flags = list(res.flags.values())
        post = [f for f in flags if f.post_fx]
        # track flags that make every note unreliable (post-FX MIDI, or a check by ear)
        unrel_kinds = list(collections.OrderedDict.fromkeys(f.kind for f in flags if f.post_fx or f.unreliable))
        pitch_safe = all(f.pitch_safe for f in flags if f.post_fx or f.unreliable)
        trusted = bool(entry.get("trust", False)) or args.trust_flagged
        tr = entry.get("transpose", "auto")
        if tr not in ("auto", None, ""):
            try:
                tr = int(tr)
            except (TypeError, ValueError):
                print(f"warning: {t.display}: transpose '{tr}' is not a whole number; using auto")
                tr = "auto"
        try:
            add = int(entry.get("addTranspose", 0) or 0)
        except (TypeError, ValueError):
            print(f"warning: {t.display}: addTranspose '{entry.get('addTranspose')}' is not a whole number; using 0")
            add = 0
        applied = collections.Counter()
        track_notes = []
        prob_notes = 0
        for n, p, off, pflags in d["resolved"]:
            pitch = (n.pitch + int(tr) if tr not in ("auto", None, "") else p) + add
            applied[pitch - n.pitch] += 1
            if not 0 <= pitch <= 127:
                d["stats"]["outOfRange"] += 1
                continue
            rec = {"on": to_sec(n.on), "off": to_sec(max(off, n.on)), "pitch": pitch,
                   "velocity": max(1, min(127, int(round(n.vel)))), "part": role, "instrument": t.display}
            nflags = []
            if n.prob < 1.0 - 1e-9:
                nflags.append(f"chance {n.prob:.2f}")
                prob_notes += 1
            if not trusted:  # trust (after listening) keeps flagged notes; chance is decided by --probability
                nflags += unrel_kinds + [x for x in pflags if x not in unrel_kinds]
            if n.on < origin - 1e-9:
                d["stats"]["beforeExport"] += 1
                continue
            track_notes.append((rec, n, off, nflags, pflags))
        d["applied"] = applied
        d["probNotes"] = prob_notes
        if prob_notes:
            res.flag("probability", t.display, f"{prob_notes} notes have a chance below 100%", post_fx=True)
        # only tracks whose notes would be in the key need recording
        if role != "ignore" and track_notes and (post or prob_notes) and not (trusted and not prob_notes):
            post_fx_tracks.append(t.display)
        if role != "ignore" and track_notes and any(f.listen for f in res.flags.values()):
            check_tracks.append(t.display)
        final, unrel = 0, 0
        for rec, n, off, nflags, pflags in track_notes:
            beat_note = (n.on, off, rec["pitch"], rec["velocity"])
            if role == "ignore":
                continue
            chance = any(x.startswith("chance") for x in nflags)
            fx = any(not x.startswith("chance") for x in nflags)  # only present when not trusted
            if fx or (chance and args.probability != "keep"):
                u = dict(rec)
                u["flags"] = nflags
                unreliable.append(u)
                unrel_midi.append((t.display, role, beat_note))
                unrel += 1
                # arpeggiated/strummed chord parts still name the harmony (their pitches are right)
                if role == "chords" and pitch_safe and not chance and not pflags:
                    chord_src.append((n.on, off, rec["pitch"]))
                continue
            truth_notes.append(rec)
            role_midi[role].append((t.display, beat_note))
            final += 1
            if role == "chords":
                chord_src.append((n.on, off, rec["pitch"]))
            if role == "bass":
                bass_src.append((n.on, off, rec["pitch"]))
        if final and any("not modelled; offsets" in f.detail for f in flags):
            any_offset_flag = True
        if trusted and final and any(not f.timing_safe for f in flags):
            any_offset_flag = True
        d["final"], d["unreliable"] = final, unrel

    truth_notes.sort(key=lambda r: (r["on"], r["pitch"]))
    unreliable.sort(key=lambda r: (r["on"], r["pitch"]))

    # grid and chords
    end_beat = max(song_end, max([off for t in midi_tracks for _, _, off, _ in per_track[t.id]["resolved"]] + [0.0]))
    grid, bpb = beat_grid(signatures, end_beat)
    grid = [(b, db_) for b, db_ in grid if b >= origin - 1e-9]
    beats = [to_sec(b) for b, _ in grid]
    downbeats = [to_sec(b) for b, d_ in grid if d_]
    chords = []
    pcw = [0.0] * 12
    for n in truth_notes + unreliable:
        pcw[n["pitch"] % 12] += max(0.0, n["off"] - n["on"])
    key_tonic, key_mode, spelling = estimate_key(pcw) if any(pcw) else (0, "major", NOTE_NAMES)
    if chord_src:
        gb = [b for b, _ in grid] + [end_beat]
        for a, b, lab in derive_chords(chord_src, bass_src, gb, names=spelling):
            chords.append({"start": to_sec(a), "end": to_sec(b), "label": lab})

    name = args.name or os.path.splitext(os.path.basename(args.set))[0]
    tempo_desc = f"{bpm0:g} BPM" if tempo.constant else f"tempo automation {min(tempo.bpms):g}-{max(tempo.bpms):g} BPM"
    sig_desc = ", ".join(f"{n}/{d}" + (f"@{b:g}" if b > 0 else "") for b, n, d in signatures)
    notes_complete = not pitched_audio
    if args.notes_complete is not None:
        notes_complete = args.notes_complete == "true"
    unisons = 0
    if not args.keep_unisons:
        truth_notes, k1 = merge_unisons(truth_notes)
        unreliable, k2 = merge_unisons(unreliable)
        unisons = k1 + k2
    truth = collections.OrderedDict()
    truth["format"] = "realbench-truth-1"
    truth["name"] = name
    truth["source"] = (f"Ableton Live set {os.path.basename(args.set)} ({creator}), {tempo_desc}, {sig_desc}; "
                       f"als2truth v{TOOL_VERSION}: arrangement MIDI clips with loops unrolled, instrument/MIDI-effect "
                       f"transposes applied, drums omitted" +
                       (f"; {unisons} unison doublings merged" if unisons else "") +
                       (f"; time 0 = beat {origin:g}" if origin else "") +
                       (f"; offset {args.offset:+g} s" if args.offset else ""))
    truth["notesComplete"] = notes_complete
    truth["offsetsReliable"] = not any_offset_flag
    truth["notes"] = truth_notes
    truth["beats"] = beats
    truth["downbeats"] = downbeats
    truth["beatsPerBar"] = bpb
    if chords:
        truth["chords"] = chords
    truth["comment"] = ("roles: " + ", ".join(f"{per_track[t.id]['role']}={t.display}" for t in midi_tracks
                                              if per_track[t.id]["role"] != "ignore") +
                        (f". Not in the key (audio tracks): {', '.join(pitched_audio)}" if pitched_audio else "") +
                        (f". Post-FX MIDI needed for: {', '.join(post_fx_tracks)}" if post_fx_tracks else "") +
                        (f". Check by ear: {', '.join(check_tracks)}" if check_tracks else ""))
    truth["unreliableNotes"] = unreliable
    truth["als2truth"] = {
        "version": TOOL_VERSION, "set": os.path.abspath(args.set), "creator": creator,
        "tempo": bpm0, "tempoConstant": tempo.constant, "signatures": [[b, n, d] for b, n, d in signatures],
        "exportStartBeat": origin, "offsetSeconds": args.offset, "songEndBeat": end_beat, "unisonsMerged": unisons,
        "postFxMidiNeeded": post_fx_tracks, "checkByEar": check_tracks, "audioTracksNotInKey": pitched_audio,
        "estimatedKey": f"{spelling[key_tonic]} {key_mode}",
        "roles": {t.display: per_track[t.id]["role"] for t in midi_tracks},
    }
    with open(os.path.join(out_dir, "truth.json"), "w") as f:
        json.dump(truth, f, indent=1)

    # MIDI per role
    midi_dir = os.path.join(out_dir, "midi")
    os.makedirs(midi_dir, exist_ok=True)
    written = []
    for role in ("melody", "countermelody", "chords", "bass"):
        items = role_midi.get(role, [])
        path = os.path.join(midi_dir, f"{role}.mid")
        if not items:
            if os.path.exists(path):
                os.remove(path)
            continue
        groups = collections.OrderedDict()
        for tn, note in items:
            groups.setdefault(tn, []).append(note)
        write_midi(path, [(tn, PROGRAMS[role], ns) for tn, ns in groups.items()], tempo, signatures, origin, end_beat)
        written.append(path)
    upath = os.path.join(midi_dir, "unreliable.mid")
    if unrel_midi:
        groups = collections.OrderedDict()
        for tn, role, note in unrel_midi:
            groups.setdefault(f"{tn} ({role}, unreliable)", []).append(note)
        write_midi(upath, [(tn, PROGRAMS["unreliable"], ns) for tn, ns in groups.items()], tempo, signatures, origin, end_beat)
        written.append(upath)
    elif os.path.exists(upath):
        os.remove(upath)

    # report
    report = collections.OrderedDict()
    report["set"] = os.path.abspath(args.set)
    report["creator"] = creator
    report["tempo"] = {"bpm": bpm0, "constant": tempo.constant, "breakpoints": [[b, v] for b, v in zip(tempo.beats, tempo.bpms)]}
    report["timeSignatures"] = [[b, n, d] for b, n, d in signatures]
    report["songEndBeat"] = end_beat
    report["songEndSeconds"] = round(tempo.seconds(end_beat), 3)
    report["estimatedKey"] = f"{spelling[key_tonic]} {key_mode}"
    report["notes"] = notes_log
    report["postFxMidiNeeded"] = post_fx_tracks
    report["checkByEar"] = check_tracks
    report["audioTracksNotInKey"] = pitched_audio
    report["soloActive"] = any_solo
    report["truth"] = {"notes": len(truth_notes), "unreliableNotes": len(unreliable), "chords": len(chords),
                       "beats": len(beats), "byRole": dict(collections.Counter(n["part"] for n in truth_notes))}
    rows = []
    for t in tracks:
        if t.kind != "midi":
            continue
        d = per_track[t.id]
        res = d["res"]
        group = "/".join(g.name for g in reversed(ancestors(t)))
        row = collections.OrderedDict()
        row["track"] = t.display
        row["id"] = t.id
        row["group"] = group or None
        row["role"] = d["role"]
        row["suggested"] = d["suggested"][0]
        row["why"] = d["suggested"][1]
        row["state"] = {"muted": auto.false_spans(t.speaker) == [(-math.inf, math.inf)],
                        "muteAutomated": auto.varies(t.speaker), "solo": t.solo, "frozen": t.freeze,
                        "monitoring": {"0": "in", "1": "auto", "2": "off"}.get(t.monitoring, t.monitoring),
                        "sessionClips": t.session_clips}
        st = d["stats"]
        row["counts"] = collections.OrderedDict(
            [("clips", st["clips"]), ("clipEvents", st["clipEvents"]), ("played", st["played"]), ("chased", st["chased"]),
             ("disabled", st["disabled"]), ("clipDisabled", st["clipDisabled"]), ("muted", st["muted"]),
             ("soloedOut", st["soloedOut"]), ("monitorIn", st["monitorIn"]), ("silent", st["silent"]),
             ("outOfRange", st["outOfRange"]), ("beforeExport", st["beforeExport"]),
             ("probabilityBelow1", d["probNotes"]), ("bentAtOnset", st["bentAtOnset"]), ("glides", st["glides"]),
             ("bentOffPitch", st["bentOffPitch"]), ("bendReshaped", st["bendReshaped"]),
             ("pitchEnvelope", st["pitchEnvelope"]), ("clipEnvelope", st["clipEnvelopeNotes"]),
             ("noteLengthApplied", st["noteLength"]),
             ("inKey", d["final"]), ("unreliable", d["unreliable"])])
        row["features"] = d["feats"]
        row["transposes"] = {f"{k:+d}": v for k, v in sorted(d["applied"].items())}
        row["transposeSources"] = [f"{k} (x{v})" for k, v in res.descs.most_common()]
        row["layers"] = [f"{k} (x{v})" for k, v in res.layers.most_common()]
        row["devices"] = res.devices
        row["flags"] = [f.to_json() for f in res.flags.values()]
        row["postFxMidiNeeded"] = any(f.post_fx for f in res.flags.values())
        row["checkByEar"] = any(f.listen for f in res.flags.values())
        rows.append(row)
    report["tracks"] = rows
    report["otherTracks"] = [{"track": t.name, "kind": t.kind, "audioClips": len(t.audio_clips),
                              "muted": auto.false_spans(t.speaker) == [(-math.inf, math.inf)]}
                             for t in tracks if t.kind != "midi"]
    with open(os.path.join(out_dir, "report.json"), "w") as f:
        json.dump(report, f, indent=1)
    with open(os.path.join(out_dir, "report.txt"), "w") as f:
        f.write(render_report(report, truth))
    print(f"wrote {os.path.join(out_dir, 'truth.json')}: {len(truth_notes)} notes "
          f"({', '.join(f'{k} {v}' for k, v in report['truth']['byRole'].items())}), {len(unreliable)} unreliable, "
          f"{len(beats)} beats, {len(chords)} chord spans")
    if post_fx_tracks:
        print("post-FX MIDI needed: " + ", ".join(post_fx_tracks))
    if check_tracks:
        print("check by ear: " + ", ".join(check_tracks))
    for p in written:
        print(f"wrote {p}")
    return truth, report


def render_report(report, truth):
    L = []
    L.append(f"als2truth report: {report['set']}")
    L.append(f"{report['creator']}; tempo {report['tempo']['bpm']:g} BPM" + ("" if report["tempo"]["constant"] else " (automated)") +
             f"; signatures {', '.join(f'{n}/{d}@{b:g}' for b, n, d in report['timeSignatures'])}; "
             f"song end beat {report['songEndBeat']:g} ({report['songEndSeconds']:.2f} s); "
             f"key estimate {report['estimatedKey']}")
    for n in report["notes"]:
        L.append("note: " + n)
    L.append(f"key: {report['truth']['notes']} notes {report['truth']['byRole']}, {report['truth']['unreliableNotes']} unreliable, "
             f"{report['truth']['chords']} chord spans, {report['truth']['beats']} beats; notesComplete={truth['notesComplete']}")
    if report["audioTracksNotInKey"]:
        L.append("audio tracks with pitched content (not in the key): " + ", ".join(report["audioTracksNotInKey"]))
    L.append("")
    if report["postFxMidiNeeded"]:
        L.append("POST-FX MIDI NEEDED (record these tracks' MIDI after their MIDI effects, then re-run):")
        for r in report["tracks"]:
            if r["track"] in report["postFxMidiNeeded"]:
                why = "; ".join(f["detail"] for f in r["flags"] if f["postFxMidiNeeded"])
                L.append(f"  - {r['track']}: {why}")
        L.append("")
    if report.get("checkByEar"):
        L.append("CHECK BY EAR (recording post-FX MIDI cannot fix these; listen, then set trust or addTranspose):")
        for r in report["tracks"]:
            if r["track"] in report["checkByEar"]:
                for f in r["flags"]:
                    if f["checkByEar"]:
                        where = f" ({f['device']})" if f["device"] != r["track"] else ""
                        L.append(f"  - {r['track']}{where}: {f['detail']}" + (" [notes unreliable]" if f["notesUnreliable"] else ""))
        L.append("")
    hdr = f"{'track':22} {'role':13} {'sugg':13} {'clipEv':>6} {'played':>6} {'muted':>5} {'inKey':>5} {'unrel':>5} {'range':>9} {'poly':>5} {'transp':>12}"
    L.append(hdr)
    L.append("-" * len(hdr))
    for r in report["tracks"]:
        c, f = r["counts"], r["features"]
        rng = f"{f['pitchMin']}-{f['pitchMax']}" if f.get("notes") else "-"
        poly = f"{f['polyphony']:.2f}" if f.get("notes") else "-"
        tr = ",".join(f"{k}" for k in r["transposes"]) or "-"
        L.append(f"{r['track'][:22]:22} {r['role']:13} {r['suggested']:13} {c['clipEvents']:6d} {c['played'] + c['chased']:6d} "
                 f"{c['muted'] + c['soloedOut']:5d} {c['inKey']:5d} {c['unreliable']:5d} {rng:>9} {poly:>5} {tr:>12}")
    L.append("")
    for r in report["tracks"]:
        L.append(f"== {r['track']}" + (f"  (group {r['group']})" if r["group"] else "") + f"  role {r['role']} (suggested {r['suggested']}: {r['why']})")
        s = r["state"]
        st = [k for k in ("muted", "muteAutomated", "solo", "frozen") if s[k]]
        if st or s["monitoring"] != "auto":
            L.append(f"   state: {', '.join(st)}{' monitoring ' + s['monitoring'] if s['monitoring'] != 'auto' else ''}")
        c = r["counts"]
        L.append("   counts: " + ", ".join(f"{k} {v}" for k, v in c.items() if v))
        f = r["features"]
        if f.get("notes"):
            L.append(f"   pitch {f['pitchMin']}-{f['pitchMax']} (median {f['pitchMedian']:g}), polyphony {f['polyphony']} (max {f['maxPolyphony']}), "
                     f"{f['notesPerActiveBeat']} notes/active beat, coverage {int(100 * f['coverage'])}%" +
                     (f"; {f['velocityAtMost10']} notes at velocity <= 10 (may be near-silent)" if f.get("velocityAtMost10") else ""))
        if r["transposes"]:
            L.append("   transposes applied: " + ", ".join(f"{k} st x{v}" for k, v in r["transposes"].items()))
        for x in r["transposeSources"][:6]:
            L.append("     from " + x)
        for x in r["layers"][:4]:
            L.append("     layered chains: " + x)
        for fl in r["flags"]:
            L.append(f"   FLAG {fl['kind']}: {fl['detail']}" + (" [post-FX MIDI needed]" if fl["postFxMidiNeeded"] else
                                                                  " [check by ear]" if fl["checkByEar"] else ""))
        L.append("   devices:")
        for dv in r["devices"]:
            L.append("     " + dv)
    return "\n".join(L) + "\n"


PART_RANK = {"melody": 0, "countermelody": 1, "bass": 2, "chords": 3}


def merge_unisons(notes, tol=0.05):
    """Layered tracks doubling a line (a sub bass under a mid bass, a pad doubling the lead) give two
    notes of the same pitch starting together. A transcription can only hear one of them and the
    scorer matches one-to-one, so they become one note: earliest onset, latest offset, the higher
    part (melody > countermelody > bass > chords) and every instrument name ("A + B")."""
    out, merged = [], 0
    for n in sorted(notes, key=lambda n: (n["on"], n["pitch"])):
        twin = None
        for m in reversed(out):
            if n["on"] - m["on"] > tol:
                break
            if m["pitch"] == n["pitch"]:
                twin = m
                break
        if twin is None:
            out.append(dict(n))
            continue
        merged += 1
        twin["off"] = max(twin["off"], n["off"])
        if PART_RANK.get(n["part"], 9) < PART_RANK.get(twin["part"], 9):
            twin["part"] = n["part"]
        if n["instrument"] not in twin["instrument"].split(" + "):
            twin["instrument"] += " + " + n["instrument"]
        if "velocity" in n:
            twin["velocity"] = max(twin.get("velocity", 0), n["velocity"])
        if n.get("flags"):
            twin["flags"] = sorted(set(twin.get("flags", [])) | set(n["flags"]))
    return out, merged


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("set", help="Ableton Live set (.als)")
    p.add_argument("--out", required=True, help="output folder")
    p.add_argument("--roles", help="roles file to honour/write (default OUT/roles.json)")
    p.add_argument("--fresh-roles", action="store_true", help="ignore an existing roles file and write new suggestions")
    p.add_argument("--name", help="truth name (default: set file name)")
    p.add_argument("--export-start", type=float, default=0.0, metavar="BEAT",
                   help="arrangement beat where the rendered audio starts (time 0 of the key)")
    p.add_argument("--offset", type=float, default=0.0, metavar="S", help="seconds added to every time")
    p.add_argument("--include-muted", action="store_true", help="keep notes of muted tracks / muted spans")
    p.add_argument("--ignore-solo", action="store_true", help="ignore solo buttons")
    p.add_argument("--no-chase", action="store_true",
                   help="do not start notes already sounding where a clip begins (Live's 'Chase MIDI notes')")
    p.add_argument("--trust-flagged", action="store_true", help="put every flagged track's notes in the key (post-FX and check-by-ear flags)")
    p.add_argument("--probability", choices=("unreliable", "keep"), default="unreliable",
                   help="notes with chance < 100%%: unreliable (default) or keep in the key")
    p.add_argument("--keep-unisons", action="store_true",
                   help="keep same-pitch notes that start within 50 ms on different tracks as separate notes")
    p.add_argument("--notes-complete", choices=("true", "false"),
                   help="override notesComplete (default: false when audible audio tracks carry pitched parts)")
    args = p.parse_args(argv)
    convert(args)


if __name__ == "__main__":
    main()
