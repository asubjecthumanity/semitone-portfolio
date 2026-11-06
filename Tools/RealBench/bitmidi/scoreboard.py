#!/usr/bin/env python3
"""Song mode scoreboard over the bitmidi songs (real recordings, fan-MIDI keys).

Standard library only. Reads realbench's own outputs (summary.json, score.json,
diagnostics.json); it never opens audio or MIDI. See README.md, "Scoreboard".

  scoreboard.py run --tag NAME [--songs a,b] [--pipelines music,quick-music] [-- realbench options]
  scoreboard.py collect --tag NAME [--json OUT.json] [--md OUT.md]
  scoreboard.py compare BASE.json NEW.json [--md OUT.md]

`run` transcribes every song with realbench, one song at a time, into
<songs>/<slug>/results/<tag>/, and re-scores the saved predictions against each
pitch alternate key (results/<tag>/alt-<key>/). `collect` gathers the metrics
of every song into one JSON and a Markdown table, with the tuning objective.
`compare` checks a new scoreboard against a base one with the guardrails and
exits 0 when the change is accepted, 1 when it is not.

Songs folder: --songs-dir, else $BITMIDI_SONGS, else <repo>/bench/songs/bitmidi.
realbench: --realbench, else Tools/RealBench/.build/realbench next to this file.
"""

import argparse
import json
import math
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
SONGS_JSON = os.path.join(HERE, "songs.json")

# The objective: one number per song, a weighted mean of the headline metrics
# (each 0-1), reported in points (x100). The owner's targets are the beat grid
# and the chords per beat (80-90%), so those weigh most; the note-for-note
# parts are the stretch goal. A metric the key cannot score on a song (no
# melody in the key) is left out and the weights renormalised.
WEIGHTS = {
    "beats": 3.0,       # beat F1 (+-70 ms); see songs.json beatLevels
    "chords": 3.0,      # mean of chord root and root+maj/min accuracy, per 50 ms over the scored time
    "downbeats": 1.5,   # downbeat F1 (+-70 ms)
    "melody": 1.0,      # melody part onset F1 (50 ms, exact pitch)
    "bass": 1.0,        # bass part onset F1 (50 ms, exact pitch)
    "notes": 0.5,       # all notes onset F1 (50 ms, exact pitch)
}
# Metrics a guardrail watches, per dev song (points it may lose).
HEADLINE = ["beats", "downbeats", "chordRoot", "chordMajMin", "melody", "bass", "notes50"]
MAX_DROP = 2.0          # points a dev song may lose on any headline metric
MIN_GAIN = 0.25         # points the dev mean objective must gain
HOLDOUT_WARN = 1.0      # points of holdout mean objective lost that earn a warning
RUNTIME_WARN = 1.25     # music pipeline run time growth that earns a warning
PIPELINES = ["music", "quick-music"]
# Metrics that depend on the key's pitches (taken from the best pitch alternate).
PITCH_METRICS = ["chordRoot", "chordMajMin", "chordRootAll", "chordCoverage", "melody", "melodyChroma", "melody100",
                 "bass", "bassChroma", "chordsPart", "counter", "notes50", "notes100", "notesChroma50", "P50", "R50",
                 "partAcc", "alignShiftMs"]


def load_songs():
    with open(SONGS_JSON) as f:
        return json.load(f)["songs"]


def songs_dir(args):
    d = args.songs_dir or os.environ.get("BITMIDI_SONGS") or os.path.join(REPO, "bench", "songs", "bitmidi")
    if not os.path.isdir(d):
        sys.exit(f"no songs folder at {d} (pass --songs-dir or set BITMIDI_SONGS)")
    return d


def pick(songs, only):
    if not only:
        return songs
    want = [s.strip() for s in only.split(",") if s.strip()]
    known = {s["slug"] for s in songs}
    for w in want:
        if w not in known:
            sys.exit(f"unknown song {w} (known: {', '.join(sorted(known))})")
    return [s for s in songs if s["slug"] in want]


