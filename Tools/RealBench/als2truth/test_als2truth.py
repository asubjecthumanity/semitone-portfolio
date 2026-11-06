#!/usr/bin/env python3
"""Tests for als2truth on small synthetic Live sets (standard library only).

  python3 Tools/RealBench/als2truth/test_als2truth.py
"""
import contextlib
import gzip
import json
import math
import os
import struct
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import als2truth as A  # noqa: E402

_ids = [1000]


def nid():
    _ids[0] += 1
    return str(_ids[0])


def E(tag, value=None, *children, **attrs):
    el = ET.Element(tag, {k: str(v) for k, v in attrs.items()})
    if value is not None:
        el.set("Value", str(value))
    for c in children:
        el.append(c)
    return el


def param(tag, manual, macro=None, rng=None):
    """A device parameter; macro=k maps it to the enclosing rack's macro k over rng=(min, max)."""
    el = E(tag, None, E("LomId", 0), E("Manual", manual if not isinstance(manual, bool) else str(manual).lower()))
    if rng:
        el.append(E("MidiControllerRange", None, E("Min", rng[0]), E("Max", rng[1])))
    el.append(E("AutomationTarget", None, E("LockEnvelope", 0), Id=nid()))
    if macro is not None:
        el.append(E("KeyMidi", None, E("Channel", 16), E("NoteOrController", macro)))
    return el


def device(tag, *params, on=True, user=""):
    return E(tag, None, param("On", on), E("UserName", user), *params, Id=nid())


def target_id(el):
    return el.find("AutomationTarget").get("Id")


def envelope(target, events, kind="FloatEvent"):
    evs = E("Events", None)
    for t, v in events:
        evs.append(E(kind, None, Time=t, Value=(str(v).lower() if isinstance(v, bool) else v), Id=nid()))
    return E("AutomationEnvelope", None, E("EnvelopeTarget", None, E("PointeeId", target)),
             E("Automation", None, evs), Id=nid())


def note_events(notes, per_note=()):
    """notes: [(time, duration, pitch, velocity, extra attrs)]; per_note: [(NoteId, CC, [(offset, value)])]
    per-note (MPE) expression (CC -2 is pitch bend, 8192 = 48 semitones; -1 pressure; 74 slide)."""
    by_key = {}
    for n in notes:
        by_key.setdefault(n[2], []).append(n)
    kts = E("KeyTracks", None)
    for key, ns in sorted(by_key.items()):
        evs = E("Notes", None)
        for t, d, _, v, *extra in ns:
            a = {"Time": t, "Duration": d, "Velocity": v, "NoteId": nid()}
            if extra:
                a.update(extra[0])
            evs.append(E("MidiNoteEvent", None, **a))
        kts.append(E("KeyTrack", None, evs, E("MidiKey", key), Id=nid()))
    lists = E("EventLists", None)
    for note_id, cc, events in per_note:
        lst = E("PerNoteEventList", None, NoteId=note_id, CC=cc)
        lst.append(E("Events", None, *[E("PerNoteEvent", None, TimeOffset=t, Value=v, CurveControl1X=0.5,
                                         CurveControl1Y=0.5, CurveControl2X=0.5, CurveControl2Y=0.5)
                                       for t, v in events]))
        lists.append(lst)
    return E("Notes", None, kts, E("PerNoteEventStore", None, lists))


def clip(start, end, notes, loop=False, loop_start=0.0, loop_end=None, start_rel=0.0, disabled=False, per_note=(),
         envelopes=()):
    """envelopes: [(target id, [(time, value)])] clip envelopes in clip time."""
    loop_end = (end - start) if loop_end is None else loop_end
    envs = E("Envelopes", None)
    for target, events in envelopes:
        evs = E("Events", None, *[E("FloatEvent", None, Time=t, Value=v, Id=nid()) for t, v in events])
        envs.append(E("ClipEnvelope", None, E("EnvelopeTarget", None, E("PointeeId", target)),
                      E("Automation", None, evs), Id=nid()))
    return E("MidiClip", None,
             E("CurrentStart", start), E("CurrentEnd", end),
             E("Loop", None, E("LoopStart", loop_start), E("LoopEnd", loop_end), E("StartRelative", start_rel),
               E("LoopOn", str(loop).lower()), E("OutMarker", loop_end), E("HiddenLoopStart", 0), E("HiddenLoopEnd", loop_end)),
             E("Name", ""), E("Disabled", str(disabled).lower()), E("GrooveSettings", None, E("GrooveId", -1)),
             note_events(notes, per_note), E("Envelopes", None, envs), Time=start, Id=nid())


