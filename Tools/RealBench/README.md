# RealBench

`realbench` runs every Semitone transcription pipeline on a real recording (WAV, FLAC, anything
AVFoundation reads, any sample rate or channel count) and scores it against an answer key. Like
`Tools/MusicBench/musicbench`, it compiles the app's own sources, so nothing is reimplemented. It
loads audio the way `TranscriberViewModel.transcribeFile` does and calls the same code the app
calls once a take is finished. Matching reuses MusicBench's `Scoring.swift`, so on synthetic songs
the numbers are musicbench's own (see "Sanity checks").

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Tools/RealBench/build.sh   # -> Tools/RealBench/.build/realbench
B=Tools/RealBench/.build/realbench

$B song.flac truth.json --out results/song                     # all four pipelines, scored
$B song.flac truth.json --out results/song --start 60 --duration 60 --pipelines piano,music
$B song.wav none --out results/song                            # transcribe only (notes.json + notes.mid)
$B score results/song truth_v2.json                            # re-score saved predictions (no models), e.g. after fixing the key
$B song.flac truth.json --out results/song --pipelines music --save-evidence   # also keep what the analysis reads
$B regrid results/song truth.json --out results/song-try       # beat grid, bar lines and chords again on those notes (1-2 s)
$B midi2truth truth.json --midi bass.mid --part bass --transpose -12 --midi drums.mid --drums --grid-from bass.mid
$B check truth.json                                            # validate and summarize a key
$B parse-chord "A-7" "C:maj/5" "F#-7b5"                        # how chord labels are read
python3 Tools/RealBench/make_truth.py musicbench song.json -o truth.json   # MusicBench render JSON -> truth
python3 Tools/RealBench/make_truth.py notelist notes.json -o truth.json --part piano --until 60
python3 Tools/RealBench/make_truth.py merge a.json b.json -o truth.json
python3 Tools/RealBench/als2truth/als2truth.py song.als --out keys/song   # Ableton set -> truth, roles, report, MIDI
```

Run options: `--pipelines quick,quick-music,piano,music` (default all), `--start S --duration D`
(clip; all times stay on the file's timeline), `--ignore a:b` (extra unscored span, repeatable),
`--detection piano|auto|gentle|dense` (quick passes' preset, app default `piano` = Balanced),
`--beats-per-bar N` (the app's meter setting, default auto: 3, 4 or 5; the sanity check passes 5 for
clip 3 of `semitone training`), `--tempo-octave -1|1` (the ½× / 2× buttons), `--downbeat-pitch-class N` (the "note on
beat 1" hint), `--piano-units ane|cpu|all|gpu` (Core ML units for Transkun; the app uses `ane` =
`.cpuAndNeuralEngine`). The binary finds the repo from its own path (`Tools/RealBench/.build`);
set `REALBENCH_REPO` if you move it. `build.sh` also compiles `NMP` and `TranskunBackbone` to
`.build/*.mlmodelc`, as Xcode does for the app bundle.

Speed (M-series Mac): a 4.6 min song runs all four pipelines in about 28 s (Transkun 18 s) with a
peak of about 0.6 GB.

**Evidence and regrid.** `--save-evidence` writes `<pipeline>/evidence.json` next to each
prediction: the notes, the notes the chords also read (`RefineOutput.harmonyNotes`) and the audio's
rhythm and pitch evidence (`AudioOnsets`), all as the post-take analysis received them. `realbench
regrid RUN KEY --out DIR` reads them back and runs only `TakeAnalysis.derive` (beat grid, bar lines,
chords, melody) with the current code, then scores; options `--beats-per-bar`, `--tempo-octave`,
`--downbeat-pitch-class`, `--ignore`. A regrid of an unchanged build gives the run's prediction
exactly. Use it to tune the rhythm and chord stages on fixed notes (a 7-song set in seconds); anything
that changes the notes needs a full run.

## Pipelines

| name | what the app does | app code |
|---|---|---|
| `quick` | Piano mode's Basic Pitch pass: the live/quick notes, and the final notes when the piano model is off. Input `AudioFileLoader.loadMono22k` (first channel, all channels mixed if it is quiet), the detection preset resolved for `.piano` (Balanced 0.70/0.30/150 ms), no parts. | `TranscriptionEngine`, `NoteExtraction` |
| `quick-music` | Any-instrument mode's quick preview before its refine pass ends: all channels mixed at 22050 Hz, preset resolved for `.music` (Balanced = 0.70/0.40/90 ms), `VoiceSplitter` parts, no drums. | + `VoiceSplitter` |
| `piano` | Piano mode's refine pass: Transkun v2 on the 44.1 kHz take (`loadMono(44100)`, channels mixed), `.cpuAndNeuralEngine`, notes and sustain pedal. `info.verdict` is the engine arbiter's decision; when it is not `accept`, the prediction holds the quick notes, as the app shows. | `PianoTranscriber` |
| `music` | Any-instrument refine pass (`TakePipeline.refine`): the 44.1 kHz take and its 22050 Hz copy, the source profile (HPSS), Transkun checked against the quick notes by the engine arbiter (Basic Pitch on the tonal part or the mix when it rejects Transkun), `VoiceSplitter` parts. No drums: the app no longer transcribes them. `info.verdict`, `info.engine` and `info.percussiveShare` say which path ran. | `TakePipeline` |

For every pipeline the app's post-take analysis then runs on its notes, as in
`TranscriberViewModel.derive` (`TakeAnalysis.derive`). `BeatGrid.compute` runs the bar-pointer
`BeatTracker` on the notes and, for the refine passes, the audio's onsets (`AudioOnsets`; for
`music`, the tonal part's onsets and chord changes, plus the percussive part's onsets on a take
with a kit, weighted by its percussive share: `info.percussionCue` is `on` at full weight, else
the weight, or `off`); in Song mode a 4/4 take's bar lines are then decided again from the tonal
part's chord changes (`BarPhase`, see `barPhase` under Diagnostics). `HarmonyStage` finds the chords on that grid (for `music` from the refine pass's notes plus the
preview's, `RefineOutput.harmonyNotes`, and the tonal part's chroma, `AudioOnsets.chroma`, as the
app does). The melody comes from
`LeadLine.melody` for unsplit notes and is the melody part for split ones. The MIDI file is the
app's own export (`MidiExport.file`: tempo map from the beat grid, the app's part tracks, the
sustain pedal for `piano`).

## Truth format (`realbench-truth-1`)

One JSON object; times in seconds on the audio file's timeline. Only `notes` is needed; a
section that is missing is not scored. Full example: [example_truth.json](example_truth.json).

```json
{
  "format": "realbench-truth-1",
  "name": "angie",
  "source": "Slakh Track02095 stems S00-S06; bass transposed -12 (Slakh quirk)",
  "notesComplete": true,
  "offsetsReliable": true,
  "notes": [
    {"on": 5.221, "off": 5.702, "pitch": 64, "velocity": 90, "part": "melody", "instrument": "Pan Flute"},
    {"on": 5.221, "off": 7.104, "pitch": 40, "part": "bass", "instrument": "Electric Bass"},
    {"on": 5.230, "off": 5.900, "pitch": 55, "part": "guitar1", "instrument": "Acoustic Guitar (steel)"}
  ],
  "drums": [{"time": 5.221, "class": "kick"}, {"time": 5.5, "gmNote": 42, "velocity": 80}],
  "beats": [5.221, 5.9, 6.58],
  "downbeats": [5.221],
  "beatsPerBar": 4,
  "chords": [{"start": 5.2, "end": 7.9, "label": "A:min"}, {"start": 7.9, "end": 9.3, "label": "E7"},
             {"start": 9.3, "end": 10.0, "root": 7, "quality": "maj"}, {"start": 10.0, "end": 11.0, "label": "N"}],
  "ignore": [[110.0, 130.0]]
}
```

- **notes**: `on`, `off`, `pitch` (MIDI; fractional values round), optional `velocity`, `part`,
  `instrument`. A `part` of `melody`, `countermelody`, `chords` or `bass` is a *role*, scored
  against the app's part of that name (the summary's `counter` column is `countermelody`). Any other part name (`piano`, `soprano`, `guitar1`) and every `instrument` is a
  *named part*, scored by recall: how many of its notes the whole prediction finds, and which app
  part they landed in. Without a `part` a note is in part `notes`.
- **drums** (optional): `time` plus `class` (`kick`, `snare`, `hihat`; aliases such as `bd`, `sd`,
  `hh`, `closed hat`, `ride` are accepted) or `gmNote` (General MIDI key; the classes follow
  MusicBench's `DrumClass.of`). Toms, crashes and other classes are kept but not scored. A missing
  `drums` section means drums are not scored. `"drums": []` marks a drumless song, so every
  detected hit counts as a false alarm.
- **beats / downbeats** (optional): times; `beatsPerBar` is informational (pass `--beats-per-bar`
  to make the app use a meter).
- **chords** (optional): `start`, `end` and either `label` or `root` (0 = C) plus `quality`. Labels
  can be Harte (`C:maj`, `A:min7/5`, `G:maj(2)/1`, `D:hdim7`, `N`) or lead-sheet (`Am7`, `A-7`,
  `GM7`, `F#-7b5`, `B7b9`, `Eb7`). Check how a label is read with `realbench parse-chord`.
- **ignore** (optional): `[start, end]` spans left out of every score (misaligned or unlabelled
  passages). Notes and hits are dropped by onset, chord time is clipped.
- **notesComplete** (default true): set false when audible pitched parts have no key (e.g.
  JazzSAMBA's horns and bass). Precision then counts real notes as false and is only a lower
  bound, so read recall and the named-part recalls.
- **offsetsReliable** (default true): set false when offsets are estimated (GuitarSet). The
  onset+offset score and the duration diagnostics are then flagged.

Converters: `make_truth.py musicbench|notelist|merge` (Python, standard library) and `realbench
midi2truth` (Swift, using each file's tempo map via AudioToolbox). midi2truth options that follow a
`--midi FILE` apply to that file: `--part`, `--instrument`, `--transpose N`, `--offset S` and
`--drums`. Notes on channel 10 always become drum hits. `--grid-from FILE` writes beats and
downbeats from that file's tempo map and time signatures (compound 6/8, 9/8 and 12/8 count dotted
quarters), up to its last note. `--ignore a:b` adds an ignore span. A file with no tempo event is
read at 120 BPM, and the tool says so.

## Ableton sets: `als2truth`

`als2truth/als2truth.py` (Python 3, standard library only) turns an Ableton Live set into a key
for Song mode: melody, countermelody, chords and bass, with drums left out. It only reads the
`.als` file, which is gzip-compressed XML. It never opens Live.

```
A=Tools/RealBench/als2truth
python3 $A/als2truth.py "Song.als" --out keys/song             # writes truth, roles, report, MIDI
#   ...listen to keys/song/midi/*.mid, edit keys/song/roles.json...
python3 $A/als2truth.py "Song.als" --out keys/song             # run again: roles.json is honoured
python3 $A/als2truth.py "Song.als" --out keys/song --export-start 32   # audio rendered from bar 9
python3 $A/check_als.py "Song.als" keys/song                   # independent recount of the clip notes
python3 $A/test_als2truth.py                                   # unit tests on synthetic sets
```

Options: `--roles FILE` (default `OUT/roles.json`), `--fresh-roles` (write new suggestions over an
existing roles file), `--name`, `--export-start BEAT` (the arrangement beat at audio time 0),
`--offset S`, `--include-muted`, `--ignore-solo`, `--no-chase`, `--trust-flagged` (put every
flagged track's notes in the key), `--probability keep` (keep notes whose chance is below 100%)
and `--notes-complete true|false`. A set with no arrangement MIDI clip (a Push edition keeps its
music in Session View clips) stops with an error and writes nothing. Same-pitch notes that start
within 50 ms on different tracks (a sub bass under a mid bass, a pad doubling the lead) are merged
into one note, because a transcription hears one note and the scorer matches one-to-one;
`--keep-unisons` keeps them apart.

**Outputs** in `OUT/`:
- `truth.json`: a `realbench-truth-1` key. Each note's `part` is its track's role and its
  `instrument` is the track name. `beats`/`downbeats` come from the tempo map and time signature,
  up to the end of the last clip. `chords` are Harte labels per beat from the chord-role tracks,
  with the bass role giving the inversion. Labels are smoothed: changing chord costs a little, so
  a rolled chord or a one-beat rest does not flip the label. Roots are spelled to suit the
  estimated key. There is no `drums` section. Two extra keys are ignored by RealBench:
  `unreliableNotes` (flagged notes, each with `flags`) and `als2truth` (tempo, signatures, roles,
  the post-FX and check-by-ear lists). `notesComplete` is false when an audible audio track looks
  pitched (for example vocals), because audio tracks are not in the key.
- `roles.json`: one entry per MIDI track, with `role` (melody | countermelody | chords | bass |
  ignore), `suggested` and `why`. You can also set `transpose` (`"auto"`, or a whole number of
  semitones that replaces the device transposes), `addTranspose` (added on top, for octave
  fixes), `trust` (true puts a flagged track's notes in the key: post-FX and check-by-ear flags;
  chance below 100% is `--probability`), and `soundsLike` with `skipMidiEffects` (play the notes
  through another track's instrument). Entries match tracks by Live's track id, then by name.
  Your edits are kept, and new tracks are appended.
- `report.txt` and `report.json`. For each track: its state (mute, mute automation, solo, freeze,
  monitoring), counts (clip events, notes played, chased, deactivated, muted, silent in rack zones,
  chance below 100%, bends, pitch-envelope and clip-envelope notes, in the key, unreliable), pitch
  range and polyphony, every transpose applied and where it came from, layered chains or
  oscillators, the device tree, and flags. At the top: the tracks that need post-FX MIDI, the
  tracks to check by ear, and the audio tracks that are not in the key.
- `midi/melody.mid`, `countermelody.mid`, `chords.mid`, `bass.mid`: one MIDI track per Ableton
  track, on the set's tempo map, at the sounding pitches. Use them to check roles and octaves by
  ear. `midi/unreliable.mid` holds the flagged notes.

**Clips**: only Arrangement View MIDI clips on the main lane are read (Session View clips and take
lanes are not). Each clip plays from its start marker and fills its arrangement length. A looped
clip wraps from the loop end back to the loop start, as often as the length needs. Notes are cut at
the loop end and at the clip end. A note within 0.0001 beat of a clip or loop start is on it (Live
stores some boundary notes at -0.00000026). Deactivated notes and clips are skipped. A note that is
already sounding where a clip begins starts at the clip start, as Live's default "Chase MIDI Notes"
does (`--no-chase` turns this off). Notes whose chance (probability) is below 100% go to
`unreliableNotes`. A track that is muted or soloed out is dropped. Mute automation on the track or
its groups drops notes that start while it is off, and cuts notes that are sounding when it turns
off. Tempo automation ramps linearly in beats, and time-signature automation is read too.

Clip envelopes are read in clip time, so they repeat with the loop (an unlinked envelope with its
own loop is read as linked). A channel pitch-bend envelope that is away from 0 (more than 64 of
8192) at a note's onset makes that note unreliable, because the instrument's bend range is not
read; bends while a note sounds are counted. An envelope on a pitch parameter (a transpose, say)
makes the notes of its clips unreliable. Other envelopes (channel pressure, MIDI CCs, other device
parameters) are listed but not read.

**Sounding pitch.** Device parameters are read at each note's onset: automation, rack macros
(including automated macros) and macro mapping ranges are all included. The tool applies:
- the Pitch effect, and the Scale effect's note map (but not the "use current scale" mode);
- the Velocity effect's gate;
- Note Length in note-on mode with a fixed time, which sets every note's duration (synced lengths
  are flagged, and `offsetsReliable` becomes false);
- rack key, velocity and chain-selector zones, chain activators and chain solo (a note that no
  chain plays is silent);
- Sampler sample zones;
- instrument transposes: Operator's Transpose, Simpler and Sampler Transpose (with Fine rounded),
  Wavetable global and per-oscillator transposes, Drift global transpose and oscillator octaves,
  Meld engine transpose and octaves, Analog octave and semitone, and a top-level Octave/Transpose
  on other instruments (Tension, Collision, Electric);
- Operator's ratios. The oscillators that sound (within 18 dB of the loudest) and do not die away
  at once (sustain above -40 dB, or longer than 150 ms) form the body of the sound. Carriers or
  modulators, its fundamental is the greatest common divisor of their ratios: a 1:0.5 pair sounds
  at 0.5. When that is an octave of the key and an oscillator at that ratio holds within 6 dB of
  the loudest, the octave is applied (-12 for 0.5) and flagged; a body at another ratio is flagged
  only.

A synth with several oscillators: oscillators more than 18 dB below the loudest are ignored. If
the rest share a pitch class, the lowest main oscillator sets the octave (a sub oscillator only
when nothing else is left). If they do not, a voice at an octave of the played key wins, because
such patches are tuned so the played key names the note. Rack chains that sound at different
pitches give the lowest one. A per-note (MPE) pitch bend at the onset is applied, rounded to a
semitone (8192 = 48 semitones, Live's MPE range); a note whose onset bend is more than 0.25
semitone from a whole semitone is unreliable. Later bends are only counted as glides. The report
names every layered patch, so you can fix an octave with `addTranspose`.

Not modelled (check by ear): whether a sample is in tune at its root key, audio effects that shift
pitch (Grain Delay, Shifter and Vocoder are flagged), grooves (flagged), curved automation and
Operator pitch-envelope slopes (read as straight lines), the instrument's pitch-bend range, MPE
routings inside instruments (Meld's or Drift's pressure and slide targets), clip envelopes other
than pitch bend and pitch parameters (listed), and plug-in or Max instruments (MIDI pitch is
assumed). A macro mapping is assumed linear over its range, on the innermost rack.

**Post-FX MIDI.** Some MIDI effects make the played notes differ from the clip in ways the tool
cannot reproduce: Arpeggiator, Chord, Random, Note Length in note-off mode, a Velocity gate with
random velocity, Scale or Pitch following the clip scale, and Max for Live MIDI effects that make
or move notes (Note Echo, a Strum rack, any Max effect the tool does not know). The same goes for
notes with chance below 100% and probability groups. These tracks are listed under "POST-FX MIDI
NEEDED". Their raw notes go to `unreliableNotes` and `midi/unreliable.mid`. Arpeggiated or
strummed chord parts still feed the chord labels, because the arpeggiator keeps the held pitches.
To get real notes:
1. In Live, add a MIDI track with no instrument.
2. Set its MIDI From to the flagged track at **Post FX**, arm it, and record the song into the
   Arrangement.
3. In `roles.json`, set the original track to `ignore` and give the new track its role. The new
   track takes its MIDI from the flagged track, so als2truth plays it through that track's
   instrument and skips its MIDI effects. You can also say this with `"soundsLike": "<track>"` and
   `"skipMidiEffects": true`.

For Random or chance notes, render the audio from the recorded notes, not the original effect,
because each playback rolls the dice again.

**Check by ear.** Some notes are right in the clip but may not sound at their written pitch.
Recording post-FX MIDI would give back the same notes, so these tracks are listed under "CHECK BY
EAR" instead. Listen, then set `"trust": true` (or fix the octave with `addTranspose`):
- Max for Live devices that pass the notes through and map a source to device parameters
  (Expression Control, LFO MIDI, Shaper MIDI, Envelope MIDI, and Max audio modulators such as
  Envelope Follower). Their targets are read from the set (the device's id references name the
  parameters' object ids) and followed through rack macros. With no pitch target, the notes stay
  in the key. With a pitch target the notes are unreliable, except for an Expression Control slot
  whose source (pressure, slide, pitch bend, a controller) has no data in the clips: it stays at its
  stored value, so the notes stay in the key and the track is listed. Expression Control slots are
  told apart by their subpatcher ids (`obj-25` is slot 1, `obj-44` slot 2, `obj-48` slot 3, `obj-54`
  slot 4), inferred from the demo sets; another id counts as an unknown source.
- MPE Control passes the notes through and reshapes MPE pressure, slide and pitch bend: a note that
  starts bent is unreliable. CC Control's controllers are not read, so its notes are unreliable.
- An Operator pitch envelope (on, with a nonzero amount, on an oscillator that sounds): levels are
  semitones times the amount. A note shorter than the time the pitch takes to come within half a
  semitone of where it stays is unreliable, and every note is when the envelope loops or holds away
  from 0.
- A per-note bend between semitones, and the clip envelopes above.

**Roles** are suggested from the track name, the instrument, the pitch range, polyphony, rolled-chord
onsets, note density and note length:
- `ignore`: drum racks and drum or FX names, Simpler in slicing mode, more than 8 notes per active
  beat, tracks with no audible notes, and tracks whose notes are 80% or more shorter than 100 ms
  (thumps or blips, which are also too short to set a chord's bass; give such a track a role if it
  carries a part).
- `bass`: bass names, or a low line that is mostly monophonic.
- `chords`: pads and keys, or polyphonic tracks.
- `melody`: the most prominent remaining melodic line.
- `countermelody`: every other melodic line. When an audible audio track looks like the vocal
  (Lead, Vocal, Vox), every melodic MIDI track becomes a countermelody, because the sung melody is
  not in the key.

RealBench scores all four roles, `countermelody` included, against the app's parts of the same
name (see the truth format above).

Validation on the demo sets that ship with Live, run on copies with suggested roles (2026-10-10,
als2truth v2). In every case `check_als.py`'s independent recount matched the converter's
played-note count on every track:

| set | tempo | key notes (bass/chords/countermelody) | unreliable | post-FX MIDI needed | check by ear |
|---|---|---|---|---|---|
| Ninajirachi - In The Rain (Live 11 Suite) | 165 | 455 (124/206/125) | 333 | Plastic Toy, Brass (Arpeggiator), String Sample (chance) | Outland Bells (ratio 0.5: -12 applied) |
| same, Standard | 165 | 455 (124/206/125) | 333 | same | same |
| same, Intro | 165 | 364 (66/173/125) | 235 | Plastic Toy, String Sample | - |
| same, Lite | 165 | 349 (66/173/110) | 236 | Plastic Toy, String Sample | - |
| Chuck Sutton - Patience (Live 12 Suite) | 167 | 541 (185/356/0) | 613 | Strum (Arpeggiator) | Rose Bass, Sub Sub Bass, Guit Layter, Vacuum |
| same, Standard and Intro | 167 | 541 (185/356/0) | 613 | same | same |
| same, Lite | 167 | 410 (161/249/0) | 607 | same | Rose Bass, Vacuum |
| both Push editions | | nothing written (Session View clips only) | | | |

These counts predate unison merging. With it, In The Rain (Suite) keeps 393 notes with the
suggested roles and 377 after its stem calibration (below), and Patience keeps 309.

Checks behind the table:
- Patience's Sub Sub Bass sounds 36 semitones below its clips on all 38 notes: Operator Transpose
  -24, and its macros switch oscillator A (ratio 1) off ("Octave Tail" at 0), so only the ratio-0.5
  oscillators sound (-12). Its "Swoop" macro (0) sets the pitch-envelope amount to 0, so there is no
  swoop; the stored amount of -100% is stale. The Beat Of History plays 36 below, because its
  loudest Meld engine is 3 octaves down, and its Note Length makes every note 60 ms long, so it is
  suggested `ignore`. Coffee Leaf and Mello play 12 above (Drift oscillators an octave up). Guit
  Layter and Vacuum follow their automated "Octave" and "Pitch" macros (Sampler Transpose -12 to
  0). 6 and 3 of their notes start with a per-note bend of 18.55, 12.26 or 14.44 semitones, 0.26 to
  0.45 off a semitone, and are unreliable (bends of 13.21 are rounded and kept).
- Patience's Expression Controls: Rose Bass maps pressure to its Meld transposes (through macro
  1), but its clips carry no pressure, so its 147-note bass line is in the key. Vacuum's maps
  pressure to the Sampler sustain, and Strum's to its "Strum" and "Filter" macros (velocity, drive,
  filter and attack; no pitch). Strum stays post-FX for its Arpeggiator.
- Patience's clip notes stored at -0.00000026 beat (8 on Guit Layter, 4 on Vacuum, 18 on Transform
  Seed) start on the clip or loop boundary, with or without `--no-chase` (v1 counted them as
  chased, and `--no-chase` dropped 8 of Guit Layter's notes). The 4 notes still chased on Vacuum
  start 6.5 to 17 beats before their clip.
- Patience's pitch-bend clip envelopes (Coffee Leaf, Guit Layter, Vacuum) are 0 at every onset;
  Coffee Leaf's one jump to 2496 (beat 31.70, 0.01 beat) falls where no note sounds.
- In The Rain's Outland Bells: both Operator chains have their loudest oscillator at ratio 0.5,
  so the key is 12 below v1's; this matches the octave found by ear against the stems (a roles
  file that added -12 for it under v1 should now add 0).
- In The Rain's looped bass clips, with start offsets and partial loops, unroll to the counted
  notes. Its mute automation on Bass Sub and Bass Short (73 breakpoints) is applied. Bass Short's
  Operator pitch envelope (+2.7 semitones falling to 0 in 267 ms) settles before every note ends.
  Bass Reese (Intro) is in the key: its clips carry no per-note bend for MPE Control to reshape.

### From a set to a test song

A key is only as good as its match with the audio, so render the set and check the key against
the stems before scoring anything:

1. **Export** in Live (File > Export Audio/Video): Rendered Track = **All Individual Tracks**,
   Render Start 1.1.1 (or pass `--export-start`), Include Return and Master Effects **On**, PCM.
   Live writes one file per track, named "<name> <track>.aif". A **group track's** file already
   contains its members, so use either the group or its members in a mix, never both.
2. **Mix** the stems you want with `swift als2truth/mix_stems.swift OUT.wav STEM...` (unity gain,
   then -1 dBFS peak). Useful mixes: only the tracks whose notes are all in the key
   (`notesComplete: true`); everything but the vocals; everything.
3. **Check pitches** with `swift als2truth/stem_pitch.swift truth.json STEMDIR`. Sample-based
   instruments sound relative to their sample's root key and layered synths can sit an octave off;
   the set does not say either. For each track it measures the stem's energy at the key's pitch
   shifted by -36..+36 semitones and suggests where the fundamental is. Put a confirmed shift in
   `roles.json` as `addTranspose` and re-run als2truth. Trust it on single lines; for chord tracks
   that double notes in octaves, confirm by ear or by transcribing the stem alone (RealBench with
   `none` as the key) and comparing pitches note by note.
4. **No licence to export?** `swift als2truth/render_gm.swift truth.json OUTDIR --trust-flagged`
   plays the key through the General MIDI sounds that ship with macOS (one stem per track, levelled
   by part, plus `mix.wav`). Every rendered note is in the written key, so it is complete, and
   flagged raw notes become exact truth because they are what was rendered. Timbres are General
   MIDI, not the set's.

What this found on In The Rain (Live 11 Suite export, 2026-10-10): the converter's pitches were off
for Synth Keys and Brass (-24), Outland Bells (-12; als2truth v2 now gets this one from Operator's
ratios), Plastic Toy (+12, the wrong layered oscillator) and Synth Sample (+24, Simpler root key);
the bass tracks and String Synth were right. String
Sample's sample sits about +5/+8 semitones from its notes and was left out. Bass Reese is a
high-passed layer whose strongest partial is the 2nd harmonic, so its written pitch stands. Bass
Short doubles Bass Sub on all 42 of its notes, which is what the unison merge is for. Live 12 sets
cannot be opened in Live 11, so Patience was rendered with `render_gm.swift`.

## Fan-made MIDI: `bitmidi`

[bitmidi/](bitmidi/README.md) builds a key for a real recording from a fan-made MIDI file (for example
from bitmidi.com): it aligns the MIDI to the recording (transposition, tempo drift, missing or
repeated sections), flags the spans it does not trust, assigns melody, countermelody, chords and bass
from the MIDI's tracks, and writes beats, downbeats and chords per beat from the MIDI's own tempo map,
meter and harmony. `readMidi` (above) also returns each note's GM program, the time signatures, the
tempo changes and lyric events for it.

## Outputs (`--out DIR`)

```
DIR/summary.txt                 the table below, one row per pipeline
DIR/summary.json                settings, command line, every pipeline's score.json
DIR/<pipeline>/notes.json       prediction (realbench-prediction-1)
DIR/<pipeline>/notes.mid        the app's MIDI export of the same take
DIR/<pipeline>/score.json       scores (below)
DIR/<pipeline>/diagnostics.json error analysis (below)
DIR/<pipeline>/errors.csv       every true and predicted note: TP / FN / FP, partner note, onset error, cause
```

`notes.json` has the following fields:
- `notes`: `start`, `end`, `pitch`, `velocity` (as the app's MIDI export writes it), `amplitude`
  and `part`, which is `none` (unsplit), `melody`, `countermelody`, `chords` or `bass`.
- `leadLine`: the melody the app shows.
- `sustain`: pedal spans.
- `drums`: `null` (no pipeline transcribes drums any more). Predictions saved before October
  2026 may hold `time`, `kind`, `gmNote` and `velocity` for `music`, and `realbench score` still
  scores them.
- `beats`, `downbeats`, `beatsPerBar`, `bpm` and `chords` (`start`, `end`, `label`).
- `info`: thresholds, the input path taken, fallback flags and timings.
- `clipStart` and `clipDuration`.

`summary.txt` columns:

```
pipeline     notes50   P50    R50  | notes100 octfold50 on+off50 | melody counter chords  bass  partAcc |  kick  snare  hihat  | beats  downb | chRoot chMajMin |  sec
```

**Scores** (`score.json`), mir_eval conventions (the same as MusicBench):
- `notes.onset50` and `notes.onset100`: exact MIDI pitch, onset within ±50 or ±100 ms (distance
  rounded to 4 decimals, inclusive), one-to-one maximum matching.
- `onset50OctaveFolded` and `onset100OctaveFolded`: the same, matching on pitch class only.
- `onsetOffset50`: adds mir_eval's offset rule, max(50 ms, 20% of the true duration).
- `parts.roles.<melody|countermelody|chords|bass>`: the app's notes for that part against the truth
  notes of that role. Unsplit pipelines are scored on melody only, using LeadLine.
- `parts.partAccuracy`: share of matched role notes that landed in the right part (split
  pipelines only).
- `parts.named["part:X" | "instrument:Y"]`: recall at 50 and 100 ms, octave-folded recall, pitch
  range, and `foundAsPart` (which app part the found notes got).
- `drums`: `{"scored": false}` when the truth has a drums section, since the app no longer
  transcribes drums (`summary.txt` says "not scored"). For an older prediction that has drums,
  `drums.<kick|snare|hihat|all>`: onsets within ±50 ms; its closedHat, openHat and ride count as
  hihat.
- `beats.beats` and `beats.downbeats`: F-measure within ±70 ms, plus the predicted and true BPM and
  meter.
- `chords.root` and `chords.majmin`: share of time (50 ms steps) with the right root, and with the
  right root and major/minor class, over truth chords that reduce to maj or min (MusicBench's
  `scoreChords`). `rootAllChords` also counts dim, sus and aug spans. `predChordCoverage` is the
  share of chord time where the app shows any chord.

**Diagnostics** (`diagnostics.json`):
- `onsetError`: histogram (10 ms bins, ±100 ms), mean, median and the share within 25 or 50 ms.
  These come from exact-pitch matches within 100 ms. A median far from 0 means latency or a shifted
  key.
- `alignmentScan`: F1 at 50 ms after shifting every predicted onset by −200 to +200 ms. The best
  shift shows a constant offset between audio and key.
- `pitchErrors`: leftover predictions paired with leftover true notes struck within 50 ms,
  counted by interval and grouped (octave, fifth/twelfth, fourth, semitone, whole tone, third,
  other).
- `pitchClassConfusion` (12×12) and `octaveConfusion` (true × predicted octave): over the exact
  matches plus the wrong-pitch pairs.
- `errorCauses`: every false positive and false negative gets one cause, with counts and example
  times. False positives:
  - wrong pitch
  - duplicate onset
  - timing off by 50–150 ms
  - re-onset inside a held true note
  - ghost octave or harmonic (2nd–8th partial or a sub-octave) of a struck note, then of a
    sounding note
  - neighbour of a true note
  - unrelated pitch, or a note in silence

  False negatives:
  - wrong pitch
  - one predicted note for two true notes
  - timing off by 50–150 ms
  - not re-struck (inside a held predicted note)
  - masked by a found octave or harmonic
  - nothing, or only other notes, detected

  `errors.csv` gives the same cause for each note.
- `velocity`: median true velocity of found versus missed notes.
- `byOctave` and `byPitchClass`: TP, FP and FN, precision, recall and F1 per pitch range and per
  pitch class.
- `overTime`: TP, FP, FN and F1 per 10 s window.
- `duration`: for exact 50 ms matches, an offset-error histogram (100 ms bins), a histogram of the
  log2 duration ratio, the median ratio, and counts of notes too short (under 0.5×) or too long
  (over 2×).
- `drums` (older predictions with drums only): median timing per class, and false hits explained
  as class confusion, a tom or cymbal hit, or nothing.
- `beats`: beat F1 against the truth at double tempo and at half tempo (both phases), and downbeat
  F1 for every bar shift (the app's ½×, 2× and bar-nudge controls).
- `barPhase` (takes with the audio's chroma, i.e. `music`): Song mode's bar-line decision
  (`BarPhase`) section by section, 8 bars at a time. `margin` is the evidence for the bar lines shown
  minus that for their best shift (`runnerUpShift` beats later), in the clipped z-score units the
  decision uses (a clear bar is about 1; with `--downbeat-pitch-class` the hinted note counts too,
  at twice the chord change); under 2 the section is `fragile`, so a small change in the
  notes or the audio could move its bar lines. `decoderAgrees` says whether the bar-pointer model
  alone had the same bar lines there, and `downbeatF1` is the section's own score against the key
  (under 0.5 = `wrong`). `summary.txt` adds one line: sections scored, fragile, wrong, and wrong and
  fragile. A wrong section that is not fragile points at the evidence (or the key), a fragile one at
  the decision.

Clips: when `--start` is above 0, a 100 ms edge guard `[start, start + 0.1)` is added to the
ignore spans. Notes held across the cut are otherwise heard as onsets at the clip start.

## Sanity checks (2026-10-10, work/song-mode 7950f16)

Synthetic MusicBench songs. The key comes from `make_truth.py musicbench` and the audio from
`render --only`. Since Prerelease 0.9 the `music` pipeline is the Transkun refine pass, so the
cross-check with musicbench is the Basic Pitch preview, `quick-music`: its notes and parts equal
musicbench's "mix music" preset line, and its beats (from the notes alone, as in the live preview)
equal musicbench's "notes only" figure where musicbench also reads the mix (test01; on test02,
whose kit puts it over `tonalPartAbove`, musicbench tracks its tonal-part notes, 0.928/0.968).
Drums are not scored: the app no longer transcribes them, and the keys keep their hits only for
older predictions.

| song | realbench `quick-music` (notes F1/P/R · melody/chords/bass · part acc · beats/downbeats) | musicbench | drums |
|---|---|---|---|
| test01 waltz, no drums | 0.858/0.826/0.893 · 0.850/0.867/0.400 · 0.940 · 0.981/0.981 | identical | none in the key |
| test02 pop, a kit | 0.573/0.522/0.636 · 0.712/0.345/0.576 · 0.846 · 0.943/0.968 | notes and parts identical | not scored |

Chords differ by design: RealBench scores the app's beat-synchronous chords (`quick-music` root
0.987 on test01, 1.000 on test02), musicbench the note-boundary analyzer (0.798, 0.862). For the
record, the refine pass (`music`) scores 0.877/0.829/0.931 · 0.850/0.888/0.523 · 0.947 ·
0.951/0.963 on test01 and 0.625/0.549/0.724 · 0.712/0.431/0.611 · 0.859 · 0.943/0.968 on test02;
neither song is drum-heavy (percussive share 0.037 and 0.121), so neither gets the percussive cue.

On a mono file `quick` equals musicbench's "mix piano" preset line (test01: 0.859/0.832/0.889).

piano44 (`sanity.sh` step 3; 2026-10-14, tune/r3-barphase): a 4/4 solo-piano piece with two 2/4
bars (bars 11 and 28) written by `piano44/make_piano44.py` and rendered with the macOS General MIDI
piano, because clip 3 is in 5/4 and never takes the half-bar cut. Beats / downbeats: `quick`
0.822 / 0.800 (double tempo in the broken-chord opening), `piano` 0.992 / 0.625 (the opening's
10 bars two beats off; the second 2/4 bar taken a bar late), `music` 0.984 / 0.656 (round 2:
0.862; `BarPhase` keeps the opening two beats off, because its broken chords change pitch classes on
every beat and give the chord changes little margin, then follows the second 2/4 bar exactly).
Piano mode does not use `BarPhase`, so `quick` and `piano` are unchanged by it.

Piano reference clip 3 (`semitone training/AUDIOTEST3.wav`, aligned keys, read only):
- First 60 s against `MIDITEST3_aligned_steady.json` (onsets under 60 s): `piano` (Transkun) scores
  onset F1 0.999. `Tools/PianoModel/README.md` gives 0.999 for the same minute. `quick` (Basic
  Pitch) scores 0.896.
- Whole trusted set (steady and rubato keys, 110–130 s and 240–250 s ignored): `piano` scores 0.971
  and `quick` 0.846. The known values are 0.971–0.972 and 0.845.
