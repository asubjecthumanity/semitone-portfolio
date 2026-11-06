# MusicBench

Benchmark tools for Semitone's transcription. `GroundTruth.swift` is the answer-key format shared
by all of them.

## Synthetic songs

`render` writes multi-instrument songs with known arrangement and sampler-command times for
notes and drum hits, plus the generator's beat, bar and chord grid. These labels describe the
render schedule; they are not measured acoustic onset or decay times in the WAV.

```
./build.sh render                  # -> .build/render
.build/render out                  # standard set: out/dev01...dev08, out/test01...test08 (.wav + .json)
.build/render out --only dev03     # one song of the set
.build/render out --count 20 --seed 7 --verbose   # 20 per split, another seed, per-part levels
```

- **Songs** (`SongGen.swift`): 8 styles (pop, rock, funk, ballad, waltz, jazz, edm, acoustic), each
  28-40 s: drums (or none / a light kit), bass, a chord part and a melody. Random key (major or
  minor), a progression per section from the style's list (sometimes 12-bar blues or two chords a
  bar), a form of intro / verse / chorus / one-bar ending, drum fills into choruses, and a
  phrase-based melody (call-and-answer motifs, chord tones on strong beats, cadences on long notes,
  louder and higher in the chorus). Timing, velocity and length are humanized. Jazz swings; 3 in 16
  songs drift in tempo by up to ±4 %. Dev and test use different seeds but the same style mix
  (every style once per 8 songs); half of each split goes through a reverb.
- **Deterministic arrangement**: a seed fixes the generated song (SplitMix64, no system RNG).
  Keep the renderer settings, sound-bank version and macOS environment fixed when comparing
  renders. A fixed seed alone does not guarantee byte-identical audio across environments.
- **Sound** (`Render.swift`): Apple's General MIDI bank that ships with macOS
  (`gs_instruments.dls`), one `AVAudioUnitSampler` per part in an offline `AVAudioEngine`. Drums
  use the percussion bank (MSB 120, program 0). The sampler takes the kit from the bank, not the
  MIDI channel (channels 0 and 9 sound identical), and channel 9 is used by convention. Output is
  mono 44.1 kHz 16-bit, normalized to -1 dBFS peak.
- **Scheduled timing**: audio is rendered in 64-frame slices (about 1.45 ms at 44.1 kHz).
  Each note-on/off command is sent before the slice its generated time falls in; the JSON
  records that slice start. Flooring alone moves a command earlier by less than one slice.
  The scheduler also clamps overlapping same-key releases to the next attack and drops
  notes whose quantized interval is empty; labels reflect those final scheduled events.
  Sampler latency and instrument attacks can move the audible onset later; release envelopes
  and reverb can continue after note-off. Previous isolated-note measurements reported small
  delays for many instruments and tens of milliseconds for slow pads. Those observations are
  environment-specific, not a correction applied to the labels. Measure alignment per bank,
  program and renderer environment before interpreting tight onset or acoustic-offset scores.
- **Mix**: each part is first rendered alone. That measures its level, so the parts sit at their
  intended balance (melody in front, drums and chords below, ±3 dB per song), and it fails the
  render if any part is silent.
- **Checks** (every render): duration 28-40 s; bass 28-55, chords 48-76, melody 60-88; melody
  strictly monophonic with at least 10 ms between notes; no key of one instrument held twice at
  once; chord spans contiguous; known chord qualities.
- **Ground truth notes**: chord spans are the written harmony, with repeated chords merged. Rock
  guitars play power chords (root, fifth, octave), so there the third of a `maj`/`min` chord is only
  in the melody. Beats and downbeats are the written grid, including swing and drift. Note times
  reflect the humanized, slice-quantized sampler schedule. `TruthNote.on` is the note-on command
  time, `TruthNote.off` is the key-release command time, and `TruthDrum.time` is the trigger time.
  None is an acoustic boundary annotation. Keep this distinction when adding offset metrics or
  comparing to real recordings; onset-only scores currently use the scheduled labels.