def midi_track(name, devices, clips, speaker=True, group=-1, envelopes=(), tid=None, midi_in="MidiIn/External.All/-1",
               controllers=(), session_clips=()):
    """controllers: ids for MidiControllers/ControllerTargets.0, .1, ... (0 is pitch bend)."""
    mixer = E("Mixer", None, param("Speaker", speaker), E("SoloSink", "false"))
    seq = E("MainSequencer", None, E("ClipTimeable", None, E("ArrangerAutomation", None, E("Events", None, *clips))),
            E("MidiControllers", None, *[E(f"ControllerTargets.{i}", None, E("LockEnvelope", 0), Id=c)
                                         for i, c in enumerate(controllers)]),
            E("ClipSlotList", None, *[E("ClipSlot", None, E("ClipSlot", None, E("Value", None, c)), Id=nid())
                                      for c in session_clips]))
    dc = E("DeviceChain", None, E("MonitoringEnum", 1),
           E("MidiInputRouting", None, E("Target", midi_in)),
           E("MidiOutputRouting", None, E("Target", "MidiOut/None")),
           mixer, seq, E("DeviceChain", None, E("Devices", None, *devices)))
    tr = E("MidiTrack", None, E("Name", None, E("EffectiveName", name), E("UserName", name)),
           E("TrackGroupId", group), E("Freeze", "false"),
           E("AutomationEnvelopes", None, E("Envelopes", None, *envelopes)), dc, Id=tid or nid())
    return tr


def rack(tag, branches, macros=None):
    """branches: [(name, devices, key_range, extra branch children)]"""
    br_tag = {"InstrumentGroupDevice": "InstrumentBranch", "MidiEffectGroupDevice": "MidiEffectBranch"}[tag]
    chain_tag = {"InstrumentGroupDevice": "MidiToAudioDeviceChain", "MidiEffectGroupDevice": "MidiToMidiDeviceChain"}[tag]
    brs = E("Branches", None)
    for name, devs, kr, *extra in branches:
        b = E(br_tag, None, E("Name", None, E("EffectiveName", name)),
              E("DeviceChain", None, E(chain_tag, None, E("Devices", None, *devs))),
              E("ZoneSettings", None, E("KeyRange", None, E("Min", kr[0]), E("Max", kr[1])),
                E("VelocityRange", None, E("Min", 1), E("Max", 127))),
              E("BranchSelectorRange", None, E("Min", 0), E("Max", 127)),
              E("IsSoloed", "false"), E("MixerDevice", None, param("Speaker", True)), Id=nid())
        for x in (extra[0] if extra else []):
            b.append(x)
        brs.append(b)
    r = device(tag, brs, param("ChainSelector", 0))
    for i in range(16):
        r.append(param(f"MacroControls.{i}", (macros or {}).get(i, 0)))
    return r


def operator(transpose):
    return device("Operator", E("Globals", None, param("Transpose", transpose), param("Algorithm", 0)))


def simpler(transpose, macro=None, rng=None):
    return device("OriginalSimpler", E("Pitch", None, param("TransposeKey", transpose, macro=macro, rng=rng),
                                       param("TransposeFine", 0)), E("Globals", None, E("PlaybackMode", 0)))


def operator_full(transpose, ops, pitch_env=None, amount_macro=None):
    """An Operator with oscillators ops = [(coarse, volume, sustain, attack ms, decay ms, pitch env on)]
    (coarse 0 is ratio 0.5) and pitch_env = (amount, (initial, peak, sustain), (attack ms, decay ms));
    amount_macro = (k, (lo, hi)) maps the envelope amount to the enclosing rack's macro k."""
    oscs = []
    for i, (coarse, vol, sus, att, dec, pe) in enumerate(ops):
        oscs.append(E(f"Operator.{i}", None, param("IsOn", True),
                      E("Tune", None, param("Coarse", coarse), param("Fine", 0), param("FixedFrequencyOn", False)),
                      param("Volume", vol), param("PitchEnvOn", pe),
                      E("Envelope", None, param("AttackTime", att), param("AttackLevel", 0.0003), param("DecayTime", dec),
                        param("DecayLevel", 1), param("SustainLevel", sus), param("LoopMode", 0))))
    for i in range(len(ops), 4):
        oscs.append(E(f"Operator.{i}", None, param("IsOn", False)))
    amount, levels, times = pitch_env or (0, (0, 0, 0), (0.1, 0.1))
    k, rng = amount_macro if amount_macro else (None, None)
    pe = E("PitchEnv", None, param("PitchEnvOn", pitch_env is not None),
           E("PitchEnv", None, param("EnvelopeAmount", amount, macro=k, rng=rng), param("AttackLevel", levels[0]),
             param("DecayLevel", levels[1]), param("SustainLevel", levels[2]), param("AttackTime", times[0]),
             param("DecayTime", times[1]), param("LoopMode", 0)))
    return device("Operator", E("Globals", None, param("Transpose", transpose), param("Algorithm", 0)), *oscs, pe)


