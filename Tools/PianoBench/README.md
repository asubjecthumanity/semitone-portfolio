# Semitone PianoBench

A working, headless piano transcription evaluator for `johenaught/Semitone_Jhog`.
The public function is **`evaluate_version(...)`**. It runs a transcription
function or reads saved predictions, compares every case with performance MIDI,
and writes scores and error diagnostics. No interface is included.

The integration was inspected against fork commit
`dd8ad677694b25c718a2bf9cca62f916fb6edc81` on October 3, 2026 UTC. The native
runner builds the **actual checked-out Swift piano sources**, so rebuilding it
evaluates the version of the fork you currently have.

The October 3 integration review also checked the current fork at
`9e05b487e06e5c179ac93f0d0678210b08f8a060`. Version 1.1 adds verified run
snapshots/replay, saved-output identity checks and a Basic Pitch adapter.
See [SEM-001 acceptance status](ACCEPTANCE.md): portable tooling is implemented;
actual native compilation and a broad real-piano accuracy run remain pending.

## What is included

- Five difficulty tiers and 30 original diagnostic piano schedules, plus silence
  and noise controls. Generate the toy WAV/MIDI fixtures with the `fixtures` command; data files are not committed.
- Local-release adapters for MAESTRO v3, corrected SMD v2, MAPS, and your own
  paired piano WAV/performance-MIDI recordings.
- A Swift command-line runner linking Semitone's own audio loader, Transkun
  feature extractor, Core ML backbone, decoder, and segment stitcher.
- Import of MIDI, JSON, and the existing PianoModel harness's note CSV.
- Optimal one-to-one note matching, onset and duration scores, binary pedal
  scores, velocity errors, quiet/short/range/restrike slices, timing residuals,
  and ten-second complexity windows.
- JSON, CSV, and Markdown reports; paired comparisons of two versions;
  confidence intervals grouped by composition/performance; optional regression gates.
- Tests of matching, MIDI timing, sustain semantics, failure penalties, data
  identity, and report generation. `mir_eval` is needed only for reference tests.

## Install

`Tools/PianoBench` is included in the fork. You can also use the Python portion
as a standalone package. Third-party datasets and generated diagnostics stay
outside source control.

From `Tools/PianoBench`, on Linux or macOS with Python 3.11 or newer:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e '.[test]'
python -m pytest -q
python -m pianobench --help
```

From the repository root with those dependencies installed, the tests also run
as `python -m pytest Tools/PianoBench/tests -q`. The package's pytest configuration
resolves its source directory.

On Windows, activate with `.venv\Scripts\Activate.ps1` in PowerShell and use
`python` for the remaining commands. The scorer runs on Windows/Linux/macOS;
the native Apple engine requires macOS/Xcode. No GPU, PyTorch, training, or
model downloads are required to score saved outputs.

`requirements-tested.txt` records the Python dependency versions used during
validation. The normal package accepts compatible NumPy/SciPy versions and
records the actual environment in every report.

## Check that the tester works

```bash
python -m pianobench demo data/demo
```

This generates the 32-case suite, an oracle output, deliberately degraded
outputs, two reports, and a paired comparison. The oracle should score 100%
onset/duration F1 with zero false notes. The degraded output should score lower
and produce false notes on the controls. **These are tests of the tester,
not measured Semitone accuracy.**

Generate a reusable suite with:

```bash
python -m pianobench fixtures data/diagnostics
```

Its manifest is `data/diagnostics/manifest.json`.

Toy tones are original additive harmonics. They exercise the complete file,
prediction, scoring, and report path, but are not realistic piano recordings.
Use real paired data and/or a sampled piano renderer for acoustic conclusions.

## Run the actual Semitone piano engine on a Mac

Use a Mac with Xcode and a Swift toolchain compatible with the fork. The builder
uses the source list and framework dependencies from its existing PianoModel
harness. From `Tools/PianoBench`:

```bash
bash native/build.sh /absolute/path/to/Semitone_Jhog

python -m pianobench run data/diagnostics/manifest.json \
  --native .build/pianobench-native \
  --model .build/TranskunBackbone.mlmodelc \
  --weights /absolute/path/to/Semitone_Jhog/Semitone/TranskunWeights.bin \
  --compute ane \
  --version transkun-refined \
  --output runs/transkun-toy