Rendering the standard set takes about 11 s on an M1 Pro.

## Scoring the any-instrument pipeline

`musicbench` runs the app's own transcription code on the rendered songs and scores every stage:

```
./build_bench.sh                                   # -> .build/musicbench (compiles the app sources)
.build/musicbench <songsDir> --set dev             # tune on dev only
.build/musicbench <songsDir> --set test            # held-out result
.build/musicbench <songsDir> --set dev --sweep notes|voices   # threshold / part-splitting sweeps
COMPARE="mix:0.7:0.4:90,tonal:0.6:0.4:90" .build/musicbench <songsDir> --set dev   # configs per song
HPSS="31,9" .build/musicbench ...                  # other separation kernels
```

Scoring (`Scoring.swift`, mir_eval conventions): notes match on pitch and onset within ±50 ms; parts
score the notes the app labelled melody / chords / bass against that part's truth; beats and bar lines
within ±70 ms; chords are the share of time with the right root and major/minor quality over each
chord segment. Beats are tracked from the notes and the audio's onsets, as in the app: the tonal
part's, plus the percussive part's on songs with a kit (percussive share over 0.1, at a weight that
rises to full at 0.2; marked in the song list with its weight; `OnsetEnvelope.music`) and, as Song
mode passes it, the tonal part's chroma, from which a 4/4 take's bar lines are decided again
(`BarPhase`); each song's line and the total also give the bar-pointer model's own bar lines on the
same beats. The "notes only" figure leaves the onsets out. Drums are not
scored: the app no longer transcribes them (October 2026). `scoreDrums` (kick, snare and hi-hat
onsets within ±50 ms) stays for the drum lab in `drums/`, which still builds the last drum
transcriber the app shipped (`drums/build_drumbench.sh`).

