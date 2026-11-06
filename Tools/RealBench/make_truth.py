#!/usr/bin/env python3
"""Helpers that write RealBench truth JSON ("realbench-truth-1"). Standard library only.

  make_truth.py musicbench SONG.json -o truth.json
      MusicBench render JSON -> truth (roles stay melody/chords/bass, drums by GM key,
      beats, downbeats, chords).
  make_truth.py notelist NOTES.json -o truth.json [--part P] [--instrument I] [--from S] [--until S]
      A list of [start, end, pitch(, velocity)] (e.g. semitone training/MIDITEST3_aligned_*.json).
      --from/--until keep notes whose onset falls in [from, until).
  make_truth.py merge A.json B.json ... -o truth.json [--name N]
      Concatenate notes/drums/chords and union ignore spans; beats/downbeats/beatsPerBar and
      flags come from the first file that has them.
For MIDI files use `realbench midi2truth` (tempo maps via AudioToolbox).
"""
import argparse
import json
import sys


def write(obj, path):
    with open(path, "w") as f:
        json.dump(obj, f, indent=1, sort_keys=True)
    n = len(obj.get("notes", []))
    d = len(obj["drums"]) if "drums" in obj else None
    print(f"wrote {path}: {n} notes" + (f", {d} drum hits" if d is not None else "")
          + (f", {len(obj['beats'])} beats" if obj.get("beats") else "")
          + (f", {len(obj['chords'])} chords" if obj.get("chords") else ""))


def from_musicbench(args):
    song = json.load(open(args.song))
    truth = {
        "format": "realbench-truth-1",
        "name": song["name"],
        "source": f"MusicBench render {args.song} (style {song.get('style')}, {song.get('bpm')} BPM, "
                  f"reverb {song.get('reverb')}); times are sampler command times",
        "notes": [{"on": n["on"], "off": n["off"], "pitch": n["pitch"], "velocity": n["velocity"],
                   "part": n["role"], "instrument": f"GM program {n['program']}"} for n in song["notes"]],
        "drums": [{"time": d["time"], "gmNote": d["gmNote"], "velocity": d["velocity"]} for d in song["drums"]],
        "beats": song["beats"],
        "downbeats": song["downbeats"],
        "beatsPerBar": song["beatsPerBar"],
        "chords": [{"start": c["start"], "end": c["end"], "root": c["root"], "quality": c["quality"],
                    "label": c["label"]} for c in song["chords"]],
        "notesComplete": True,
        "offsetsReliable": True,
    }
    write(truth, args.output)


def from_notelist(args):
    raw = json.load(open(args.notes))
    if isinstance(raw, dict):
        raw = raw.get("notes", [])
    notes = []
    for row in raw:
        if isinstance(row, dict):
            on, off, pitch = row.get("on", row.get("start")), row.get("off", row.get("end")), row["pitch"]
            vel = row.get("velocity")
        else:
            on, off, pitch = row[0], row[1], row[2]
            vel = row[3] if len(row) > 3 else None
        if args.start is not None and on < args.start:
            continue
        if args.until is not None and on >= args.until:
            continue
        n = {"on": on, "off": off, "pitch": int(round(pitch)), "part": args.part}
        if vel is not None:
            n["velocity"] = int(round(vel))
        if args.instrument:
            n["instrument"] = args.instrument
        notes.append(n)
    notes.sort(key=lambda n: (n["on"], n["pitch"]))
    truth = {"format": "realbench-truth-1", "name": args.name or args.notes.rsplit("/", 1)[-1].rsplit(".", 1)[0],
             "source": f"notelist {args.notes}", "notes": notes}
    if args.ignore:
        truth["ignore"] = [[float(x) for x in s.split(":")] for s in args.ignore]
    write(truth, args.output)


def merge(args):
    out = {"format": "realbench-truth-1", "notes": []}
    sources = []
    for path in args.inputs:
        t = json.load(open(path))
        sources.append(t.get("source", path))
        out["notes"] += t.get("notes", [])
        if "drums" in t:
            out.setdefault("drums", []).extend(t["drums"])
        if "chords" in t:
            out.setdefault("chords", []).extend(t["chords"])
        if "ignore" in t:
            out.setdefault("ignore", []).extend(t["ignore"])
        for k in ("beats", "downbeats", "beatsPerBar", "name", "notesComplete", "offsetsReliable", "comment"):
            if k in t and k not in out:
                out[k] = t[k]
    out["notes"].sort(key=lambda n: (n["on"], n["pitch"]))
    if "drums" in out:
        out["drums"].sort(key=lambda d: d["time"])
    if "chords" in out:
        out["chords"].sort(key=lambda c: c["start"])
    if args.name:
        out["name"] = args.name
    out["source"] = " + ".join(str(s) for s in sources)
    write(out, args.output)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("musicbench")
    a.add_argument("song")
    a.add_argument("-o", "--output", required=True)
    a.set_defaults(func=from_musicbench)
    b = sub.add_parser("notelist")
    b.add_argument("notes")
    b.add_argument("-o", "--output", required=True)
    b.add_argument("--part", default="notes")
    b.add_argument("--instrument")
    b.add_argument("--name")
    b.add_argument("--from", dest="start", type=float)
    b.add_argument("--until", type=float)
    b.add_argument("--ignore", action="append", help="start:end, repeatable")
    b.set_defaults(func=from_notelist)
    c = sub.add_parser("merge")
    c.add_argument("inputs", nargs="+")
    c.add_argument("-o", "--output", required=True)
    c.add_argument("--name")
    c.set_defaults(func=merge)
    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    sys.exit(main())