```

The build records commit, working-tree status, Swift version, and source
hashes. The run records executable, model, and weights hashes. Rebuild after
editing the fork. Use a new output directory for each run; the evaluator refuses
to overwrite a completed run or silently reuse predictions.

The runner uses the app's 44.1 kHz mono file-loading policy for its refined
piano pass. It emits notes and CC64 sustain spans. The inspected API does not
expose CC67 soft-pedal spans, so that capability is reported as unsupported.

**This runner evaluates raw `PianoTranscriber` output.** It reports the app's
`looksValid` decision but does not invoke the Basic Pitch fallback, microphone
capture, optional AI cleanup, beat quantization, playback, or MIDI export.
For a final accepted-output or exported-MIDI benchmark, use predictions from
that stage through the same Python evaluator and record the stage in
`version_metadata`.

### Compare the quick Basic Pitch stage

The builder also compiles `NMP.mlpackage`. The same evaluator and input suite
can invoke the fork's `BasicPitchModel`, `TranscriptionEngine` and
`NoteExtraction` with the explicit fixed **piano** preset:

```bash
python -m pianobench run suites/smd-v2-test.json \
  --native .build/pianobench-native --engine basic-pitch \
  --model .build/NMP.mlmodelc --version basic-pitch-piano \
  --output runs/basic-pitch-piano
```

It uses the app's 22.05 kHz mono loading policy and Core ML default compute
configuration; `--compute` selects only the Transkun profile. Basic Pitch
activation is recorded as activation, not MIDI velocity; no pedal capability
or duration convention is inferred. Automatic/custom presets and final app
fallback are separate stages. The Swift branch is source-inspected and its
Python command/artifact contract is tested, but compilation/inference on a Mac
remain unrun. With different declared duration conventions, use `compare
--onset-only`; duration deltas remain unavailable rather than forcing a false
shared convention.

`--compute ane` follows the inspected default CPU/Neural Engine policy. CPU
mode is available for experiments, but the fork documents numerical failures
for its shipped mixed-precision model on a CPU path. A failed validity check
remains visible; it is not silently converted into a successful transcription.
Native compilation and model execution were **not** performed in the Linux
validation environment; see `VALIDATION.md` for exactly what was checked.

### Declare duration semantics

The native runner defaults to `unspecified`, which gives reliable onset
scoring and diagnostic duration views, but withholds headline offset F1.
After confirming the exact checkpoint's label convention, add:

```bash
--prediction-offset-semantics key_release
```

The upstream Transkun README describes its pip checkpoint as trained without
pedal extension. The fork's inspected artifact documentation does not supply
a checkpoint hash establishing that lineage, so this tester does not silently
assign that convention to every artifact named `TranskunBackbone`.

For outputs already extended by sustain, declare `pedal_extended` instead.
References retain their original key-release labels. The scorer derives a
separate sustain-extended view and caps extensions at the next attack on the
same key. This is a binary MIDI-controller target, not an estimate of audible
decay or half-pedal resonance.

## Add real piano datasets

Download data from the original project/release links in `DATASETS.md`, then
build a small frozen manifest. Large third-party datasets are not bundled.
Use paired audio and **performance** MIDI. Score MIDI alone is not a timing
reference for a rubato performance.

### SMD v2: practical real-piano starting set

```bash
python -m pianobench prepare-smd /data/SMD-piano_v2 \
  suites/smd-v2-test.json --limit 25
```

This matches original WAV files with corrected performance MIDI by basename,
excludes directories containing synthesized MIDI audio, and prefers the
original higher-rate/stereo view when a mono duplicate is present. Use one
v2 release root; ambiguous MIDI versions cause an error. Composition groups
keep alternate performances together. SMD retains physical Disklavier/acoustic
delay uncertainty, despite correction of its historical global offsets.

### MAESTRO v3: broad concert-piano coverage

```bash
python -m pianobench prepare-maestro /data/maestro-v3.0.0 \
  suites/maestro-v3-test.json --split test --limit 25
```

The root must contain the official `maestro-v3.0.0.csv` and paired files.
The adapter preserves its official split and canonical composition grouping.
Missing local files are recorded; MIDI-only downloads cannot form audio cases.
`--limit 0` includes all available pairs. `--unbalanced` disables round-robin
selection across available tiers. Subset selection uses reference information,
never prediction accuracy.

### MAPS: range, polyphony, and piano-setting comparisons

```bash
python -m pianobench prepare-maps /data/MAPS \
  suites/maps-test.json --limit 40
