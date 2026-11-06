# bitmidi: fan-made MIDI as an answer key for a real recording

`bitmidi` turns a fan-made MIDI file (for example from bitmidi.com) into a RealBench key
(`realbench-truth-1`, see [../README.md](../README.md)) for the real recording of the same song. Song
mode can then be scored on real music: the beat grid and downbeats, chords per beat, and (as a
stretch) the melody, bass and other parts note for note.

A fan MIDI is an arrangement, not a transcription of the record. Its tempo is steady where the band
drifts, sections may be missing or repeated, the key may be different, instruments are simplified,
and the vocal line is often written an octave off. `bitmidi` lines the MIDI up with the recording,
says how much of the song it trusts, and builds the key only from the parts it trusts.

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Tools/RealBench/bitmidi/build.sh   # -> .build/bitmidi
B=Tools/RealBench/bitmidi/.build/bitmidi

$B song SONGDIR                       # whole path: SONGDIR/audio.wav + SONGDIR/midi-candidates/*.mid -> SONGDIR/key/
$B song SONGDIR --midi midi-candidates/105027.mid   # use this candidate instead of the best-ranked one
$B song SONGDIR --fresh-roles         # rewrite SONGDIR/roles.json from fresh suggestions
$B inspect FILE.mid                   # voices, programs, ranges, lyrics, suggested roles (no audio)
$B pick AUDIO A.mid B.mid C.mid       # rank candidates by how much of the recording they align with confidently
$B align AUDIO FILE.mid --out DIR     # alignment only: align.json, report.txt, aligned.mid
$B truth AUDIO FILE.mid --out DIR [--roles roles.json]   # alignment + key, outside the song-folder layout
$B compare KEY1.json KEY2.json        # agreement of two keys of the same recording (beats, chords, notes per part)
$B validate AUDIO --midi EXACT.mid ...   # synthetic test with a known answer (see "Validation")
Tools/RealBench/bitmidi/validate.sh   # the whole validation suite (needs bench/)
```

Alignment options (all commands that align): `--transpose N` fixes the transposition instead of
searching all 12, `--no-refine` skips the onset refinement, `--one-pass` skips the tempo-normalised
second pass, and `--onset-weight`, `--offdiag`, `--band`, `--z0`, `--gap`, `--gap-open`,
`--slope-penalty`, `--coarse-window` change the alignment's weights (defaults below). Diagnostics:
`bitmidi octave AUDIO FILE.mid` (octave check for every voice), `bitmidi lagprofile AUDIO FILE.mid`
(recording onset strength around the warped MIDI onsets, per 30 s), `bitmidi peakcheck AUDIO EXACT.mid`
(bias of the onset detector against an exact MIDI), `bitmidi chordcheck KEY.json` (the chord labeller
against a key's own chords). It is all Swift (vDSP for the signal processing) and reads MIDI with
RealBench's `readMidi` (AudioToolbox), so a downloaded file is only ever parsed, never run.

A song takes about a second per candidate on an M-series Mac (features 0.5 s, alignment 0.5 s).

## Song folder

```
bench/songs/bitmidi/                     git-ignored; the recordings are the owner's, for local tests only
  DOWNLOADS.md                           one line per downloaded file: filename, URL, size in bytes
  <slug>/                                slug = the bitmidi page name without "-mid", e.g. toto-africa
    audio.wav                            the recording: afconvert -f WAVE -d LEI16@44100 "Song.mp3" audio.wav
    midi-candidates/<id>.mid             up to 3 versions, from https://bitmidi.com/uploads/<id>.mid
    roles.json                           written on the first run; edit it, then run again
    key/truth.json                       the RealBench key
    key/report.txt                       read this: alignment, sections, voices, warnings, octave check
    key/align.json                       time map, transposition, sections with their confidence numbers
    key/aligned.mid                      the MIDI warped onto the recording (60 BPM: one beat = one second)
    key/roles.suggested.json             the suggestions for the MIDI used, for reference
    key/pick.txt                         candidate ranking (when roles.json does not name a MIDI)