Onset matching now maximizes the number of one-to-one eligible pairs instead
of taking the nearest pair greedily. Note distances are rounded to four
decimals before the inclusive tolerance check, following
[mir_eval.transcription](https://mir-eval.readthedocs.io/latest/api/transcription.html).
Beat and drum distances use the unrounded inclusive event window. Ties are
deterministic, but do not promise minimum total timing error or a unique part
assignment. Text/JSON reports identify `maximum-cardinality-onset-v2`.

Sweeps are accepted only with `--set dev`; `--set test --sweep ...` and
`--set all --sweep ...` exit with status 2 before loading the model or songs.
Text and JSON reports label the selected set: `development`, `held_out`, or
`exploratory` (`all`). A held-out label records which split was evaluated; it
does not establish that a person has never tuned on that split. Freeze settings
on dev before reporting test scores.

Historical results from the original greedy scorer (not rerun with v2):
these values need recomputation on the same fixtures before comparison with
new scores. The table records prior tuning decisions, not validated v2 results.

| | dev | test |
|---|---|---|
| Notes, any part (old piano preset on the raw mix) | 0.722 | 0.672 |
| Notes, any part (app pipeline) | **0.755** | **0.698** |
| Melody / chords / bass part F1 | 0.850 / 0.606 / 0.740 | 0.789 / 0.545 / 0.582 |
| Notes put in the right part | 92% | 87% |
| Drums kick / snare / hi-hat F1 | 0.847 / 0.671 / 0.813 | 0.879 / 0.517 / 0.802 |
| Drum hits on drumless songs (also with room tone or silence around them) | 0 | 0 |
| Beats / bar lines F1 (with drum hits) | 0.926 / 0.942 | 0.861 / 0.746 |
| Beats / bar lines F1 (notes only) | 0.807 / 0.786 | 0.718 / 0.730 |
| Chords, root / major-minor | 0.739 / 0.675 | 0.765 / 0.694 |

- **Separation only when drums are prominent.** Transcribing the tonal part helped songs with a kit
  (rock, pop, funk: up to +0.07 F1) and hurt sparse ones (acoustic −0.08), because separation also
  softens plucked and struck attacks. The drum kit's share of the energy splits them cleanly: 11-24%
  vs 1-8%, so `MusicTranscriber` separates at ≥ 10% (`tonalPartAbove`).
- **Thresholds**: 0.70 / 0.40 / 90 ms on the raw mix, 0.60 / 0.40 / 90 ms on the tonal part
  (`NoteExtraction.Config.music`, `.musicTonal`).
- **Separation kernels** stay 17 frames × 17 bins: 31×9 helped the kick on the percussive part but
  cost pitched notes (0.755 → 0.714), and the drum transcriber reads the mix anyway.
- **Drums read the full mix** (`drums/`, `DrumTranscriber`, no longer in the app): more accurate than
  the percussive part, and only the mix lets it tell a drumless song (0 hits) from a kit.
- **Part splitting** keeps generic ranges (bass ≤ E3, melody ≥ A3): the sweep's best (melody ≥ C4)
  only matched the generator's own melody range.

Known weak spots: soft snare ghost notes, bass notes read as kicks in sparse ballads, pads with slow
attacks (EDM chords), and slow drumless songs whose beat reads at double tempo (the ½× button).
Synthetic GM songs are cleaner than real recordings, so expect lower numbers on real mixes.

## Scorer regression checks

Run `sh Tools/BugfixChecks/run.sh` from the repository root on a current Xcode
toolchain. The scorer harness compiles the real `Scoring.swift` and compares
its match counts and edge validity against committed fixtures generated by
`mir_eval 0.8.2`. This native harness was added on Linux and awaits execution.
Regenerate the reference fixtures with:

```sh
python3 Tools/BugfixChecks/generate_scoring_oracle.py
```

Only fixture generation requires `mir_eval==0.8.2` (and its NumPy/SciPy
dependencies); the app and CSV comparison CLI do not. The Python regressions
also test all 512 bipartite graphs with three nodes per side against exhaustive
search, randomized pitch/onset cases, and a 5,000-node augmenting path.
`Tools/PianoModel/compare.py` uses the same maximum-cardinality strategy while
retaining its separate strict `<30 ms`, unrounded, exact-pitch CSV contract.
That CSV tool now enforces note timing/velocity and optional sustain/frontend
limits under SEM-040; see [PianoModel/README.md](../PianoModel/README.md).

## Per-asset provenance (SEM-092)

`asset_registry.py` validates a version-1 JSON registry with an `assets` list.
Each entry has `asset_id`, normalized relative `path`, `kind`, lowercase
`sha256`, `source` (`uri`, `release`) and `rights` (`status`, `license`,
`terms_uri`, `attribution`, `permission_note`, `permitted_uses`).
Supported kinds are audio, song_truth, notes_csv, pedal_csv and other.
Rights status is `unknown` or `recorded`; uses are local_evaluation, ci,
redistribution and training. Unknown terms retain license `unknown` and no
permitted uses. Recorded terms require a license identifier or permission
note, and uses must be declared individually for every selected asset.

```sh
python3 Tools/MusicBench/asset_registry.py assets.json
python3 Tools/MusicBench/asset_registry.py assets.json --use ci
```

The first checks metadata and counts unknown records. The second rejects
an asset lacking a recorded CI permission. Both run offline with the standard
library; metadata validation does not verify file bytes. Registry records
are curator-supplied facts/claims: the tool does not infer rights from a URL
or supply missing consent, license text or attribution. Existing bundled
samples/model terms still need curation under SEM-108/023.

## Verified dataset manifests (SEM-034)

`dataset_manifest.py` verifies schema/version, source bytes, PCM WAV headers
and payload, label conventions/events/alignment, declared source groups,
derivative lineage and dev/test separation. It can also launch the existing
benchmark from a rehashed temporary snapshot and attach input provenance to
its report. Verification and launch-wrapper tests run without Apple frameworks.
See [DATASET_MANIFEST.md](DATASET_MANIFEST.md) for the complete format and commands.