```

Real `ENSTDkCl`/`ENSTDkAm` recordings and sampled renders are labeled separately.
Pieces repeated across piano settings share composition groups. The chosen
`test` label is your evaluation designation, not an invented official MAPS split.

### Your own paired recordings

```bash
python -m pianobench prepare-pairs /data/my-paired-piano \
  suites/my-piano-test.json --limit 0
```

Match `.wav` and `.mid`/`.midi` basenames. The command hashes the files and
records actual audio duration, but marks custom alignment `unverified`.
Measure MIDI/audio alignment independently, then update each manifest entry's
`alignment` with `status: "verified"`, a measured `offset_seconds`, and its
basis. Positive offsets mean a MIDI onset belongs later on the audio timeline.
For preliminary analysis, `--allow-unverified` permits an explicitly marked
exploratory run. The tester never fits a lag or drift to a model's predictions.

### Combine simple diagnostics and demanding recordings

```bash
python -m pianobench combine \
  data/diagnostics/manifest.json suites/smd-v2-test.json \
  suites/maestro-v3-test.json --output suites/combined.json
```

Run this manifest through the native command above, substituting
`suites/combined.json`. Inspect the real-recording, dataset, and split summaries
separately. A combined/subset score is not a complete official benchmark score.
For development, use validation files; freeze held-out test material before
tuning. Derivatives, alternate renderings, and repeated compositions should
retain the same group ID. Cross-dataset composition aliases require a manual
grouping audit; differing expressive MIDI files cannot prove two titles are
different compositions.

Many pretrained models have seen MAESTRO during training. MAESTRO evaluation
alone does not establish performance on unseen pianos, microphones, or rooms.

## Five levels

| Tier | Intended coverage | Typical material |
|---:|---|---|
| 1 | Very simple | Isolated notes, slow single-line melody, rests |
| 2 | Simple two-hand music | Slow bass/melody, dyads and small chords |
| 3 | Intermediate | Arpeggios, independent notes, wider polyphony |
| 4 | Advanced | Faster textures, repeated attacks, larger chords, quiet notes |
| 5 | Exceptionally complex | Very fast runs/restrikes, dense chords, concert repertoire |

For public data, the default automatic tier is the maximum of three
reference-only criteria: 95th-percentile attack density in one-second windows,
largest attack group within 35 ms, and time-weighted 95th-percentile active
note count. Tier boundaries are `[2,4,8,14]` attacks/sec, `[1,3,5,7]` chord notes,
and `[1,3,5,8]` concurrent notes. These are frozen engineering heuristics,
**not validated pianist grades**. An unusually dense short passage can raise
a piece's tier. You may assign a reviewed `difficulty_level` in the manifest;
record the reason in `difficulty_source` before comparing versions.

Original fixtures use designed diagnostic tiers and also retain computed
complexity. Their six patterns cover melody, chords, repeated strikes, dynamic
contrast, sustain/soft-pedal scheduling, and full-range/segment-boundary cases.
The JSON report additionally scores ten-second passages by computed complexity.
Those passage counts use global matching, avoiding note truncation at window
boundaries; silent passages' extra notes still count in the whole-piece score.

SMD's repertoire includes useful demanding material such as Chopin Op.10 No.4,
Liszt's Dante sonata, Rachmaninoff Sonata Op.36, and Ravel's *Jeux d'eau*. Their
performance MIDI was used to exercise the parser here; their audio was not
transcribed in this validation environment.

## What the scores mean

| Output | Meaning |
|---|---|
| Onset precision | Fraction of predicted notes matched to real attacks |
| Onset recall | Fraction of reference attacks found |
| Onset F1 | Balance of precision and recall; primary acoustic headline |
| Onset/offset F1 | Also requires the correct duration under compatible semantics |
| Pitch activity F1 | Exact time-weighted overlap of active pitches, with duplicates unioned |
| 10/25/50/100 ms sweep | Sensitivity to tighter/looser timing tolerance |
| Timing residuals | Error/bias/drift on matched attacks; conditioned on successful matches |
| MIDI velocity error | Dynamics error where values are declared actual MIDI velocity |
| CC64 / CC67 scores | Pedal-event matches and time spent correctly down |
| No-note controls | False notes per minute, rather than inflated silent-file note F1 |
| Range/quiet/short/restrike slices | Reference-note recall for localized weaknesses |
| Runtime / real-time factor | Measured run cost; imported outputs without timing have no speed claim |

The normal rules are 50 ms onset tolerance, 50 cents pitch tolerance, and
offset tolerance `max(50 ms, 20% of reference duration)`. With integer MIDI
pitches, 50 cents requires the same key. Matching is maximum cardinality on a
sparse bipartite graph, not nearest-first greedy pairing. Distance rounding
to four decimals and inclusive/strict thresholds follow the reference
`mir_eval` matcher; randomized tests verify match counts under normal rules.

An onset score of 0.95 does **not** mean 95% of an engraved score is correct.
The evaluator measures performance events. Notation, spelling, staff/voice
assignment, written rhythm, and score layout require separately annotated targets.

Macro F1 gives each positive performance equal weight. Micro F1 pools note
counts, so long/dense pieces contribute more. An additional tier-balanced
mean weights only present tiers equally and explicitly reports missing tiers.
Negative controls are excluded from note F1. Missing or failed predictions
give zero recall for positive cases, preventing success-only reporting.
Failed negative cases are listed and excluded from the false-notes-per-minute
denominator; a crash cannot masquerade as a successful silent result.

Possible octave/semitone errors and merged restrikes are diagnostic hypotheses,
not proof of the internal cause. Maximum matching can have multiple valid
solutions, so timing/velocity statistics for ambiguous same-key notes may
depend on the chosen maximum matching.

## Use the function directly

```python
from pianobench import evaluate_version, NativeRunner, compare_runs

