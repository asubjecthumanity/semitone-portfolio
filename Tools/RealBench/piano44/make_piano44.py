#!/usr/bin/env python3
"""A 4/4 piano check with known bar lines, including two 2/4 bars.

Writes a realbench-truth-1 key for a short solo-piano piece (92 BPM, C major,
32 bars, about 80 s): an intro, a verse, a 2/4 bar, a chorus, the verse again
with some chords changing on beat 3, a second 2/4 bar and an ending. The left
hand plays broken chords, then "oom-pah" (bass on 1 and 3, chord on 2 and 4),
then broken chords again; the right hand plays a melody with pickups into the
next bar. Onsets are humanized by up to +-10 ms and velocities vary, from a
fixed seed, so the key is the same on every run. Render it with
`als2truth/render_gm.swift` (GM program 0, Acoustic Grand Piano) and score it
with realbench: see piano44.sh. Standard library only.

    python3 make_piano44.py -o truth.json
"""
import argparse
import json

BPM = 92.0
BEAT = 60.0 / BPM
START = 1.0          # seconds of silence before bar 1

ROOTS = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
QUALITY = {"maj": (0, 4, 7), "min": (0, 3, 7)}

# (beats in the bar, [(chord, beats)]); a chord is "C", "Am", ...
INTRO = [(4, [("C", 4)]), (4, [("G", 4)])]
VERSE = [(4, [("C", 4)]), (4, [("G", 4)]), (4, [("Am", 4)]), (4, [("F", 4)]),
         (4, [("C", 4)]), (4, [("G", 4)]), (4, [("F", 2), ("C", 2)]), (4, [("G", 4)])]
CHORUS = [(4, [("Am", 4)]), (4, [("F", 4)]), (4, [("C", 4)]), (4, [("G", 4)]),
          (4, [("Am", 4)]), (4, [("F", 4)]), (4, [("Dm", 2), ("G", 2)]), (4, [("C", 4)])]
VERSE2 = [(4, [("C", 4)]), (4, [("G", 4)]), (4, [("Am", 2), ("Em", 2)]), (4, [("F", 4)]),
          (4, [("Dm", 4)]), (4, [("G", 4)]), (4, [("C", 2), ("Am", 2)]), (4, [("Dm", 2), ("G", 2)])]
ENDING = [(4, [("F", 4)]), (4, [("G", 4)]), (4, [("C", 4)]), (4, [("C", 4)])]
FORM = ([(b, "broken") for b in INTRO] + [(b, "broken") for b in VERSE] + [((2, [("G", 2)]), "oompah")]
        + [(b, "oompah") for b in CHORUS] + [(b, "broken") for b in VERSE2] + [((2, [("F", 2)]), "oompah")]
        + [(b, "block") for b in ENDING])


class LCG:
    """A small fixed generator, so the key does not depend on Python's random module."""
    def __init__(self, seed):
        self.state = seed & 0xFFFFFFFF

    def unit(self):
        self.state = (1664525 * self.state + 1013904223) & 0xFFFFFFFF
        return self.state / 2 ** 32

    def uniform(self, a, b):
        return a + (b - a) * self.unit()

    def choice(self, items):
        return items[int(self.unit() * len(items)) % len(items)]


def chord_tones(name):
    root = ROOTS[name[0]]
    quality = "min" if name.endswith("m") else "maj"
    return root, quality, [(root + i) % 12 for i in QUALITY[quality]]


def nearest(pc, around):
    """The pitch of pitch class `pc` nearest to MIDI `around`."""
    best = None
    for p in range(around - 6, around + 7):
        if p % 12 == pc and (best is None or abs(p - around) < abs(best - around)):
            best = p
    return best