SOURCES = ["Velocity", "Modwheel", "Pitchbend", "Pressure", "Expression", "Keytrack", "Random", "Increment", "Slide",
           "Sustain"]


def expression_control(refs, sources=("Pressure",)):
    """A Max Expression Control whose slots map to the parameters with LomIds refs = [(slot obj prefix, lom)]."""
    plist = E("ParameterList", None)
    for i, src in enumerate(sources, 1):
        plist.append(E("MxDEnumParameter", None, E("Name", f"Source {i}"),
                       E("Timeable", None, E("LomId", 0), E("Manual", SOURCES.index(src)),
                         E("AutomationTarget", None, Id=nid())),
                       E("Names", None, *[E("Name", None, E("Name", n), Id=j) for j, n in enumerate(SOURCES)])))
    refs_el = E("IdRefList", None, *[E("MxDIdRef", None, E("Name", f"{obj}::obj-16::obj-5"), E("LomId", lom),
                                       E("Property", "id"), Id=nid()) for obj, lom in refs])
    patch = E("PatchSlot", None, E("Value", None, E("MxPatchRef", None, E("FileRef", None, E(
        "RelativePath", "Devices/MIDI Effects/Expression Control/Expression Control.amxd")))))
    return device("MxDeviceMidiEffect", patch, E("ParameterList", None, plist), E("IdRefList", None, refs_el))


def set_lom(el, lom):
    el.find("LomId").set("Value", str(lom))
    return el


def live_set(tracks, bpm=120, sig=201, tempo_events=None, master_envs=()):
    tempo = param("Tempo", bpm)
    sigp = param("TimeSignature", sig)
    envs = list(master_envs)
    if tempo_events:
        envs.append(envelope(target_id(tempo), tempo_events))
    master = E("MasterTrack", None, E("AutomationEnvelopes", None, E("Envelopes", None, *envs)),
               E("DeviceChain", None, E("Mixer", None, tempo, sigp)))
    ls = E("LiveSet", None, E("Tracks", None, *tracks), master)
    return E("Ableton", None, ls, MajorVersion=5, MinorVersion="11.0", Creator="Test"), tempo


def write_set(root, folder, name="test.als"):
    path = os.path.join(folder, name)
    with open(path, "wb") as f:
        f.write(gzip.compress(ET.tostring(root)))
    return path


def load(path):
    with open(path) as f:
        return json.load(f)


def run(path, out, *extra):
    with open(os.devnull, "w") as quiet, contextlib.redirect_stdout(quiet):
        A.main([path, "--out", out] + list(extra))
    return load(os.path.join(out, "truth.json"))


def report(out):
    return {r["track"]: r for r in load(os.path.join(out, "report.json"))["tracks"]}


class ClipTests(unittest.TestCase):
    def test_looped_clip_unrolls_with_start_offset(self):
        c = clip(16, 26, [(0, 0.5, 60, 100), (1, 0.5, 61, 100), (2, 0.5, 62, 100), (3, 0.5, 63, 100),
                          (3.5, 1.0, 64, 100)], loop=True, loop_start=0, loop_end=4, start_rel=1)
        notes, st = A.expand_clip(c)
        got = [(round(n.on, 6), n.pitch, round(n.off - n.on, 6)) for n in notes]
        # the start marker (local 1) sits at the clip start: pass 1 plays local 1..4 from beat 16,
        # pass 2 local 0..4 from 19, pass 3 local 0..3 from 23 (the clip ends at 26)
        want_on = [16, 17, 18, 18.5, 19, 20, 21, 22, 22.5, 23, 24, 25]
        self.assertEqual(sorted(g[0] for g in got), want_on)
        # the note crossing the loop end is cut there, on every pass
        self.assertIn((18.5, 64, 0.5), got)
        self.assertIn((22.5, 64, 0.5), got)
        self.assertEqual(st["played"], 12)

    def test_unlooped_clip_start_marker_and_cut(self):
        c = clip(32, 40, [(2, 1, 50, 90), (4, 1, 51, 90), (11.5, 2, 52, 90), (12, 1, 53, 90)],
                 loop=False, loop_start=4, loop_end=12)
        notes, _ = A.expand_clip(c, chase=False)
        self.assertEqual([(n.on, n.pitch, n.off) for n in notes], [(32, 51, 33), (39.5, 52, 40)])

    def test_chase_starts_a_note_already_sounding(self):
        c = clip(0, 8, [(-0.25, 2, 60, 90), (1, 1, 62, 90)], loop=False, loop_start=0, loop_end=8)
        notes, st = A.expand_clip(c)
        self.assertEqual([(n.on, n.pitch, n.off, n.chased) for n in notes], [(0, 60, 1.75, True), (1, 62, 2, False)])
        notes, _ = A.expand_clip(c, chase=False)
        self.assertEqual(len(notes), 1)

    def test_disabled_notes_and_clips(self):
        c = clip(0, 4, [(0, 1, 60, 90, {"IsEnabled": "false"}), (1, 1, 61, 90)])
        notes, st = A.expand_clip(c)
        self.assertEqual([n.pitch for n in notes], [61])
        self.assertEqual(st["disabled"], 1)
        notes, st = A.expand_clip(clip(0, 4, [(0, 1, 60, 90)], disabled=True))
        self.assertEqual(notes, [])