runner = NativeRunner(
    executable=".build/pianobench-native",
    model=".build/TranskunBackbone.mlmodelc",
    weights="../../Semitone/TranskunWeights.bin",
    compute="ane",
    offset_semantics="unspecified",  # declare key_release after checkpoint verification
)
report = evaluate_version(
    "suites/smd-v2-test.json",
    version="commit-and-config-name",
    output_dir="runs/version-1",
    transcriber=runner,
)
print(report["summary"]["onset"]["macro_f1"])
```

Your own `transcriber(audio_path)` function can return a `Performance` containing
`Note(onset, offset, pitch, velocity)` objects, pedal spans, duration, semantics,
and provenance. `evaluate_performance(reference, prediction)` scores one pair.
`examples/evaluate_exports.py` demonstrates scoring a directory of saved outputs.

### Saved JSON, MIDI, or CSV outputs

```bash
python -m pianobench run suites/smd-v2-test.json \
  --predictions /data/predictions/version-1 \
  --prediction-offset-semantics key_release \
  --version version-1-exported-midi --output runs/version-1
```

Each file must be named `<manifest-piece-id>.json`, `.mid`, `.midi`, or `.csv`.
Exactly one format per ID is allowed. MIDI decoding respects tempo changes and
default tempo, skips percussion channel 10, treats zero-velocity note-ons as
note-offs, and preserves separate sustain/soft-pedal spans. Type-2, SMPTE,
unterminated-note, nonfinite, and invalid-interval input is rejected.

Existing `Tools/PianoModel` harness CSV has `onset,offset,pitch,velocity` without
a header. `read_csv(path, sustain_path=...)` can load its separate sustain CSV.
No confidence is inferred from velocity or Basic Pitch activation.
Extra CSV columns are rejected; the supported note contract is exactly three
or four fields. Duplicate keys, nonfinite JSON numbers (including overflow),
boolean schema versions and case-colliding case IDs are rejected.

JSON `velocity`/`velocity_midi` fields use MIDI units. A legacy `amplitude`
field is converted only when `metadata.velocity_semantics` explicitly declares
`normalized_midi_velocity`; that opt-in describes the amplitude field.
An unspecified or activation amplitude does not create a velocity value/score.

For JSON, use this minimal contract:

```json
{
  "schema_version": 1,
  "duration_seconds": 3.0,
  "offset_semantics": "key_release",
  "notes": [{"onset": 0.5, "offset": 1.0, "pitch": 60, "velocity": 72}],
  "pedals": [{"onset": 0.7, "offset": 1.3, "controller": 64}],
  "pedal_controllers": [64],
  "metadata": {"velocity_semantics": "midi_velocity", "stage": "accepted-piano"}
}
```

Include the actual `metadata.audio_sha256` when available. A mismatched hash
fails the case. Imports without hashes remain usable but are explicitly
reported as lacking source-audio identity verification.
Saving a canonical prediction records `evaluation_audio_sha256` separately from
its producer's `audio_sha256`; replay does not turn an unverified association
into a verified one. Older 1.0 canonical exports may already have rebound an
unknown association: use original producer outputs for new evidentiary runs.

A generic executable can be used with `--command-argv` containing a JSON array
of arguments and `{audio}`/`{output}` placeholders. The adapter uses no shell.
It enforces a per-file timeout and records failures. An upstream Python model
can serve as a comparator, but its result is not the native Swift fork's result.

## Compare versions and gate regressions

Run the same frozen manifest after rebuilding the second version, then:

```bash
python -m pianobench compare runs/version-1/report.json \
  runs/version-2/report.json --output runs/comparison.json \
  --fail-regression 0.005