def build():
    rng = LCG(20261014)
    notes, beats, downbeats, chords = [], [], [], []

    def jitter():
        return rng.uniform(-0.010, 0.010)

    def add(on_beat, dur_beats, pitch, vel, part):
        on = START + on_beat * BEAT + jitter()
        notes.append({"on": round(on, 4), "off": round(on + max(dur_beats * BEAT - 0.03, 0.08), 4),
                      "pitch": pitch, "velocity": int(max(30, min(115, vel))), "part": part,
                      "instrument": "Piano"})

    scale = [0, 2, 4, 5, 7, 9, 11]
    beat = 0.0
    melody_pitch = 72
    for bar_index, ((length, spans), style) in enumerate(FORM):
        bar_start = beat
        downbeats.append(round(START + bar_start * BEAT, 4))
        for k in range(length):
            beats.append(round(START + (bar_start + k) * BEAT, 4))
        # Chords and the left hand.
        t = bar_start
        for name, span in spans:
            root, quality, tones = chord_tones(name)
            chords.append({"start": round(START + t * BEAT, 4), "end": round(START + (t + span) * BEAT, 4),
                           "label": f"{'CDEFGAB'[[0, 2, 4, 5, 7, 9, 11].index(root)]}:{quality}"})
            bass = nearest(root, 40)
            third = nearest(tones[1], bass + 16)
            fifth = nearest(tones[2], bass + 7)
            if style == "broken":
                pattern = [bass, fifth, bass + 12, third]
                for e in range(int(span * 2)):
                    accent = 8 if e == 0 and t == bar_start else 0
                    add(t + e / 2, 0.5 if e % 4 else 1.0, pattern[e % 4], rng.uniform(62, 74) + accent, "bass" if e % 4 == 0 else "chords")
            elif style == "oompah":
                for b in range(int(span)):
                    if b % 2 == 0:
                        add(t + b, 0.9, bass if b == 0 else nearest(tones[2], bass - 5 if bass > 40 else bass + 7),
                            rng.uniform(72, 82) + (6 if t + b == bar_start else 0), "bass")
                    else:
                        for pc in tones:
                            add(t + b, 0.45, nearest(pc, 57), rng.uniform(52, 62), "chords")
            else:  # block: a held chord over the bass
                add(t, span - 0.1, bass, rng.uniform(72, 80), "bass")
                for pc in tones:
                    add(t + 0.02, span - 0.1, nearest(pc, 57), rng.uniform(56, 64), "chords")
            t += span
        # The right hand's melody: chord tones on beats 1 and 3, steps between, sometimes a pickup.
        rhythms = [[1, 1, 1, 1], [1.5, 0.5, 1, 1], [2, 1, 1], [1, 1, 2], [0.5, 0.5, 1, 1, 1], [1, 1, 1, 0.5, 0.5]]
        if length == 2:
            rhythms = [[1, 1], [2]]
        rhythm = rng.choice(rhythms)
        if style == "block" and bar_index == len(FORM) - 1:
            rhythm = [4]
        pos = 0.0
        for d in rhythm:
            at = bar_start + pos
            # The chord sounding at this point.
            acc = bar_start
            current = spans[0][0]
            for name, span in spans:
                if at >= acc:
                    current = name
                acc += span
            _, _, tones = chord_tones(current)
            strong = abs(pos - round(pos)) < 1e-9 and int(round(pos)) % 2 == 0
            if strong:
                melody_pitch = nearest(rng.choice(tones), melody_pitch)
            else:
                step = rng.choice([-2, -1, 1, 2])
                idx = min(range(len(scale)), key=lambda i: abs(scale[i] - melody_pitch % 12))
                melody_pitch = 12 * (melody_pitch // 12) + scale[(idx + step) % 7] + (12 if idx + step >= 7 else -12 if idx + step < 0 else 0)
            melody_pitch = min(max(melody_pitch, 64), 81)
            add(at, d, melody_pitch, rng.uniform(78, 92) + (6 if pos == 0 else 0), "melody")
            pos += d
        beat += length
    end = START + beat * BEAT
    return {
        "format": "realbench-truth-1",
        "name": "piano44",
        "source": "Tools/RealBench/piano44/make_piano44.py: a 4/4 solo piano piece at 92 BPM with two 2/4 bars "
                  "(bars 11 and 28); onsets humanized +-10 ms",
        "notesComplete": True,
        "offsetsReliable": True,
        "notes": sorted(notes, key=lambda n: (n["on"], n["pitch"])),
        "beats": beats,
        "downbeats": downbeats,
        "beatsPerBar": 4,
        "chords": chords,
        "ignore": [[end, end + 10]],
    }


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()
    key = build()
    with open(a.out, "w") as f:
        json.dump(key, f, indent=1)
    print(f"{a.out}: {len(key['notes'])} notes, {len(key['beats'])} beats, {len(key['downbeats'])} bars, "
          f"{key['beats'][-1] + BEAT:.1f} s")