```

`aligned.mid` plays the MIDI (drums included, transposed) on the recording's timeline: open it in
GarageBand or Logic next to `audio.wav` to hear whether the alignment and the octaves are right.

## How it works

### 1. Features (20 ms frames, 22050 Hz mono)

- **Chroma**: STFT 4096 (Hann), a triangular filterbank onto semitones C1-B7 (at least two FFT bins
  wide, tuned to the recording's own tuning, which is estimated from spectral peaks), log
  compression, folded into 12 pitch classes from A1 up, unit length. Quiet frames get the flat vector.
- **Onsets** ("DLNCO", Ewert, Muller and Grosche 2009): the rise of log pitch energy (STFT 2048) kept
  at its local peaks and folded into 12 pitch classes; a broadband spectral-flux channel (STFT 1024);
  and three drum-band channels (flux at 40-150 Hz, 1-4 kHz and 6-10 kHz for kick, snare and hi-hat).
  Each group is divided by its local maximum (+-1.5 s) and given a 200 ms decaying tail.
- **The MIDI side** gets the same features from its notes: sounding notes with six harmonics for the
  chroma, onset impulses for the pitch-class channels, every note for the rhythm channel, and GM kick
  (35, 36), snare (37-40) and hi-hat/ride (42, 44, 46, 51, 53, 59) hits for the drum bands. A drum band
  is used only when the MIDI has at least 20 such hits. Drum notes never feed the chroma.

### 2. Alignment

1. **Coarse** (0.2 s frames, chroma smoothed over 1 s): for each of the 12 transpositions, a local
   alignment over the similarity matrix (the path may start and end anywhere). A cell scores its
   similarity in standard deviations above the mean of all sounding cells of all 12 transpositions,
   minus 0.5; silent frames on either side score as neutral. Steps (1,1), (2,1) and (1,2) follow the
   tempo; gap steps (one side advances alone) stand for material only one side has and cost 8 to open
   and 0.5 per frame (affine gaps, so a missing chorus is one gap). The best transposition wins.
2. **Second pass**: the MIDI is stretched by the median tempo ratio found in the first pass and aligned
   again with the transposition fixed and a cost of 0.5 for every (2,1) or (1,2) step. The path then
   keeps a steady slope unless the music says otherwise, so in loop-based songs (where many bars look
   alike) it cannot slip a bar for free.
3. **Segments**: the coarse path is cut at gap runs of 0.6 s or more. Gaps in the recording become
   "recording only" spans (ignored in the key), gaps in the MIDI "MIDI only" spans (its notes are
   dropped). Segments under 4 s are dropped.
4. **Fine** (20 ms): per segment, DTW in a band of +-0.6 s around the coarse path, cost = (1 - chroma
   cosine) + Euclidean distance of the onset features, steps (1,1) at twice the cost and (1,0), (0,1)
   with a 0.5 penalty (without it the path wanders inside held chords).
5. **Time map**: every 0.1 s of MIDI time, a weighted line fit of the path over +-0.4 s (frames with
   MIDI onsets weigh most) gives the recording time; the anchors are made monotone (isotonic
   regression). Then each anchor is nudged by up to +-60 ms to where the warped MIDI onsets best meet
   the recording's onset strength (median over +-0.5 s of anchors). The map is piecewise linear;
   outside the segments it is undefined.

### 3. Confidence per section (4 MIDI bars, or 8 s without bars)

| number | what it is | flagged when |
|---|---|---|
| `chroma`, `bg` | mean chroma cosine along the map, and the same MIDI frames against recording frames 4-11 s away | `chroma - bg < 0.04` |
| `contrast`, `lag` | recording onset strength at the warped MIDI onsets shifted by -250...+250 ms: `contrast` = 1 - (mean at +-40...100 ms) / (value at 0), `lag` = best shift | 6+ onsets and `lag` beyond +-30 ms (when 0 is under 90% of the best), or `contrast < 0.3` |
| `drums` | MIDI kick and snare hits on the recording's kick and snare bands, MIDI shifted by -1, 0, +1 beat; `=` when the section's kick/snare pattern repeats every beat (a kick on every beat and no snare, say), which a one-beat shift cannot change, so the check is skipped | 8+ hits and a one-beat shift fits 15% better |
| `jitter` | median relative deviation of the map's 1 s slopes from the section's slope | `> 0.10` (a real match keeps a steady tempo ratio; a forced one wobbles) |
| `keymargin` | chroma cosine along the map with the chosen transposition minus the best other one | `< 0.03` |
| `sounding` | share of the section's MIDI frames with a pitched note | `< 0.3` (drums-only or silent MIDI says nothing about notes or chords) |
| `hit50`, `ch50` | warped MIDI onsets within 50 ms of a recording onset peak, and the share of time within 50 ms of a peak (chance) | information only |
| `cbeat` | chroma similarity along the map with the MIDI shifted by -2...+2 beats: the best shift and how much better it is than none (`+0` when no shift is better) | information only: when the chords change once a bar and the voicings share notes, a one-beat slip moves the similarity by only a few percent |

The onset numbers alone cannot tell a right alignment from a wrong one, because the fine alignment
itself pulls the MIDI onsets onto the recording's onsets: aligning "Angie" to "Africa" gives an onset
contrast of 0.91. The tempo steadiness and the key margin catch that case (jitter 0.11-0.41 and key
margin -0.02-0.09 there, against 0.00-0.02 and 0.10-0.19 for the real Africa MIDI), and every one of
its sections is flagged.

### 4. The key

- **Notes**: every voice with a pitched role, warped (onset and offset through the map; an offset past
  the segment keeps the MIDI duration), transposed by the song transposition plus the voice's
  `addTranspose`. Notes that start in an ignored span or in a MIDI-only span are left out. Unisons
  (same pitch, onsets within 50 ms, in any voices) are merged into one note, the part kept by priority
  melody > bass > countermelody > chords, because a transcription hears one note and the scorer
  matches one to one. `notesComplete` and `offsetsReliable` are false: an arrangement's notes are
  approximate, so note F1 against a fan MIDI is a rough guide, not a precise score.
- **Beats and downbeats**: the MIDI's tempo map and time signatures (RealBench's `readMidi` grid:
  compound meters count dotted quarters), warped. `beatsPerBar` is the first meter. Meter changes in
  the MIDI are kept and listed in the report.
- **Chords**: one label per MIDI beat from the MIDI's own harmony, a port of `als2truth.py`'s
  `derive_chords`. Given the notes als2truth labelled from (`chordcheck --with-unreliable`), it gives
  the same labels 100% of the time on In The Rain and its GM render, and 84% on Patience, whose key
  merged unisons after labelling. It does not use the app's
  chord code, so the key stays independent. Chords-role notes count by how long they sound in the beat,
  countermelody notes at a third of that; the lowest bass note sounding through a quarter of the beat
  names the inversion and helps pick the root; templates maj, min, dim, aug, sus4, sus2, 7, maj7, min7,
  hdim7, dim7, minmaj7, maj6, min6, 5; a Viterbi pass charges 0.4 per change. Labels are Harte
  (`C#:min7`, `E:maj/5`, `N`), spelled for the estimated key; all of them read with `realbench
  parse-chord`. With no chords-role voice the labels come from every non-melody voice. With no bass
  voice (an arrangement without a bass part) the lowest chords-role note sounding through a quarter of
  the beat stands in for the bass, so an add9 or drone voicing (Db F Ab Eb) keeps its root instead of
  reading as `Ab:sus4`; the report says so.
- **Ignore**: everything outside the matched segments, recording-only gaps, flagged sections, and the
  spans in roles.json.
- An extra `bitmidi` object (ignored by RealBench) records the MIDI file, the transposition, the
  tuning, the trusted seconds, the estimated key, the key options and the tempo.

### 5. Roles

Every track and channel pair is a voice (`t<track>c<channel>`, channels 1-16). Suggestions, in order:
- `drums`: channel 10. Dropped from the key (RealBench no longer scores drums).
- `ignore`: percussion names on a pitched channel, GM programs 112-127 (percussive and sound effects),
  fewer than 8 notes.
- `bass`: "bass" in the name (not "bassoon"), GM programs 32-39, or a low (median below C3), mostly
  single-note line.
- `chords`: polyphonic (1.4+ notes sounding on average, or 20%+ of onsets in 3-note chords).
- `melody`: the most melody-like single line, scored on name (vocal, voice, vox, melody, lead, sing:
  +3; lead, solo, main: +2; harmony, backing, 2nd, bridge, intro, fill: -2), lyrics (5 x the share of
  the file's lyric events that fall on its notes; karaoke files carry them), GM program (choir, voice,
  synth voice: +1.5; brass to synth leads: +0.5), how much of the song it covers, register, and
  chordal onsets. A named vocal track or one carrying most lyrics competes even if it holds a few
  harmonies; if it is polyphonic it is suggested as `melody+countermelody` (top line melody, the rest
  countermelody).
- `countermelody`: every other single line.

Extra roles for a voice that mixes parts: `melody+chords` (top line melody, the rest chords),
`melody+countermelody`, `chords+bass` (lowest line bass, the rest chords). The top line is the
highest note struck together with or still sounding at each onset.

The report lists every voice: id, track name, GM program, notes, range, median pitch, polyphony,
share of chord onsets, seconds sounding, lyric share, role, suggestion and why.

### 6. Octave check

For each voice with a role, the report gives two readings of where its notes sound in the recording,
with the key's pitches shifted by -24...+24 semitones: the level of the recording's energy at that
pitch while the notes sound (above the frame's median), and its rise at the notes' onsets. When both
readings agree on a shift other than 0 the report says "sounds +N: check by ear"; when they disagree,
"unclear". Treat it as a hint. Other parts on the same pitch classes (a bass under a riff, a pad
doubling the tune) blur it, and for a bass "+12" is usually a false alarm because the second
harmonic is louder than the fundamental in most mixes. On the tests it got Slakh's known bass octave
error (-12) and most voices of the GM renders right, but also flagged a few correct voices.

## roles.json

Written by `song` on the first run from the suggestions, for the MIDI that was picked; edit and run
again. Only entries for the MIDI named in `midi` are applied (another candidate gets its own
suggestions; `--fresh-roles` rewrites the file).

```json
{
  "format": "bitmidi-roles-1",
  "midi": "midi-candidates/105034.mid",
  "transpose": "auto",
  "ignore": [[0, 12.5]],
  "barShift": 0,
  "tempoScale": 1,
  "beatsPerBar": null,
  "align": {"slope-penalty": 2, "band": 0.2, "offdiag": 2},
  "trust": [[110.2, 117.1]],
  "comment": "why you changed what you changed",
  "voices": [
    {"id": "t0c4", "name": "", "program": "Synth Voice", "notes": 387, "range": "B3-A5",
     "suggested": "melody", "why": "...", "role": "melody", "addTranspose": -12}
  ]
}
```

- `midi`: the candidate to use (relative to the song folder). Set it to stop `song` from ranking.
- `transpose`: `"auto"` or a whole number of semitones added to every pitched note (it also fixes the
  alignment's transposition). Pick the octave here (`-8` and `4` differ only by octave).
- `voices[].role`: melody, countermelody, chords, bass, ignore, drums, melody+chords,
  melody+countermelody, chords+bass. `addTranspose`: semitones on top for this voice (octave fixes).
  Voices are matched by `id`, then by name.
- `ignore`: extra recording spans `[start, end]` (seconds) to leave out of the key.
- `barShift`: move the bar lines by N beats (the MIDI's bar 1 is not the song's). `beatsPerBar`:
  replace the MIDI's meter with N beats per bar (bars run from the MIDI's first downbeat, plus
  `barShift`). Either one replaces the MIDI's meter changes with a constant meter.
- `tempoScale`: `0.5` keeps every other MIDI beat (the MIDI counts twice the song's beats), `2` adds a
  beat between MIDI beats. The report warns when the key's tempo is above 170 or below 55 BPM.
- `align`: alignment settings for this song, by their command-line names without `--` (`slope-penalty`,
  `band`, `offdiag`, `onset-weight`, `gap`, `gap-open`, `z0`, `coarse-window`, and `one-pass` or
  `no-refine` set to 1); options on the command line win. For a recording that keeps a steady tempo
  (most studio pop, played to a click) where the default alignment slips by a beat in repetitive
  passages, `{"slope-penalty": 2, "band": 0.2, "offdiag": 2}` keeps the map close to one straight
  line: the coarse path pays more for tempo steps, the fine path may only move 0.2 s (under half a
  beat at 70-140 BPM) from it, and it pays more for horizontal or vertical steps. Check the result
  against the default (`align` both ways and compare the time maps).
- `trust`: recording spans `[start, end]` whose flagged sections stay in the key (a section is kept
  when at least half of it lies in the spans). Use it only for flags shown to be false alarms by
  other evidence, and say what that evidence is in `comment`; the report lists the sections kept and
  the confident time with and without them. It never brings back time outside the matched segments,
  and `ignore` still wins.

## Validation

`validate` takes MIDI whose timing is exact for the recording (Slakh's per-stem MIDI for `angie`, or
an Ableton key's notes), warps it with a known tempo curve (MIDI time runs at R x (1 + A sin(2 pi t /
P)) of the recording's), transposes it, optionally cuts or repeats sections, jitters onsets, drops
drums or parts, aligns it back, and reports the onset error of every distinct MIDI onset (median, 90th
percentile, share within 50 and 100 ms), the beat error, whether the transposition and the
cut/repeated spans were found, and how the section flags matched the real errors (`--sections` lists
them). `validate.sh` runs the suite below (11 cases, 11 s in all). Results on 2026-10-13:

| case | transposition | onset error median / p90 | within 50 ms (all / trusted sections) | beat error median / p90 |
|---|---|---|---|---|
| angie, exact MIDI | found | 6.1 / 12.5 ms | 100% / 100% | 6.1 / 12.5 ms |
| angie, +3 st, 1.12x +-6% tempo | found | 6.0 / 12.4 ms | 99.7% / 99.7% | 6.3 / 13.2 ms |
| same + 30 ms random onset jitter | found | 10.1 / 23.0 ms | 99.4% / 99.4% | 10.8 / 23.3 ms |
| same, no drums, only piano+bass+flute | found | 6.6 / 17.7 ms | 96.8% / 97.1% | 6.5 / 16.6 ms |
| strong drift 0.85x +-10% (23 s period) | found | 5.5 / 13.0 ms | 99.9% / 99.9% | 5.5 / 12.9 ms |
| MIDI lacks 100-130 s | found | 6.1 / 14.6 ms | 96.9% / 99.6% | 6.1 / 14.9 ms |
| MIDI plays 60-80 s twice | found | 6.0 / 12.8 ms | 98.9% / 100% | 5.8 / 12.8 ms |
| all at once (-5 st, 0.9x, cut, repeat, jitter, 4 parts) | found | 8.9 / 22.8 ms | 95.4% / 100% | 9.2 / 26.5 ms |
| patience-gm (GM render of an Ableton set) | found | 6.9 / 27.4 ms | 92.5% / 92.5% | 7.1 / 29.5 ms |
| in-the-rain keyonly (real export, sparse key) | found | 6.0 / 36.5 ms | 91.1% / 96.3% | 7.9 / 125 ms |
| in-the-rain full (vocals and drums not in the key) | found | 36 / 1270 ms | 50.6% / 81.9% | 97 / 1173 ms |

The target was a median under about 30 ms; every case but the last is at 6-10 ms. The cut was found
as a 24.6 s recording-only gap at 97.0-121.6 s (the other 5 s were stretched over and are flagged).
The repeat was found as a 17 s MIDI-only gap; which of the two copies is used is arbitrary. In the
"all at once" case the 15 s cut was absorbed and flagged instead of found as a gap. "In The Rain full"
is the worst case: a sparse key (no vocals, no drums) against a mix led by vocals and drums, in a song
built of repeating bars. Half its notes are misplaced, mostly by whole beats; the flags catch 11 of 14
misaligned sections and leave 37 of 125 s trusted, where 82% of onsets are within 50 ms.

A wrong MIDI is rejected: Angie's piano part aligned to the Africa recording gets 0 s trusted (every
section flagged for tempo wobble or key margin).

### The real-song test: Toto, "Africa"

Recording: `Toto - Africa (Lyrics).mp3` (294.5 s). Candidates: bitmidi 105027 ("toto-africa.mid",
type 1, 30 tracks, constant 4/4) and 105034 ("TOTO.Africa K.mid", type 0 with lyrics and 2/4 bars).
`song` ranked 105034 first (253.9 s trusted of 294.5 s, every section of the matched span trusted,
transposition 0, tuning +1 cent, tempo ratio 1.015) and 105027 second (234 s). The lyrics put the
melody on "Synth Voice" (99% of lyric events on its notes); its octave check (energy level -12) and
the sung range say it is written an octave high, so roles.json sets `addTranspose: -12`. The intro
(drums only in the MIDI: 0-10.7 s) and the outro after the MIDI ends (264.6-294.5 s) are ignored.

The two candidates' keys, aligned independently, agree on beats (F1 0.994), chord roots (99.3% of
the time) and bass notes (F1 0.993); their melodies match an octave apart (105027's vocal is also
written an octave high), and their downbeats disagree (F1 0.46) because only 105034 has the 2/4 bars.
The app's `music` pipeline against the 105034 key: beats 0.992, downbeats 0.49 (0.52 at a two-beat
bar shift: the app keeps 4/4 through the MIDI's 2/4 bars), chord root 0.731, maj/min 0.702, bass
0.503, melody 0.123, notes overall 0.329. RealBench's alignment scan puts the app's onsets 0-20 ms
from the key's (median onset error +5.6 ms), so the key's timing is consistent with the audio.

### Coldplay, "Viva la Vida": a steady tempo and a one-beat slip

Recording: `Coldplay - Viva la Vida (Lyrics).mp3` (242.6 s, a steady 137.9 BPM). bitmidi has two
files: 24946 is a 7 s loop of the string riff (no alignment found) and 24989 is a full guitar-tab
style arrangement (Guitar, String Ensemble, a kick on every beat) with no vocal and no bass part.
With the default settings the time map follows one straight line through most of the song but slips
by exactly one beat (435 ms) in the sparse intro and in parts of the second chorus and the bridge;
the kick/snare check flagged the wrong sections (with a kick on every beat it cannot see a one-beat
shift), so roles.json now sets the stiff `align` settings, which keep the whole map within about
60 ms of the line. Against the app's own output the stiff map agrees better than the default over
the same 47.6-214.5 s: note F1 0.179 against 0.162, beats 0.607 against 0.560, downbeats 0.550
against 0.475, chord roots the same (0.75). The key scores 144 s (59%): verse 1, the first
interlude (voicings without roots), the bridge and the ending are left out, and three sections whose
only flag was a known false alarm are kept with `trust`; the reasons for every span are in that
song's `roles.json` comment and the numbers in its `key/report.txt`.

## Known weaknesses

- **Repeating music.** When many bars sound alike (loops, vamps, riffs), a section can be placed a
  bar or a few beats off, and chroma and onset checks cannot see it. The two-pass tempo prior, the
  kick/snare check (one-beat shifts only: most grooves repeat every two beats, so a two-beat shift is
  invisible; a kick on every beat cannot show even a one-beat shift) and the tempo-steadiness check
  catch most of it, not all; for a steady-tempo recording the stiff `align` settings in roles.json
  avoid it. Beats and chord roots survive a whole-bar slip; notes and downbeats do not. Compare
  candidates (`compare`) when you can.
- **Bar lines** come from the MIDI's time signatures. Fan MIDIs disagree (Africa: one has 2/4 bars,
  the other not); check downbeats by ear before trusting downbeat scores (`barShift`, `beatsPerBar`).
- **Octaves.** Fan MIDIs often write the vocal line an octave high; the octave check is a hint, not
  a measurement. Note scores (melody, bass) depend on getting this right; beats and chords do not.
- **Note-level truth is approximate.** Arrangements simplify, quantise and re-voice; pitch bends are
  ignored. Read note F1 against a fan MIDI as a rough guide (the key says `notesComplete: false`).
- **One transposition per song.** A recording that changes key where the MIDI does not (or the other
  way round) gets low chroma there and those sections are flagged, not fixed.
- **Sections in a different order** (not just missing or repeated) cannot be followed: the alignment
  is monotonic.
- **Detuned recordings.** Tuning is estimated and used for the features, but the key's pitches are
  whole semitones; the report warns beyond 25 cents.
- Drum-band channels are fixed frequency bands, so the kick/snare check is weaker for unusual kits.

## Per-song recipe

1. Convert the recording: `afconvert -f WAVE -d LEI16@44100 "bench/songs/bitmidi/<Song>.mp3"
   bench/songs/bitmidi/<slug>/audio.wav`.
2. Find up to 3 candidate MIDIs: `https://bitmidi.com/search?q=<words>`; each song page links
   `/uploads/<id>.mid`. Download each with `curl -fL -o <slug>/midi-candidates/<id>.mid
   https://bitmidi.com/uploads/<id>.mid` and append `<slug>/midi-candidates/<id>.mid, URL, size` to
   `DOWNLOADS.md`. Prefer the songs' own titled files; `bitmidi inspect` shows what each holds.
