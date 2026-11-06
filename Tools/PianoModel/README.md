# Piano model (Transkun v2) — regeneration and verification

The app's high-accuracy piano pass is a Swift port of [Transkun](https://github.com/Yujia-Yan/Transkun)
v2 (Yujia Yan, MIT license). Two generated files ship in the app:

| File | Made by | What it is |
|---|---|---|
| `Semitone/TranskunBackbone.mlpackage` | `convert_backbone.py` | transformer backbone, Core ML (30 MB): fp16 except the last layer, run on the Neural Engine |
| `Semitone/TranskunWeights.bin` | `export_assets.py` | FFT windows, mel filterbank, interval scorer, velocity/timing heads (float32, fixed order) |

Everything else (features, semi-CRF decode, heads, 16 s segment stitching) is Swift in
`Semitone/Transcription/Piano/`.

## Precision and compute units

The backbone is fp16 except its final ConvTranspose1d (`upConv1dSkip`), which stays fp32, and it runs with
`.cpuAndNeuralEngine` (`PianoTranscriber`'s default; Core ML puts that one fp32 layer on the CPU).
Measured 2026-09-22 on iPhone 17 / iOS 27, Debug build, first 60 s of clip 3 (onset F1 vs. MIDI):

| Setup | Time for 60 s of audio | F1 |
|---|---|---|
| **fp16 + fp32 last layer, Neural Engine (shipping)** | **4.1 s** (9.5 s the first time: one-time Neural Engine compile) | **0.999**, same notes as fp32 |
| fp32, CPU only | 37.5 s | 0.999 (bit-identical to PyTorch) |
| all fp16, Neural Engine | 9.1 s | 0.879 |
| all fp16, CPU only | 27.6 s | 0.005 (garbage) |
| shipping model forced onto the CPU | 5.0 s | garbage (10,192 one-frame notes) |
| fp32 with the GPU | — | aborts the app (see below); fp16 on the GPU gave no result in 4 min |

- **GPU:** on iOS 27 Core ML's GPU path aborts the app inside MPSGraph while compiling the fp32 model
  (`MTLReportFailure` in `applyOptimizationPasses`). It can't be caught, so the GPU is never used.
- **Why the last layer:** with every other op type kept fp32 in turn, only `conv_transpose` mattered on the
  Neural Engine (mean output error 8.6e-2 → 4.8e-3); on clip 3 the mixed model gives the fp32 note list
  (1,293/1,293).
- **iPhone CPU in fp16 is broken** for this model (output collapses to one-frame notes on every key). If iOS ever
  falls back from the Neural Engine to the CPU, `PianoTranscriber.looksValid` rejects that output and the app
  keeps the quick transcription instead of showing garbage. The fp32 package (convert with `FLOAT32`) is the
  exact, 9× slower alternative.

The decoder's Viterbi and the feature log/scatter run on vDSP, so a Debug build (`-Onone`) is about as fast
as Release (the plain-Swift loops were 40× slower unoptimized).

## Verify the port against PyTorch

```
cp harness.swift main.swift      # swiftc only allows top-level code in main.swift
swiftc -O -Xcc -DACCELERATE_NEW_LAPACK -o harness main.swift \
  ../../Semitone/Transcription/Piano/*.swift ../../Semitone/Transcription/NoteEvent.swift \
  ../../Semitone/Transcription/BPConstants.swift ../../Semitone/Audio/AudioFileLoader.swift \
  -framework CoreML -framework AVFoundation -framework Accelerate
xcrun coremlcompiler compile ../../Semitone/TranskunBackbone.mlpackage .
./harness "<audio>" TranskunBackbone.mlmodelc ../../Semitone/TranskunWeights.bin clip   # writes clip_samples.f32, clip_swift.csv
python reference.py clip          # PyTorch Transkun on the identical samples -> clip_python.csv
python compare.py clip_python.csv clip_swift.csv
```

`compare.py ... --json` prints the same counts and differences as JSON. Two
empty files are a valid silence comparison (exit 0); unmatched notes, including
one empty file or zero matches, return exit 1. Invalid input returns exit 2.
When no notes match, difference statistics are `null`, not zero or NaN.
The host CSV boundary rejects non-finite/negative/reversed/zero-length times,
non-integer or unsupported piano pitches (21–108), and velocities outside
integer MIDI units 0–127. Errors identify the file and line and return 2.
Polyphony and same-key overlaps are retained. `event_contracts.py` exposes
the same checks for callers with a declared duration/overlap policy; it does
not sanitize values or replace native app-boundary validation (SEM-046).
An exit of 0 means all enabled parity gates passed. Matching maximizes eligible
one-to-one pairs. JSON identifies policy `note-sustain-features-v1`.
Default note limits are exact pitch, strict onset error <30 ms, inclusive
offset error <=5 ms, velocity error <=1 MIDI unit and no unmatched notes.
Offset/velocity constraints participate in matching so an ambiguous repeated
note can be reassigned; independent maximum pairings for each field alone
cannot establish joint parity. Inclusive offset/pedal limits allow 1 ps for
binary-float roundoff; zero limits remain exact. The default limits are
explicit tool policies, not measured guarantees for every compute profile.

```sh
python3 Tools/PianoModel/compare.py clip_python.csv clip_swift.csv --json \
  --python-sustain clip_python_sustain.csv --swift-sustain clip_sustain.csv \
  --require-sustain
```

`reference.py clip` now emits both note and sustain CSVs. It matches the app's
hard-stop policy: starts at/after audio end are discarded and ends are capped
at the audio end. Negative starts/invalid events are rejected, not shifted
into agreement. Soft pedal remains outside the app/harness output (SEM-030).

Use `--onset-tolerance-ms`, `--offset-tolerance-ms`, `--velocity-tolerance`,
`--pedal-tolerance-ms` to declare a calibrated profile. `--max-unmatched-python`
and `--max-unmatched-swift` default to zero; an explicit allowance does not
waive offset/velocity errors on otherwise onset-matchable notes. `--onset-only`
explicitly disables the note offset/velocity gates for legacy diagnostics.
That scope is recorded in JSON and is not full note parity. Pedal comparison
requires both sustain files and checks counts plus both interval endpoints.

Frontend checks use little-endian `.f32` vectors:

```sh
python3 Tools/PianoModel/compare.py clip_python.csv clip_swift.csv --json \
  --python-features clip_feat0_python.f32 --swift-features clip_feat0.f32 \
  --require-features --feature-max-abs 0.00002 --feature-mean-abs 0.00001
```

Sizes must agree and be nonzero; features must be finite and complete Float32
values. Both maximum and mean absolute errors must pass. `reference.py clip 0`
now writes `clip_feat0_python.f32`, prints the same structured feature check,
and exits 1 if the feature limits fail. Note/feature parity tools themselves
use the standard library; producing PyTorch reference output still requires
the model/dependencies described above. The model-producing invocation was
not run while adding these portable checks.

JSON records `passed`, failure names, gate-matched count, configured limits,
diagnostic pairing and whether sustain/features were actually checked.
Omitted auxiliary files are explicitly unchecked; `--require-sustain` and
`--require-features` enforce their presence. Failed gates exit 1; malformed
input/policy exits 2; silence remains valid for notes/empty pedal intervals.
An empty feature vector cannot establish frontend parity. These checks compare
implementations and do not replace an accuracy benchmark against true notes.

Result on 2026-09-22 (fp32 package): identical note lists on both reference clips (35/35 and 1,293/1,293;
onsets within 1 µs, velocities 100% equal). `DUMP_SEGMENT=k ./harness ...` plus
`python reference.py clip k` compares one segment's features (max diff 1.6e-5).

The decoder also reads the two pedal symbols (sustain −64, soft −67) exactly as Transkun does; the sustain
spans are returned for playback. On the first 60 s of clip 3 the Swift port finds the same 26 sustain presses
as PyTorch (timing within 0.005 ms). The harness writes them to `<prefix>_sustain.csv`.

Accuracy vs. ground truth (`semitone training/`, onset F1, 50 ms): clip 1 1.000; clip 3 "trusted" set
0.971 (Basic Pitch: 0.904 / 0.845). Clip 3's MIDI has no tempo — use the aligned JSONs there.