class TempoTests(unittest.TestCase):
    def test_constant_and_ramp(self):
        tm = A.TempoMap(120)
        self.assertAlmostEqual(tm.seconds(8), 4.0)
        tm = A.TempoMap(120, [(A.FAR_PAST, 120, "float"), (0, 120, "float"), (8, 180, "float")])
        self.assertAlmostEqual(tm.seconds(8), 60 / 7.5 * math.log(1.5), places=9)
        self.assertAlmostEqual(tm.seconds(10) - tm.seconds(8), 2 * 60 / 180, places=9)
        # a step: two breakpoints at the same beat
        tm = A.TempoMap(100, [(A.FAR_PAST, 100, "float"), (4, 100, "float"), (4, 200, "float")])
        self.assertAlmostEqual(tm.seconds(6), 4 * 0.6 + 2 * 0.3, places=9)

    def test_signatures_and_grid(self):
        self.assertEqual(A.decode_signature(201), (4, 4))
        self.assertEqual(A.decode_signature(302), (6, 8))
        self.assertEqual(A.decode_signature(200), (3, 4))
        grid, bpb = A.beat_grid([(0.0, 6, 8)], 6)
        self.assertEqual(bpb, 2)
        self.assertEqual([b for b, _ in grid], [0, 1.5, 3, 4.5, 6])
        self.assertEqual([b for b, d in grid if d], [0, 3, 6])


class ChordTests(unittest.TestCase):
    def w(self, pcs):
        x = [0.0] * 12
        for p in pcs:
            x[p % 12] += 1
        return x

    def test_labels(self):
        self.assertEqual(A.label_chord(self.w([0, 4, 7]), None), "C:maj")
        self.assertEqual(A.label_chord(self.w([9, 0, 4]), 0), "A:min/b3")
        self.assertEqual(A.label_chord(self.w([7, 11, 2, 5]), 7), "G:7")
        self.assertEqual(A.label_chord(self.w([2, 5, 9, 0]), 2), "D:min7")
        self.assertEqual(A.label_chord(self.w([0]), None), "N")
        self.assertEqual(A.label_chord([0.0] * 12, None), "N")


class ConvertTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def build(self):
        # bass: Operator -24, looped 4-beat clip played 3 times from beat 0
        bass = midi_track("Sub Bass", [operator(-24)],
                          [clip(0, 12, [(0, 1, 60, 100), (2, 1, 67, 100)], loop=True, loop_end=4)])
        # chords: Pitch +12 before a key-split rack (low chain 0, high chain +12)
        pitcher = device("MidiPitcher", param("Pitch", 12), param("Lowest", 0), param("Range", 127))
        split = rack("InstrumentGroupDevice", [("low", [operator(0)], (0, 59)), ("high", [operator(12)], (60, 127))])
        keys = midi_track("Keys", [pitcher, split],
                          [clip(0, 8, [(0, 4, 36, 80), (0, 4, 40, 80), (0, 4, 43, 80),
                                       (4, 4, 48, 80), (4, 4, 52, 80), (4, 4, 55, 80)])])
        # lead: Simpler whose transpose is mapped to a macro automated 0 -> 127 at beat 8
        sp = simpler(0, macro=0, rng=(-12, 0))
        lead_rack = rack("InstrumentGroupDevice", [("s", [sp], (0, 127))])
        macro_env = envelope(target_id(lead_rack.find("MacroControls.0")), [(A.FAR_PAST, 0), (8, 0), (8, 127)])
        lead = midi_track("Lead Synth", [lead_rack],
                          [clip(0, 16, [(1, 1, 72, 90), (9, 1, 72, 90), (10, 1, 74, 90, {"Probability": "0.5"})])],
                          envelopes=[macro_env])
        # arpeggiated pad: flagged, raw notes unreliable
        arp = midi_track("Arp Pad", [device("MidiArpeggiator", param("TransposeSteps", 0)), operator(12)],
                         [clip(0, 8, [(0, 8, 60, 70), (0, 8, 64, 70), (0, 8, 67, 70)])], tid="500")
        # post-FX MIDI recorded from the arp track: no instrument, so it sounds through Arp Pad's
        # Operator (+12) with the arpeggiator skipped, and is not flagged
        rec = midi_track("Arp Pad Recorded", [], [clip(0, 4, [(0, 0.25, 60, 70), (0.25, 0.25, 64, 70)])],
                         midi_in="MidiIn/Track.500/PostFxOut")
        # Note Length (note-on mode, 100 ms x 50% gate) fixes every duration to 50 ms
        nl = device("MidiNoteLength", param("Mode", False), param("SyncState", False), param("TimeLength", 100),
                    param("Gate", 50))
        blip = midi_track("Blip", [nl, operator(0)], [clip(0, 4, [(0, 2, 64, 100), (2, 2, 67, 100)])])
        # drums: omitted
        drums = midi_track("Drums", [device("DrumGroupDevice")], [clip(0, 4, [(0, 0.1, 36, 100), (1, 0.1, 38, 100)])])
        # muted track and a track muted by automation from beat 4
        muted = midi_track("Muted Line", [operator(0)], [clip(0, 4, [(0, 1, 70, 90)])], speaker=False)
        mt = midi_track("Gated Line", [operator(0)], [clip(0, 8, [(0, 1, 76, 90), (3, 2, 77, 90), (6, 1, 79, 90)])])
        spk = mt.find("DeviceChain/Mixer/Speaker")
        mt.find("AutomationEnvelopes/Envelopes").append(
            envelope(target_id(spk), [(A.FAR_PAST, True), (4, True), (4, False)], kind="BoolEvent"))
        root, _ = live_set([bass, keys, lead, arp, rec, blip, drums, muted, mt], bpm=120)
        return write_set(root, self.dir)

    def test_end_to_end(self):
        path = self.build()
        out = os.path.join(self.dir, "out")
        truth = run(path, out)
        rep = report(out)
        notes = truth["notes"]
        by = lambda inst: sorted((n["on"], n["pitch"]) for n in notes if n["instrument"] == inst)
        # tempo 120: one beat = 0.5 s
        self.assertEqual(by("Sub Bass"), [(0.0, 36), (1.0, 43), (2.0, 36), (3.0, 43), (4.0, 36), (5.0, 43)])
        self.assertEqual([n["part"] for n in notes if n["instrument"] == "Sub Bass"], ["bass"] * 6)
        # Pitch +12 moves 36/40/43 to 48/52/55 (low chain) and 48.. to 60.. (high chain, +12)
        self.assertEqual(by("Keys"), [(0.0, 48), (0.0, 52), (0.0, 55), (2.0, 72), (2.0, 76), (2.0, 79)])
        # macro-mapped transpose: -12 before beat 8, 0 after; the 50% note is unreliable
        self.assertEqual(by("Lead Synth"), [(0.5, 60), (4.5, 72)])
        unrel = truth["unreliableNotes"]
        self.assertTrue(any(n["instrument"] == "Lead Synth" and n["pitch"] == 74 and n["flags"] == ["chance 0.50"] for n in unrel))
        self.assertEqual(sorted(n["pitch"] for n in unrel if n["instrument"] == "Arp Pad"), [72, 76, 79])
        self.assertIn("Arp Pad", truth["als2truth"]["postFxMidiNeeded"])
        self.assertEqual(by("Arp Pad Recorded"), [(0.0, 72), (0.125, 76)])
        self.assertNotIn("Arp Pad Recorded", truth["als2truth"]["postFxMidiNeeded"])
        # 50 ms notes are thumps, not a line: suggested ignore (their Note Length durations are
        # checked in test_roles_file_is_honoured)
        self.assertEqual(rep["Blip"]["suggested"], "ignore")
        self.assertIn("shorter than 100 ms", rep["Blip"]["why"])
        self.assertFalse(any(n["instrument"] == "Blip" for n in notes))
        self.assertTrue(truth["offsetsReliable"])
        self.assertFalse(any(n["instrument"] in ("Drums", "Muted Line") for n in notes + unrel))
        self.assertNotIn("drums", truth)
        # mute automation from beat 4: the note at 3 is cut at 4, the note at 6 is dropped
        gated = sorted((n["on"], n["off"], n["pitch"]) for n in notes + unrel if n["instrument"] == "Gated Line")
        self.assertEqual(gated, [(0.0, 0.5, 76), (1.5, 2.0, 77)])
        self.assertEqual(rep["Gated Line"]["counts"]["muted"], 1)
        # grid and chords from the chords role
        self.assertEqual(truth["beats"][:3], [0.0, 0.5, 1.0])
        self.assertEqual(truth["downbeats"][:2], [0.0, 2.0])
        self.assertEqual(rep["Keys"]["role"], "chords")
        self.assertEqual(rep["Drums"]["role"], "ignore")
        self.assertEqual(rep["Sub Bass"]["role"], "bass")
        labels = [c["label"] for c in truth["chords"]]
        self.assertEqual(labels[0], "C:maj")
        # MIDI files are valid SMF with the expected notes
        self.assertEqual(sorted(p for _, p in midi_notes(os.path.join(out, "midi", "bass.mid"))), [36, 36, 36, 43, 43, 43])
        self.assertTrue(os.path.exists(os.path.join(out, "midi", "unreliable.mid")))

    def test_roles_file_is_honoured(self):
        path = self.build()
        out = os.path.join(self.dir, "out")
        run(path, out)
        roles_path = os.path.join(out, "roles.json")
        roles = load(roles_path)
        for e in roles["tracks"]:
            if e["track"] == "Keys":
                e["role"] = "countermelody"
                e["addTranspose"] = -12
            if e["track"] == "Arp Pad":
                e["trust"] = True
            if e["track"] == "Blip":
                e["role"] = "countermelody"
        with open(roles_path, "w") as f:
            json.dump(roles, f)
        # Keys at -12 double the Sub Bass's first note; keep the layers apart to check each track
        truth = run(path, out, "--keep-unisons")
        blips = sorted((n["on"], n["off"]) for n in truth["notes"] if n["instrument"] == "Blip")
        self.assertEqual(blips, [(0.0, 0.05), (1.0, 1.05)])
        keys = [n for n in truth["notes"] if n["instrument"] == "Keys"]
        self.assertEqual({n["part"] for n in keys}, {"countermelody"})
        self.assertEqual(sorted(n["pitch"] for n in keys)[:3], [36, 40, 43])
        self.assertEqual(sorted(n["pitch"] for n in truth["notes"] if n["instrument"] == "Arp Pad"), [72, 76, 79])
        # the user's edits survive the re-run
        self.assertEqual([e["role"] for e in load(roles_path)["tracks"] if e["track"] == "Keys"], ["countermelody"])

    def test_export_start_and_tempo_ramp(self):
        bass = midi_track("Bass", [operator(0)], [clip(0, 16, [(8, 1, 40, 100), (12, 1, 41, 100)])])
        root, tempo = live_set([bass], bpm=120, tempo_events=[(A.FAR_PAST, 120), (0, 120), (8, 120), (16, 240)])
        path = write_set(root, self.dir)
        out = os.path.join(self.dir, "out2")
        truth = run(path, out, "--export-start", "8")
        ons = [n["on"] for n in truth["notes"]]
        self.assertAlmostEqual(ons[0], 0.0, places=4)
        k = 120 / 8.0
        self.assertAlmostEqual(ons[1], round(60 / k * math.log(180 / 120), 5), places=4)


    def test_unison_layers_merge(self):
        # a sub and a mid bass doubling the same line, plus a lead an octave up: the doubled notes
        # become one (latest offset, both names), the octave stays separate
        sub = midi_track("Bass Sub", [operator(0)], [clip(0, 4, [(0, 1, 36, 100), (2, 1, 38, 100)])])
        mid = midi_track("Bass Short", [operator(0)], [clip(0, 4, [(0.05, 0.5, 36, 90), (2, 2, 38, 90)])])
        top = midi_track("Lead", [operator(0)], [clip(0, 4, [(0, 1, 48, 90)])])
        root, _ = live_set([sub, mid, top], bpm=120)
        path = write_set(root, self.dir, "unison.als")
        truth = run(path, os.path.join(self.dir, "u1"))
        got = sorted((n["on"], n["off"], n["pitch"], n["instrument"]) for n in truth["notes"] if n["part"] == "bass")
        self.assertEqual(got, [(0.0, 0.5, 36, "Bass Sub + Bass Short"), (1.0, 2.0, 38, "Bass Sub + Bass Short")])
        self.assertEqual(truth["als2truth"]["unisonsMerged"], 2)
        self.assertTrue(any(n["pitch"] == 48 for n in truth["notes"]))
        kept = run(path, os.path.join(self.dir, "u2"), "--keep-unisons")
        self.assertEqual(sum(1 for n in kept["notes"] if n["part"] == "bass"), 4)