3. `bitmidi song bench/songs/bitmidi/<slug>` and read `key/report.txt`: transposition and its margin,
   trusted seconds, flagged sections, recording-only and MIDI-only spans, the voice table and the
   octave check, warnings (tempo, meter, unisons).
4. Edit `roles.json`: roles (is the melody the sung line?), `addTranspose` for octave errors,
   `transpose` if the key is ambiguous, `ignore`, `tempoScale`/`barShift`/`beatsPerBar` for the grid.
   Run `song` again. With two good candidates, build both keys (`truth ... --out`) and `compare` them.
5. Score: `realbench <slug>/audio.wav <slug>/key/truth.json --out results/<slug> --pipelines music`, or
   add the song to `songs.json` and use the scoreboard (below).
   In the diagnostics, `alignmentScan.bestShiftMs` far from 0 or a melody that only matches
   octave-folded points back at the key, not the app.

## Scoreboard

`scoreboard.py` (Python 3, standard library) scores Song mode on every song in
[songs.json](songs.json) and keeps the tuning honest. It only reads realbench's outputs.

```
SB="python3 -I Tools/RealBench/bitmidi/scoreboard.py"
export BITMIDI_SONGS=$PWD/bench/songs/bitmidi        # or pass --songs-dir (default: <repo>/bench/songs/bitmidi)
$SB run --tag try1                                   # realbench music,quick-music on every song, one at a time
$SB run --tag try1 --songs africa,let-it-be -- --beats-per-bar 4   # a subset; options after -- go to realbench
$SB collect --tag try1 --json try1.json --md try1.md # metrics of every song, the objective, Markdown tables
$SB compare Tools/RealBench/bitmidi/baseline.json try1.json         # guardrails: exit 0 = accept, 1 = reject
```

