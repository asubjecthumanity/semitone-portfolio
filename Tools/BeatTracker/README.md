# Beat / downbeat tracker — prototype and evaluation

`Semitone/Transcription/BeatTracker.swift` is a bar-pointer model (Krebs, Böck & Widmer 2015;
the model behind madmom's downbeat tracker) run over the transcribed notes:

- **Evidence**: note onsets (beats), low bass onsets + pitch-class change (downbeats). Onsets are
  capped at 0.5 probability so a note between beats costs a little instead of ruling a tempo out.
- **Model**: state = (tempo, position in bar); tempo may change only at beat boundaries,
  `exp(-60·|ratio−1|)`, plus a gentle log-normal preference around 120 BPM (1 octave).
- **Resolution matters**: at 50 frames/s fast tempi (175 BPM ≈ 17.1 frames) fall between integer
  steps and the model retreats to half tempo. 100 frames/s with every integer interval fixes it.
  The beat region (the first 1/16 of each beat, where beat evidence counts) is fractional too: in
  whole frames it was rounded down, so its share of the beat swung with the tempo (4.7% at 140 BPM,
  5.7% at 69) and the tempo octave followed the rounding (October 2026).
- **Short bars**: in an even meter beat 1 may also follow half a bar, at a cost of 10 (log
  likelihood), so a 2/4 bar in a 4/4 song moves the bar lines instead of leaving them on beat 3.
- Auto meter decodes 3, 4 and 5 in parallel and keeps 4 unless another fits clearly better by
  per-frame log-likelihood: 3 by 5%, 5 by 10% (`TempoChoice.meter`). The score is measured above a
  take with no beat at all, so on a grid that fits poorly it sits near 0 and any edge is "10%":
  GuitarSet 03, a strummed 4/4 take tracked at a wrong tempo (115 BPM for 98), is read as 5/4 by
  0.005 with 4/4 at -0.007. A floor under the margin (0.075) fixed it but turned Take Five, a real
  5/4, into 4/4 (October 2026), so it is not used; the right fix is GuitarSet 03's tempo.
- **Tempo octave**: the onsets cannot tell a beat from its subdivision. Below about 125 BPM the beat
  region (1/16 of the beat) is wider than the notes' evidence (3 frames), so a slow grid pays for
  empty region frames and the decoder leans to the double tempo when the eighths are as loud as the
  beats (a ballad at 70 tracks at 140). After decoding, in Song mode only (the refine pass, whose
  evidence carries the audio's chroma), `TempoChoice.countsSubdivisions` halves a grid of 155 BPM or
  more (`slowestHalvedGrid`) when the layers that move once a beat or slower mark only every other grid
  beat: a kit's kick and snare (the stronger of the two per beat; Song mode, from the percussive
  part's 30-150 Hz and 150-2000 Hz bands) on one alternate beat only (weaker at most 70% of the
  stronger; at 80% or more the grid stays), or else a bass (notes below E3) about two grid beats
  apart on the same alternate beats (65% of its notes on the grid). The half-tempo grid is decoded on
  those beats only, so it keeps their phase. A waltz's bass, once a bar, falls on both alternate
  beats; a bass on every beat or in eighths fills both; a kick and snare alternating fill both. The
  user's ½× and 2× re-track from the tempo shown. Doubling a grid is not tried: a walking bass and an
  eighth-note rock bass look the same. The floor: 155 BPM is the geometric mean of about 110 BPM (the
  middle of the 100-120 BPM listeners tap along to most readily) and its double, so from there up the
  half tempo (78 BPM or more) is the nearer count, and below it the grid is. With round 3's floor of
  120, drumless solo-piano pieces in 4/4 with a half-note left hand at 120-150 BPM were halved (beat
  F1 0.99 -> 0.66); the grids that counted eighths on the dev takes ran at 162-182. Piano mode's
  passes and the Home tile preview never halve: a pianist's left hand in half notes marks alternate
  beats at any tempo. Known cost: a ballad under 78 BPM counted in eighths keeps the double tempo
  (Let It Be, 70 BPM, at 140); the ½× button halves it.

`barpointer.py` is the NumPy prototype the Swift port was checked against (98–100% of beats
within 10 ms). `tracker_cli.swift` prints the Swift result for a notes CSV
(`start,end,pitch[,velocity]`):

```
swiftc -O -o trackcli tracker_cli.swift ../../Semitone/Transcription/BeatTracker.swift \
  ../../Semitone/Transcription/NoteEvent.swift
./trackcli notes.csv <beatsPerBar or 0 for auto> <duration s> [tempoOctave] [barShift]
```

Scores on 2026-09-22 (mir_eval F-measure, ±70 ms; clip 3 uses the aligned answer key in
`semitone training/`, excluding its two unalignable passages):

| | beats | bar lines | clip 3 rubato half: beats / bars |
|---|---|---|---|
| clip 1 (4/4, 120 BPM), piano-model or quick notes | 1.00 | 1.00 | — |
| clip 3 (10/8 as 5 beats), piano-model notes | 0.95 | 0.94 | 0.92 / 0.89 |
| previous nearest-onset grid, clip 3 | 0.60 | 0.23 | 0.58 / 0.14 |

Known limit: half/double-tempo ambiguity is inherent (clip 3's chords change every *two* bars, so
a double-length bar fits the harmony as well). The app's ½× / 2× and bar-nudge controls cover it.
More reference clips with MIDI (3/4, 6/8, pop 4/4) are the best way to keep tuning this.