class BoundaryTests(unittest.TestCase):
    def test_note_stored_a_hair_before_the_boundary_is_played(self):
        # Live stores some boundary notes at -2.6e-7: they are on the boundary, not chased
        c = clip(8, 16, [(-0.00000026, 1, 60, 90), (2, 1, 62, 90)], loop=True, loop_start=0, loop_end=4)
        notes, st = A.expand_clip(c)
        self.assertEqual(st["chased"], 0)
        self.assertEqual(sorted((n.on, n.pitch) for n in notes), [(8, 60), (10, 62), (12, 60), (14, 62)])
        notes, _ = A.expand_clip(c, chase=False)
        self.assertEqual(len(notes), 4)


class PitchCheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def convert(self, tracks, *extra):
        # the tracks here play the same notes to compare how each sounds: keep the unisons apart
        root, _ = live_set(tracks, bpm=120)
        out = os.path.join(self.dir, "out")
        truth = run(write_set(root, self.dir), out, "--keep-unisons", *extra)
        return truth, report(out), load(os.path.join(out, "report.json"))

    def by(self, truth, inst, key="notes"):
        return sorted((n["on"], n["pitch"]) for n in truth[key] if n["instrument"] == inst)

    def test_per_note_bend_between_semitones_is_unreliable(self):
        per = 8192 / 48.0
        c = clip(0, 4, [(0, 1, 60, 100, {"NoteId": "n1"}), (1, 1, 62, 100, {"NoteId": "n2"}), (2, 1, 64, 100)],
                 per_note=[("n1", "-2", [(0, 2 * per)]), ("n2", "-2", [(0, 18.55 * per)])])
        truth, rep, _ = self.convert([midi_track("Lead Synth", [operator(0)], [c])])
        self.assertEqual(self.by(truth, "Lead Synth"), [(0.0, 62), (1.0, 64)])  # +2 applied
        unrel = [n for n in truth["unreliableNotes"] if n["instrument"] == "Lead Synth"]
        self.assertEqual([(n["pitch"], n["flags"]) for n in unrel], [(81, ["bend between semitones"])])
        self.assertEqual(rep["Lead Synth"]["counts"]["bentOffPitch"], 1)

    def test_operator_pitch_envelope_and_sub_ratio(self):
        # a -48 st swoop that settles after 500 ms: a 250 ms note never reaches its pitch
        swoop = operator_full(0, [(1, 1.0, 1.0, 0.1, 1000, True)], pitch_env=(-1, (48, 0, 0), (500, 1000)))
        sw = midi_track("Swoop Lead", [swoop], [clip(0, 8, [(0, 0.5, 60, 100), (2, 2, 62, 100)])])
        # the same envelope with its amount on a rack macro at 0: no swoop
        held = operator_full(0, [(1, 1.0, 1.0, 0.1, 1000, True)], pitch_env=(-1, (48, 0, 0), (500, 1000)),
                             amount_macro=(4, (0, -1)))
        mr = midi_track("Macro Lead", [rack("InstrumentGroupDevice", [("op", [held], (0, 127))], macros={4: 0})],
                        [clip(0, 8, [(0, 0.5, 60, 100), (2, 2, 62, 100)])])
        # the only ratio-1 oscillator dies in 74 ms; ratio-0.5 oscillators hold: an octave below the key
        sub = operator_full(-24, [(1, 0.52, 0.0003, 0.1, 73.5, False), (0, 1.0, 0.0003, 0.1, 2718, False),
                                  (0, 0.1, 0.0003, 0.1, 816, False)])
        sb = midi_track("Sub Bass", [sub], [clip(0, 8, [(0, 1, 72, 100), (2, 1, 79, 100)])])
        # ratio 1 holding with ratio 3: no change
        fm = operator_full(0, [(1, 1.0, 1.0, 0.1, 1000, False), (3, 0.5, 1.0, 0.1, 1000, False)])
        fb = midi_track("FM Keys", [fm], [clip(0, 8, [(0, 1, 60, 100)])])
        truth, rep, _ = self.convert([sw, mr, sb, fb])
        self.assertEqual(self.by(truth, "Swoop Lead"), [(1.0, 62)])
        self.assertEqual([n["flags"] for n in truth["unreliableNotes"] if n["instrument"] == "Swoop Lead"],
                         [["pitch envelope"]])
        self.assertTrue(any(f["kind"] == "pitch-envelope" and "495 ms" in f["detail"] for f in rep["Swoop Lead"]["flags"]))
        self.assertEqual(self.by(truth, "Macro Lead"), [(0.0, 60), (1.0, 62)])
        self.assertFalse(any(f["kind"] == "pitch-envelope" for f in rep["Macro Lead"]["flags"]))
        self.assertEqual(self.by(truth, "Sub Bass"), [(0.0, 36), (1.0, 43)])  # -24 transpose, -12 body
        self.assertTrue(any(f["kind"] == "operator-ratio" and "applied" in f["detail"] for f in rep["Sub Bass"]["flags"]))
        self.assertEqual(self.by(truth, "FM Keys"), [(0.0, 60)])
        # trust keeps the swept note
        truth2 = run(os.path.join(self.dir, "test.als"), os.path.join(self.dir, "out"), "--trust-flagged", "--keep-unisons")
        self.assertEqual(self.by(truth2, "Swoop Lead"), [(0.0, 60), (1.0, 62)])

    def test_expression_control_mappings(self):
        def track(name, lom, pressure, target):
            if target == "pitch":  # macro 1 -> Simpler transpose, the way Rose Bass maps it
                inner = simpler(0, macro=0, rng=(0, 12))
                ec = expression_control([("obj-25", lom)])
                r = rack("InstrumentGroupDevice", [("chain", [ec, inner], (0, 127))], macros={0: 0})
                set_lom(r.find("MacroControls.0"), lom)
                devices = [r]
            else:  # directly to a filter cutoff
                cutoff = set_lom(param("Cutoff", 100), lom)
                devices = [expression_control([("obj-25", lom)]), operator(0), device("AutoFilter", cutoff)]
            notes = [(0, 1, 48, 100, {"NoteId": f"{name}-1"}), (2, 1, 50, 100)]
            per = [(f"{name}-1", "-1", [(0, 0), (0.5, 90)])] if pressure else []
            return midi_track(name, devices, [clip(0, 4, notes, per_note=per)])

        truth, rep, full = self.convert([track("Rose Bass", 970, False, "pitch"), track("Press Bass", 971, True, "pitch"),
                                         track("Filter Bass", 972, True, "filter")])
        # pressure -> pitch, but no pressure in the clips: kept, listed to check by ear
        self.assertEqual(self.by(truth, "Rose Bass"), [(0.0, 48), (1.0, 50)])
        f = [x for x in rep["Rose Bass"]["flags"] if x["kind"] == "max-mapping"][0]
        self.assertIn("no Pressure data", f["detail"])
        self.assertTrue(f["checkByEar"] and not f["postFxMidiNeeded"])
        # with pressure data: unreliable, but recording post-FX MIDI would not help
        self.assertEqual(self.by(truth, "Press Bass"), [])
        self.assertEqual({tuple(n["flags"]) for n in truth["unreliableNotes"] if n["instrument"] == "Press Bass"},
                         {("max-mapping",)})
        # no pitch parameter: kept
        self.assertEqual(self.by(truth, "Filter Bass"), [(0.0, 48), (1.0, 50)])
        self.assertEqual(full["postFxMidiNeeded"], [])
        self.assertEqual(full["checkByEar"], ["Rose Bass", "Press Bass"])

    def test_clip_pitch_bend_envelope(self):
        c = clip(0, 8, [(0, 1, 60, 100), (2, 1, 62, 100), (4, 1, 64, 100)],
                 envelopes=[("9001", [(-63072000, 0), (1.99, 0), (2, 4096), (3, 4096), (3.01, 0)]),
                            ("9002", [(-63072000, 0), (0, 0)])])
        truth, rep, _ = self.convert([midi_track("Keys Line", [operator(0)], [c], controllers=["9001", "9002"])])
        self.assertEqual(self.by(truth, "Keys Line"), [(0.0, 60), (2.0, 64)])
        self.assertEqual([n["flags"] for n in truth["unreliableNotes"]], [["clip pitch bend"]])
        details = [f["detail"] for f in rep["Keys Line"]["flags"] if f["kind"] == "clip-envelope"]
        self.assertTrue(any("1 notes start under a bend" in d for d in details))
        self.assertTrue(any("channel pressure" in d and "not read" in d for d in details))

    def test_session_only_set_writes_nothing(self):
        t = midi_track("Keys", [operator(0)], [], session_clips=[E("MidiClip", None, Id=nid())])
        root, _ = live_set([t])
        out = os.path.join(self.dir, "out")
        with open(os.devnull, "w") as quiet, contextlib.redirect_stdout(quiet):
            with self.assertRaises(SystemExit) as cm:
                A.main([write_set(root, self.dir), "--out", out])
        self.assertIn("Session View", str(cm.exception.code))
        self.assertFalse(os.path.exists(os.path.join(out, "truth.json")))