`run` writes `<slug>/results/<tag>/` (realbench's usual `summary.*` and `<pipeline>/` files) and
re-scores the saved predictions against each `pitchAlternates` key into `results/<tag>/alt-<key>/`.
To tune the beat grid, the bar lines or the chords on fixed notes, run once with `-- --save-evidence`
and then `realbench regrid <slug>/results/<tag> <slug>/truth.json --out <slug>/results/<newtag>` per
song (and `realbench score` into `alt-<key>/` for a song with pitch alternates); `collect` reads the
result like any run. Each song's `music/diagnostics.json` has `barPhase`: the bar-line decision's
margin section by section, so the fragile sections show (see ../README.md, Diagnostics).
A song takes about 20 s (Transkun dominates), the ten songs about 4 minutes.

**songs.json** lists each song's key (`truth`), its `split`, and what is special about it:
`pitchAlternates` (Still D.R.E. is tuned -49 cents, halfway between A minor and B-flat minor, so its
pitch scores take the better of the two keys; beats and downbeats come from the main key),
`beatLevels` (Country Roads: the key counts 82 BPM, but the 164 BPM pulse is as valid, so the
objective accepts the key at double tempo for beats) and `weak` (metrics whose key is a rough guide
on that song; they are still scored).

**Metrics** (per song and pipeline, in the JSON): beat and downbeat F-measure (+-70 ms), the beat F1
against the key at double and half tempo, downbeat F1 at the best bar shift, app and key tempo and
meter, chord root and root+maj/min accuracy (and root over all chords, and chord coverage), melody
F1 (50 and 100 ms, and pitch-class only), bass F1 (and pitch-class only), chords-part and
countermelody F1, all-notes F1 at 50 and 100 ms (and pitch-class only, precision, recall), part
accuracy, the alignment scan's best shift, the engine and whether the drum cue was on. The Markdown
tables show melody F1 at 50 ms (the objective's) and at 100 ms beside it: a fan MIDI writes the
vocal rhythm on the grid while singers phrase around it, so the 100 ms column shows how much of
the gap is timing. It is reported only.

**Objective**: one number per song, in points: the weighted mean of beat F1 x3, chords (the mean of
root and root+maj/min accuracy) x3, downbeat F1 x1.5, melody F1 x1, bass F1 x1 and all-notes F1 x0.5
(50 ms, exact pitch), over the metrics the song's key can score. Beats and chords carry the owner's
80-90% targets; the note-for-note parts are the stretch goal, and fan-MIDI notes are approximate. The
objective is computed on `music`, Song mode's refine pass (what the app shows after a take).

**Guardrails** (`compare`): a change is accepted only if
- the mean objective over the dev songs gains at least 0.25 points, and
- no dev song loses more than 2 points on its objective or on any headline metric (beats,
  downbeats, chord root, chord maj/min, melody, bass, notes at 50 ms).

Holdout songs are reported, never tuned on; a holdout mean loss of more than 1 point, a run time
growth over 25%, or a `quick-music` headline loss over 2 points prints a warning. Changes to code the
Piano mode shares (BeatTracker, HarmonyStage, VoiceSplitter, NoteFusion) also need the existing
checks: MusicBench's dev songs, RealBench's synthetic sanity songs and the piano clip 3 (see
`../README.md`).

`quick-music` is reported for reference. In the app the preview has no beat grid (the refine pass
supplies it) and names its chords with the note-boundary analyzer, so its beat, downbeat and chord
columns show what the preview's notes would give on a grid, not what the preview shows.

`baseline.json` here is the scoreboard of `work/song-tuning` before any tuning (2026-10-13),
`round1.json` the scoreboard after tuning round 1 (2026-10-14: the r1-downbeat, r1-parts and r1-chords
changes; dev mean objective 51.8 -> 61.7), `round2.json` the scoreboard after round 2 (2026-10-14:
the r2-tempo, r2-chords and r2-bass changes; dev mean objective 61.7 -> 69.8), and `round3.json` the
scoreboard after round 3 (2026-10-14: the r3-barphase change with r2-melody, and r3-tempo; dev mean
objective 69.8 -> 75.1), and `final.json` the scoreboard after the round 3 review's robustness fixes
(2026-10-14: tempo halving only in Song mode and from 155 BPM, BarPhase reads the Downbeat note; dev
unchanged at 75.1, holdout 72.9 -> 69.2 from Let It Be's 70 BPM, tracked at 140 again). Compare the
next round against the latest one. `bench/songs/bitmidi/SCOREBOARD.md` shows the latest round's tables
and a short history of the rounds (`SCOREBOARD-baseline.md`, `SCOREBOARD-round1.md`,
`SCOREBOARD-round2.md` and `SCOREBOARD-round3.md` keep earlier rounds' tables).