def alt_name(key):
    return "alt-" + os.path.splitext(os.path.basename(key))[0]


# MARK: - run

def cmd_run(args, extra):
    sd = songs_dir(args)
    rb = args.realbench or os.path.join(HERE, "..", ".build", "realbench")
    if not os.access(rb, os.X_OK):
        sys.exit(f"no realbench binary at {rb} (run Tools/RealBench/build.sh)")
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    for song in pick(load_songs(), args.songs):
        folder = os.path.join(sd, song["slug"])
        out = os.path.join(folder, "results", args.tag)
        os.makedirs(out, exist_ok=True)
        cmd = [rb, os.path.join(folder, "audio.wav"), os.path.join(folder, song["truth"]), "--out", out,
               "--pipelines", args.pipelines] + extra
        started = time.time()
        with open(os.path.join(out, "run.log"), "w") as log:
            code = subprocess.call(cmd, stdout=log, stderr=subprocess.STDOUT)
        print(f"{song['slug']:26s} exit {code}  {time.time() - started:5.1f} s  -> {out}", flush=True)
        if code != 0:
            sys.exit(f"realbench failed on {song['slug']}; see {out}/run.log")
        for key in song.get("pitchAlternates", []):
            alt = os.path.join(out, alt_name(key))
            code = subprocess.call([rb, "score", out, os.path.join(folder, key), "--out", alt],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
            if code != 0:
                sys.exit(f"realbench score failed on {song['slug']} {key}")


# MARK: - collect

def get(d, *path):
    for p in path:
        if not isinstance(d, dict) or p not in d:
            return None
        d = d[p]
    return d


def metrics_from(score, diag):
    """The scoreboard's metrics from one pipeline's score.json and diagnostics.json."""
    m = {
        "beats": get(score, "beats", "beats", "f1"),
        "downbeats": get(score, "beats", "downbeats", "f1"),
        "predBPM": get(score, "beats", "predBPM"),
        "truthBPM": get(score, "beats", "truthBPM"),
        "predMeter": get(score, "beats", "predBeatsPerBar"),
        "truthMeter": get(score, "beats", "truthBeatsPerBar"),
        "beatsDouble": get(diag, "beats", "beatF1vsMetricalVariants", "truthAtDoubleTempo"),
        "beatsHalf": max([x for x in [get(diag, "beats", "beatF1vsMetricalVariants", "truthAtHalfTempoEven"),
                                      get(diag, "beats", "beatF1vsMetricalVariants", "truthAtHalfTempoOdd")]
                          if x is not None], default=None),
        "chordRoot": get(score, "chords", "root"),
        "chordMajMin": get(score, "chords", "majmin"),
        "chordRootAll": get(score, "chords", "rootAllChords"),
        "chordCoverage": get(score, "chords", "predChordCoverage"),
        "melody": get(score, "parts", "roles", "melody", "onset50", "f1"),
        "melodyChroma": get(score, "parts", "roles", "melody", "onset50OctaveFolded", "f1"),
        "melody100": get(score, "parts", "roles", "melody", "onset100", "f1"),
        "bass": get(score, "parts", "roles", "bass", "onset50", "f1"),
        "bassChroma": get(score, "parts", "roles", "bass", "onset50OctaveFolded", "f1"),
        "chordsPart": get(score, "parts", "roles", "chords", "onset50", "f1"),
        "counter": get(score, "parts", "roles", "countermelody", "onset50", "f1"),
        "notes50": get(score, "notes", "onset50", "f1"),
        "notes100": get(score, "notes", "onset100", "f1"),
        "notesChroma50": get(score, "notes", "onset50OctaveFolded", "f1"),
        "P50": get(score, "notes", "onset50", "precision"),
        "R50": get(score, "notes", "onset50", "recall"),
        "partAcc": get(score, "parts", "partAccuracy", "accuracy"),
        "alignShiftMs": get(diag, "alignmentScan", "bestShiftMs"),
        "scoredSeconds": get(score, "window", "scoredSeconds"),
        "runSeconds": score.get("runSeconds"),
    }
    shifts = get(diag, "beats", "downbeatF1byBarShift") or {}
    if shifts:
        best = max(shifts, key=lambda k: (shifts[k], -int(k)))
        m["downbeatsBestShift"] = shifts[best]
        m["downbeatsShift"] = int(best)
    else:
        m["downbeatsBestShift"] = m["downbeatsShift"] = None
    # A role the key has but the pipeline does not split (unsplit pipeline) reads as missing.
    for role, k in [("melody", "melody"), ("bass", "bass"), ("chords", "chordsPart"), ("countermelody", "counter")]:
        if get(score, "parts", "roles", role, "onset50") is None:
            m[k] = None
            if role == "melody":
                m["melodyChroma"] = m["melody100"] = None
            if role == "bass":
                m["bassChroma"] = None
    info = score.get("info") or {}
    for k in ["engine", "verdict", "percussionCue", "percussiveShare", "tuningCents"]:
        if k in info:
            m[k] = info[k]
    return m


def objective(m, song):
    """One number per song (points), or None when nothing is scored."""
    beats = m.get("beats")
    levels = song.get("beatLevels", ["asIs"])
    if beats is not None:
        options = [beats]
        if "double" in levels and m.get("beatsDouble") is not None:
            options.append(m["beatsDouble"])
        if "half" in levels and m.get("beatsHalf") is not None:
            options.append(m["beatsHalf"])
        beats = max(options)
    chords = None
    if m.get("chordRoot") is not None and m.get("chordMajMin") is not None:
        chords = (m["chordRoot"] + m["chordMajMin"]) / 2
    parts = {"beats": beats, "chords": chords, "downbeats": m.get("downbeats"), "melody": m.get("melody"),
             "bass": m.get("bass"), "notes": m.get("notes50")}
    total = sum(WEIGHTS[k] * v for k, v in parts.items() if v is not None)
    weight = sum(WEIGHTS[k] for k, v in parts.items() if v is not None)
    return None if weight == 0 else 100 * total / weight


def read_run(run_dir, pipeline):
    s = os.path.join(run_dir, pipeline, "score.json")
    d = os.path.join(run_dir, pipeline, "diagnostics.json")
    if not os.path.exists(s):
        return None
    with open(s) as f:
        score = json.load(f)
    diag = {}
    if os.path.exists(d):
        with open(d) as f:
            diag = json.load(f)
    return metrics_from(score, diag)


def collect(args):
    sd = songs_dir(args)
    board = {"format": "bitmidi-scoreboard-1", "tag": args.tag,
             "date": time.strftime("%Y-%m-%d %H:%M"), "note": args.note or "",
             "weights": WEIGHTS, "guardrails": {"maxDropPoints": MAX_DROP, "minGainPoints": MIN_GAIN,
                                                "headline": HEADLINE},
             "songs": {}}
    for song in load_songs():
        run_dir = os.path.join(sd, song["slug"], "results", args.tag)
        entry = {"title": song["title"], "split": song["split"], "style": song["style"], "pipelines": {}}
        if song.get("beatLevels", ["asIs"]) != ["asIs"]:
            entry["beatLevels"] = song["beatLevels"]
        summary = os.path.join(run_dir, "summary.json")
        if os.path.exists(summary):
            with open(summary) as f:
                sj = json.load(f)
            entry["command"] = " ".join(os.path.basename(a) if os.path.isabs(a) else a
                                        for a in sj.get("command", "").split())
            entry["settings"] = sj.get("settings")
        for p in PIPELINES:
            m = read_run(run_dir, p)
            if m is None:
                continue
            # Pitch alternates: each pitch metric takes the best of the keys.
            used = {}
            for key in song.get("pitchAlternates", []):
                alt = read_run(os.path.join(run_dir, alt_name(key)), p)
                if alt is None:
                    continue
                for k in PITCH_METRICS:
                    if k in ("alignShiftMs", "chordCoverage"):
                        continue
                    a, b = alt.get(k), m.get(k)
                    if a is not None and (b is None or a > b):
                        m[k] = a
                        used[k] = key
            if used:
                m["pitchKeyUsed"] = used
            m["objective"] = objective(m, song)
            entry["pipelines"][p] = m
        if entry["pipelines"]:
            board["songs"][song["slug"]] = entry
    for p in PIPELINES:
        for split in ["dev", "holdout", "all"]:
            vals = [e["pipelines"][p]["objective"] for e in board["songs"].values()
                    if p in e["pipelines"] and e["pipelines"][p]["objective"] is not None
                    and (split == "all" or e["split"] == split)]
            board.setdefault("means", {}).setdefault(p, {})[split] = (sum(vals) / len(vals)) if vals else None
        for k in HEADLINE + ["chordRootAll", "melodyChroma", "melody100", "notes100"]:
            vals = [e["pipelines"][p][k] for e in board["songs"].values()
                    if p in e["pipelines"] and e["pipelines"][p].get(k) is not None]
            board.setdefault("metricMeans", {}).setdefault(p, {})[k] = (sum(vals) / len(vals)) if vals else None
    return board


def f3(x):
    return "-" if x is None else f"{x:.3f}"


def f1p(x):
    return "-" if x is None else f"{x:.1f}"


def markdown(board):
    out = []
    out.append(f"# Song mode scoreboard: {board['tag']}")
    out.append("")
    note = f" {board['note']}." if board.get("note") else ""
    out.append(f"{board['date']}.{note} Real recordings scored against fan-MIDI keys (`Tools/RealBench/bitmidi`). "
               "Scores are 0-1 except the objective (points, 0-100). Beats and downbeats: F-measure at +-70 ms. "
               "Chords: share of the scored time with the right root, and with the right root and major/minor. "
               "Parts and notes: onset F1 at 50 ms, exact pitch (chroma = pitch class only). "
               "Melody 100 ms: the same at +-100 ms, reported only (fan-MIDI vocal rhythm is loose; the "
               "objective keeps 50 ms). Fan-MIDI notes are approximate, so note F1 is a rough guide.")
    out.append("")
    w = board["weights"]
    out.append("Objective = weighted mean of beats x{beats:g}, chords (mean of root and maj/min) x{chords:g}, "
               "downbeats x{downbeats:g}, melody x{melody:g}, bass x{bass:g}, all notes x{notes:g}; "
               "metrics a key cannot score are left out.".format(**w))
    for p in PIPELINES:
        rows = [(slug, e) for slug, e in board["songs"].items() if p in e["pipelines"]]
        if not rows:
            continue
        title = "music (Song mode refine pass, what the app shows after a take)" if p == "music" \
            else "quick-music (live preview)"
        out.append("")
        out.append(f"## {title}")
        out.append("")
        out.append("| song | split | objective | beats | downbeats | chord root | chord maj/min | melody | melody 100 ms "
                   "| melody chroma | bass | chords part | notes 50 ms | notes 100 ms | tempo app / key | meter app / key |")
        out.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for slug, e in rows:
            m = e["pipelines"][p]
            star = "*" if m.get("pitchKeyUsed") else ""
            beats = f3(m["beats"])
            if "double" in e.get("beatLevels", []) and m.get("beatsDouble") is not None:
                beats += f" (2x {f3(m['beatsDouble'])})"
            if "half" in e.get("beatLevels", []) and m.get("beatsHalf") is not None:
                beats += f" (0.5x {f3(m['beatsHalf'])})"
            out.append(f"| {slug}{star} | {e['split']} | {f1p(m['objective'])} | {beats} | {f3(m['downbeats'])} "
                       f"| {f3(m['chordRoot'])} | {f3(m['chordMajMin'])} | {f3(m['melody'])} | {f3(m.get('melody100'))} "
                       f"| {f3(m['melodyChroma'])} "
                       f"| {f3(m['bass'])} | {f3(m['chordsPart'])} | {f3(m['notes50'])} | {f3(m['notes100'])} "
                       f"| {f1p(m['predBPM'])} / {f1p(m['truthBPM'])} | {m['predMeter'] or '-'} / {m['truthMeter'] or '-'} |")
        mm = board["metricMeans"][p]
        means = board["means"][p]
        out.append(f"| **mean** | dev {f1p(means['dev'])}, holdout {f1p(means['holdout'])} | {f1p(means['all'])} "
                   f"| {f3(mm['beats'])} | {f3(mm['downbeats'])} | {f3(mm['chordRoot'])} | {f3(mm['chordMajMin'])} "
                   f"| {f3(mm['melody'])} | {f3(mm.get('melody100'))} | {f3(mm['melodyChroma'])} | {f3(mm['bass'])} | - "
                   f"| {f3(mm['notes50'])} "
                   f"| {f3(mm['notes100'])} | | |")
        if any(e["pipelines"][p].get("pitchKeyUsed") for _, e in rows):
            out.append("")
            out.append("\\* pitch scores from the better of the song's keys (tuning between two semitones, see songs.json).")
        if any(e.get("beatLevels") for _, e in rows):
            out.append("")
            out.append("(2x ...): beat F1 against the key at double tempo, which the objective also accepts on that song.")
    # Diagnostics for the refine pass.
    rows = [(slug, e) for slug, e in board["songs"].items() if "music" in e["pipelines"]]
    if rows:
        out.append("")
        out.append("## music: diagnostics")
        out.append("")
        out.append("| song | beats vs key at 2x / 0.5x | downbeats at best bar shift (shift) | chord root, all chords "
                   "| chord coverage | counter-melody | part accuracy | notes P / R (50 ms) | onset shift ms | engine | drum cue |")
        out.append("|---|---|---|---|---|---|---|---|---|---|---|")
        for slug, e in rows:
            m = e["pipelines"]["music"]
            out.append(f"| {slug} | {f3(m['beatsDouble'])} / {f3(m['beatsHalf'])} "
                       f"| {f3(m['downbeatsBestShift'])} ({m['downbeatsShift'] if m['downbeatsShift'] is not None else '-'}) "
                       f"| {f3(m['chordRootAll'])} | {f3(m['chordCoverage'])} | {f3(m['counter'])} | {f3(m['partAcc'])} "
                       f"| {f3(m['P50'])} / {f3(m['R50'])} | {m['alignShiftMs'] if m['alignShiftMs'] is not None else '-'} "
                       f"| {m.get('engine', '-')} | {m.get('percussionCue', '-')} |")
    out.append("")
    return "\n".join(out)


def cmd_collect(args):
    board = collect(args)
    if not board["songs"]:
        sys.exit(f"no results tagged {args.tag}")
    def rounded(x):
        if isinstance(x, float):
            return round(x, 4)
        if isinstance(x, dict):
            return {k: rounded(v) for k, v in x.items()}
        if isinstance(x, list):
            return [rounded(v) for v in x]
        return x
    text = json.dumps(rounded(board), indent=1, sort_keys=True)
    if args.json:
        with open(args.json, "w") as f:
            f.write(text + "\n")
    md = markdown(board)
    if args.md:
        with open(args.md, "w") as f:
            f.write(md)
    print(md)


# MARK: - compare

def cmd_compare(args):
    with open(args.base) as f:
        base = json.load(f)
    with open(args.new) as f:
        new = json.load(f)
    lines = [f"# {new['tag']} against {base['tag']}", ""]
    failures, warnings = [], []
    lines.append("| song | split | objective | " + " | ".join(HEADLINE) + " |")
    lines.append("|---|---|---|" + "---|" * len(HEADLINE))
    dev_b, dev_n, hold_b, hold_n = [], [], [], []
    for slug, e in new["songs"].items():
        b = get(base, "songs", slug, "pipelines", "music")
        n = get(e, "pipelines", "music")
        if b is None or n is None:
            continue
        split = e["split"]
        cells = []
        ob, on = b.get("objective"), n.get("objective")
        if ob is not None and on is not None:
            (dev_b if split == "dev" else hold_b).append(ob)
            (dev_n if split == "dev" else hold_n).append(on)
            cells.append(f"{on:.1f} ({on - ob:+.1f})")
            if split == "dev" and on - ob < -MAX_DROP:
                failures.append(f"{slug}: objective {on - ob:+.1f} points")
        else:
            cells.append("-")
        for k in HEADLINE:
            vb, vn = b.get(k), n.get(k)
            if vb is None or vn is None:
                cells.append("-")
                continue
            d = 100 * (vn - vb)
            cells.append(f"{vn:.3f} ({d:+.1f})" if abs(d) >= 0.05 else f"{vn:.3f}")
            if split == "dev" and d < -MAX_DROP:
                failures.append(f"{slug}: {k} {d:+.1f} points")
        rb, rn = b.get("runSeconds"), n.get("runSeconds")
        if rb and rn and rn > RUNTIME_WARN * rb:
            warnings.append(f"{slug}: music run time {rb:.1f} -> {rn:.1f} s")
        lines.append(f"| {slug} | {split} | " + " | ".join(cells) + " |")
        # The live preview: a drop is worth a warning, not a veto.
        qb = get(base, "songs", slug, "pipelines", "quick-music")
        qn = get(e, "pipelines", "quick-music")
        if qb and qn:
            for k in HEADLINE:
                if qb.get(k) is not None and qn.get(k) is not None and 100 * (qn[k] - qb[k]) < -MAX_DROP:
                    warnings.append(f"{slug}: quick-music {k} {100 * (qn[k] - qb[k]):+.1f} points")

    def mean(x):
        return sum(x) / len(x) if x else float("nan")
    gain = mean(dev_n) - mean(dev_b)
    hold = mean(hold_n) - mean(hold_b)
    lines.append("")
    lines.append(f"dev mean objective {mean(dev_b):.2f} -> {mean(dev_n):.2f} ({gain:+.2f}); "
                 f"holdout {mean(hold_b):.2f} -> {mean(hold_n):.2f} ({hold:+.2f}, reported only)")
    if not (gain >= MIN_GAIN):
        failures.append(f"dev mean objective gained {gain:+.2f} points (needs +{MIN_GAIN:.2f})")
    if not math.isnan(hold) and hold < -HOLDOUT_WARN:
        warnings.append(f"holdout mean objective {hold:+.2f} points")
    lines.append("")
    lines.append("ACCEPT" if not failures else "REJECT")
    for f_ in failures:
        lines.append(f"- guardrail: {f_}")
    for w_ in warnings:
        lines.append(f"- warning: {w_}")
    text = "\n".join(lines) + "\n"
    if args.md:
        with open(args.md, "w") as f:
            f.write(text)
    print(text)
    sys.exit(0 if not failures else 1)


def main():
    argv = sys.argv[1:]
    extra = []
    if "--" in argv:
        i = argv.index("--")
        argv, extra = argv[:i], argv[i + 1:]
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="transcribe and score every song (one at a time)")
    r.add_argument("--tag", required=True)
    r.add_argument("--songs", help="comma-separated slugs (default: all)")
    r.add_argument("--pipelines", default="music,quick-music")
    r.add_argument("--songs-dir")
    r.add_argument("--realbench")
    c = sub.add_parser("collect", help="gather a tag's metrics into JSON and Markdown")
    c.add_argument("--tag", required=True)
    c.add_argument("--json")
    c.add_argument("--md")
    c.add_argument("--note", help="free text kept in the JSON (the commit and build the run used)")
    c.add_argument("--songs-dir")
    m = sub.add_parser("compare", help="check a scoreboard against a base one with the guardrails")
    m.add_argument("base")
    m.add_argument("new")
    m.add_argument("--md")
    args = ap.parse_args(argv)
    if args.cmd == "run":
        cmd_run(args, extra)
    elif args.cmd == "collect":
        cmd_collect(args)
    else:
        cmd_compare(args)


if __name__ == "__main__":
    main()