```

A positive delta means version 2 improved. `0.005` allows a 0.5 percentage-point
onset macro-F1 decline. This gate is a user-chosen engineering threshold, not a
statistical-significance assertion. The comparison refuses changed datasets,
alignment, score configuration, scorer source, or declared offset conventions.
It reports paired per-piece/per-tier deltas and group-bootstrap 95% intervals.
Intervals are unavailable with fewer than two independent declared groups.

For different/unknown engine duration conventions, add `--onset-only` to
compare just attacks. The JSON lists `compared_metrics: ["onset"]` and contains
no duration delta. Dataset, label alignment, scorer source and tolerance
identity still must agree. Default comparisons continue to require compatible
duration conventions.

`run --min-onset-f1 0.90` is an optional absolute gate. Exit codes are 0 for a
completed passing run, 2 for invalid input/setup, and 3 for failed transcription
cases or a requested accuracy/regression gate failure.

Each run produces `report.json` with detailed diagnostics, `pieces.csv` for
spreadsheet analysis, `report.md` for reading, standardized prediction JSON,
a manifest copy, a relative-path replay manifest, input snapshots and a per-file
progress checkpoint. The checkpoint preserves
completed expensive results if the process stops; automatic resume is not
implemented, to avoid mixing stale outputs across changed versions.

## Verify and reproduce saved runs

Before any transcriber runs, the evaluator copies selected audio/labels into
`inputs/<id>/`, rehashes them against the preflight and preserves the exact
parsed manifest bytes. This needs disk space for one selected-input copy per
run; begin with a small frozen subset. The runner receives the frozen audio,
so editing original files later does not silently change the experiment.
Changed snapshots, tester sources or recorded runner artifacts invalidate the
run. Fixed command-file arguments, executable, native model/weights and build
receipt are recorded/checkable identities. The native builder captures source
and input artifact hashes before compilation and checks them again before
writing its binary/compiled-model receipt. This does not establish a model's
training provenance or validate Swift/Core ML execution.

`run_integrity.json` is written after reports are complete. It covers the
reports, manifests, input copies and predictions. Imported producer bytes are
retained separately from canonical output. Run verification and scoring replay
work without macOS or iOS:

```bash
python -m pianobench verify-run runs/version-1
python -m pianobench run runs/version-1/replay_manifest.json \
  --predictions runs/version-1/predictions \
  --version version-1-scoring-replay --output runs/version-1-replay
```

You can move the whole run folder: the replay manifest uses relative paths.
Verification checks saved bytes, event/input contracts and identity; it does
not authenticate curator claims, regenerate native predictions or establish
that synthetic/oracle output measures Semitone. Failed native/prediction cases
are still penalized and reported; a valid receipt can contain failed cases.

## Primary references

- [mir_eval transcription rules and matching](https://mir-eval.readthedocs.io/latest/api/transcription.html)
- [Mido MIDI file timing](https://mido.readthedocs.io/en/stable/files/midi.html)
- [MAESTRO v3](https://magenta.withgoogle.com/datasets/maestro)
- [SMD corrected v2](https://www.audiolabs-erlangen.de/resources/MIR/SMD/midi)
- [MAPS](https://adasp.telecom-paris.fr/resources/2010-07-08-maps-database/)
- [Transkun model/label documentation](https://github.com/Yujia-Yan/Transkun)
- [Inspected fork](https://github.com/johenaught/Semitone_Jhog/tree/dd8ad677694b25c718a2bf9cca62f916fb6edc81)

Implementation priorities follow the supplied `Semitone_Jhog_Master_Improvement_Backlog(1).md`,
particularly SEM-001, SEM-002, SEM-003, SEM-034, SEM-035, SEM-037, SEM-089, and SEM-093.