def midi_notes(path):
    with open(path, "rb") as f:
        data = f.read()
    assert data[:4] == b"MThd"
    ntrk = struct.unpack(">H", data[10:12])[0]
    pos, out = 14, []
    for _ in range(ntrk):
        assert data[pos:pos + 4] == b"MTrk"
        ln = struct.unpack(">I", data[pos + 4:pos + 8])[0]
        trk, i, t, status = data[pos + 8:pos + 8 + ln], 0, 0, 0
        while i < len(trk):
            d = 0
            while True:
                b = trk[i]
                i += 1
                d = (d << 7) | (b & 0x7F)
                if not b & 0x80:
                    break
            t += d
            b = trk[i]
            if b == 0xFF:  # meta event: type byte, then a variable-length size
                j, ln2 = i + 2, 0
                while True:
                    c = trk[j]
                    j += 1
                    ln2 = (ln2 << 7) | (c & 0x7F)
                    if not c & 0x80:
                        break
                i = j + ln2
                continue
            status = b
            i += 1
            if status & 0xF0 in (0x80, 0x90, 0xA0, 0xB0, 0xE0):
                p, v = trk[i], trk[i + 1]
                i += 2
                if status & 0xF0 == 0x90 and v > 0:
                    out.append((t, p))
            else:
                i += 1
        pos += 8 + ln
    return out


if __name__ == "__main__":
    unittest.main(verbosity=1)
