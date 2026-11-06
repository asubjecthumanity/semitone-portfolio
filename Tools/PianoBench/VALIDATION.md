# Validation evidence

## Fork integration and version 1.1 review — October 3, 2026

The original archive `Semitone_PianoBench.zip` was located and its actual 29
tests rerun successfully. Its SHA-256 is
`6f7eff857350ae0edc1fe22b99be5e657cd40b4334cfa229a90e2b5747b2ce3e`.
Source integration was checked against fork head
`9e05b487e06e5c179ac93f0d0678210b08f8a060`; no app/model assets were changed.

**Final checks:** 55 PianoBench pytest cases passed on Python 3.12.14, including
the original 29 and 26 new parameterized cases. The separate existing
BugfixChecks suite passed all 52 tests: **107 passing host tests total**.
The package installed in an isolated environment as version 1.1.0 and its
callable/CLI worked from outside the source directory. Python source parsing,
Bash syntax and whitespace checks passed.

New checks exercise changed inputs between preflight/copy and during a run,
original-file edits after snapshots, exact parsed manifest preservation,
source-audio identity remaining unknown on replay, receipt verification and
modified/missing outputs, relocation of saved runs, duplicate/nonfinite JSON,
boolean schemas/case-colliding IDs, audio header/pedal bounds, activation versus
velocity, extra CSV columns, cross-engine onset-only comparisons, command
artifact changes/timeouts, native artifact/build identities and build-source
changes. Native identity tests use small file fixtures/stub toolchain output;
they do not compile Swift or execute Core ML.

Two complete 32-case demo runs and one scoring replay used the final 1.1 code.
All cases completed; all five designed tiers were present. Artificial oracle
onset/offset macro F1 remained 1.0000; degraded onset F1 was 0.76907533 and
offset F1 0.76896951. Controls reported 0 versus 2.5 false notes/minute.
The original/replay input fingerprints, score configuration and every
per-piece score were identical. All three saved runs passed `verify-run`.
These are evidence that the tester/replay works, not real Semitone accuracy.

The new Basic Pitch branch uses actual app API signatures inspected at the
current head. Its Python dispatch/artifact contract and build-receipt helpers
were tested. **Mac compilation, native inference, physical microphone data
and a broad real-piano run remain unexecuted.** SEM-001 stays open as stated in
`ACCEPTANCE.md`. The historical validation below is retained as the original
delivery's record; its real SMD MIDI parser checks were not repeated here.

## Original delivery validation

Validated October 3, 2026 UTC on Linux with Python 3.12.14. Native integration
was inspected against `johenaught/Semitone_Jhog` commit
`dd8ad677694b25c718a2bf9cca62f916fb6edc81`.

## Completed checks

- **29 automated tests passed.** These cover maximum matching, the greedy
  repeated-note counterexample, duplicate-prediction penalties, inclusive and
  strict boundaries, duration tolerance, sustain/restrike behavior, unknown
  duration semantics, silence/false-positive rates, MIDI tempo/default-tempo
  handling, controllers, data hashes, split leakage, version comparisons,
  subprocess paths with spaces, official-data adapters, and JSON serialization.
- **1,000 randomized comparisons** within those tests agreed with `mir_eval`
  0.8.2 maximum-match counts: 250 examples × onset/onset-offset × inclusive/strict.
  Ambiguous maximum matchings are allowed to choose different individual pairs.
- **Two complete 32-case version runs** produced prediction files, JSON/CSV/
  Markdown reports, and a paired comparison. All five tiers were present and
  no cases failed. Artificial oracle predictions scored 1.0000 onset and
  onset/offset macro F1; intentionally degraded predictions scored 0.769075
  onset and 0.768970 onset/offset macro F1. Negative controls reported 0 versus
  2.5 false notes/minute. These numbers validate the tester, not Semitone.
- **Five real corrected SMD v2 MIDI files parsed successfully**, including
  separate sustain/soft controllers, with no parser warnings:

| SMD performance | Notes | Pedal spans | MIDI duration |
|---|---:|---:|---:|
| Bach BWV849-01 | 724 | 74 | 156.55 s |
| Chopin Op.10 No.4 | 2,202 | 128 | 131.06 s |
| Liszt Dante sonata | 12,698 | 560 | 1,036.05 s |
| Rachmaninoff Op.36-01 | 4,409 | 464 | 562.24 s |
| Ravel Jeux d'eau | 4,056 | 172 | 317.05 s |

- Scoring the 12,698-note Liszt reference against an identical event set gave
  **1.0 onset and onset/offset F1 in about 3.10 seconds** in this environment.
  This checks long-piece scoring and serialization; it is not inference speed.
- Python modules compiled, and `native/build.sh` passed Bash syntax checking.
- Native file loading was checked against the inspected view model: its
  refined file-import pass also calls `AudioFileLoader.loadMono` at 44.1 kHz.

The demo confidence intervals group tempo-tier variants into five original
schedule families; the melody and dynamics variants share a family. The
packaged reports therefore avoid pretending those derivatives are 30
independent compositions.

## Unverified parts and practical limits

This environment has no macOS Core ML/AVFoundation runtime or Xcode, so the
native runner was **not compiled or executed**. Its source list follows the
fork's existing PianoModel harness and calls the inspected APIs directly, but
the first Mac run must validate compilation, model loading, and engine output.
CPU/Neural Engine behavior should be measured on the hardware you actually use.

The sampled FluidSynth renderer path was not executed here; the original toy
renderer and all bundled toy fixtures were exercised. Real SMD audio, MAPS
audio, MAESTRO audio, and the current Semitone model were not transcribed here.
The SMD MIDI used for parser checking is not redistributed in the package.

Difficulty classification is a declared/reference-derived engineering
heuristic. It is not a calibrated music-exam grade or a guarantee of acoustic
difficulty. Dataset timestamps may contain residual physical delays; the
tester applies declared alignment and does not optimize it against predictions.
Cross-dataset title aliases and training exposure still require a provenance
audit. The evaluator assesses performance-note events; it does not claim to
assess engraved notation.

The native runner scores raw refined-piano output and reports the app validity
gate. It does not reproduce the app's quick-pass fallback or optional AI edits.
To test those stages, import their accepted/exported outputs on the same
frozen inputs and identify the stage in run metadata.

The included `examples/demo_reports` are labeled **DEMO_ORACLE** and
**DEMO_DEGRADED**. They contain no measured claim about the fork's accuracy.
