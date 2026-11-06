#!/usr/bin/env python3
"""Cross-checks an als2truth output folder against an independent count of the set's clip notes.

  python3 Tools/RealBench/als2truth/check_als.py SONG.als OUT_DIR

Shares no clip code with als2truth: notes are counted per arrangement clip with closed-form loop
arithmetic (first pass from the start marker, whole loops, the partial last pass), then compared
per track with report.json ("played", not counting notes chased into a clip). For tracks in the key it
also matches truth + unreliable notes to the recount by onset and prints the pitch shift between
clip pitch and key pitch (the instrument/MIDI-effect transposes), and checks the beat grid's tempo.
Exit status 1 when a count differs.
"""
import collections
import gzip
import json
import os
import sys
import xml.etree.ElementTree as ET


def v(el, path):
    x = el.find(path)
    return None if x is None else x.get("Value")


# Live stores some notes a hair before a clip or loop boundary (-2.6e-7 by float error); a note
# within this many beats of a boundary is on it.
TOL = 1e-4


def notes_in(events, a, b):
    return [(max(t, a), p) for t, p in events if a - TOL <= t < b - TOL]


def recount_clip(clip):
    """[(arrangement beat, clip pitch)] of the enabled notes this clip plays (onset inside the clip)."""
    if v(clip, "Disabled") == "true":
        return []
    events = []
    for kt in clip.iter("KeyTrack"):
        key = int(v(kt, "MidiKey"))
        for n in kt.iter("MidiNoteEvent"):
            if n.get("IsEnabled") != "false":
                events.append((float(n.get("Time")), key))
    cs, ce = float(v(clip, "CurrentStart")), float(v(clip, "CurrentEnd"))
    length = ce - cs
    ls, le = float(v(clip, "Loop/LoopStart")), float(v(clip, "Loop/LoopEnd"))
    marker = ls + float(v(clip, "Loop/StartRelative"))
    if v(clip, "Loop/LoopOn") != "true":
        return [(cs + t - marker, p) for t, p in notes_in(events, marker, marker + length)]
    period = le - ls
    out = []
    first = min(le - marker, length)
    out += [(cs + t - marker, p) for t, p in notes_in(events, marker, marker + first)]
    whole, rest = divmod(length - first, period)
    body = notes_in(events, ls, le)
    for k in range(int(round(whole)) if abs(whole - round(whole)) < 1e-9 else int(whole)):
        base = cs + first + k * period
        out += [(base + t - ls, p) for t, p in body]
    base = cs + first + int(whole) * period
    out += [(base + t - ls, p) for t, p in notes_in(events, ls, ls + rest)]
    return out


def main():
    als, out_dir = sys.argv[1], sys.argv[2]
    with open(als, "rb") as f:
        root = ET.fromstring(gzip.decompress(f.read()))
    with open(os.path.join(out_dir, "report.json")) as f:
        report = json.load(f)
    with open(os.path.join(out_dir, "truth.json")) as f:
        truth = json.load(f)
    master = root.find("LiveSet/MasterTrack")
    if master is None:
        master = root.find("LiveSet/MainTrack")
    bpm = float(v(master, "DeviceChain/Mixer/Tempo/Manual"))
    rows = {r["id"]: r for r in report["tracks"]}
    bad = 0
    print(f"{'track':22} {'recount':>7} {'report':>7}  {'inKey+unrel':>11}  pitch shift clip->key (onset-matched)")
    for t in root.find("LiveSet/Tracks"):
        if t.tag != "MidiTrack":
            continue
        tid = t.get("Id")
        row = rows[tid]
        played = []
        for c in t.findall("DeviceChain/MainSequencer/ClipTimeable/ArrangerAutomation/Events/MidiClip"):
            played += recount_clip(c)
        mine = len(played)
        theirs = row["counts"]["played"]
        ok = mine == theirs
        bad += not ok
        shift = ""
        if row["role"] != "ignore" and report["tempo"]["constant"]:
            sec = 60.0 / bpm
            origin = truth["als2truth"]["exportStartBeat"]
            key = collections.defaultdict(list)
            for n in truth["notes"] + truth.get("unreliableNotes", []):
                if n["instrument"] == row["track"]:
                    key[round(n["on"] / sec + origin, 3)].append(n["pitch"])
            raw = collections.defaultdict(list)
            for b, p in played:
                raw[round(b, 3)].append(p)
            diffs = collections.Counter()
            for b, ps in key.items():
                if b in raw and len(raw[b]) == len(ps):
                    for x, y in zip(sorted(raw[b]), sorted(ps)):
                        diffs[y - x] += 1
            shift = ", ".join(f"{d:+d} x{c}" for d, c in sorted(diffs.items()))
        total = row["counts"]["inKey"] + row["counts"]["unreliable"]
        print(f"{row['track'][:22]:22} {mine:7d} {theirs:7d}  {total:11d}  {shift}{'' if ok else '   <-- MISMATCH'}")
    beats = truth.get("beats", [])
    if len(beats) > 2 and report["tempo"]["constant"]:
        gaps = [round(b - a, 4) for a, b in zip(beats, beats[1:])]
        print(f"tempo {bpm:g} BPM: beat gaps {min(gaps)}..{max(gaps)} s (expected {60 / bpm:.4f})")
        if max(abs(g - 60 / bpm) for g in gaps) > 2e-4:
            bad += 1
            print("   <-- beat grid does not match the tempo")
    print("OK" if not bad else f"{bad} mismatches")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
