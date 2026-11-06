# SEM-001: tooling implemented; real-piano acceptance remains open

The function from the “Create Piano Accuracy Tester” conversation is the
foundation for rank 1. It is now in this fork as `pianobench.evaluate_version()`.
The original archive passed its 29 tests on recheck; version 1.1 adds snapshot,
provenance, dynamics and replay checks plus a Basic Pitch stage adapter.

| Original acceptance requirement | Present evidence | Remaining work |
|---|---|---|
| A pinned broad real-piano manifest | Dataset adapters, hashes, split grouping and declared semantics are implemented | Curate actual paired real recordings, including intended piano/mic conditions; audit groups, rights and alignment |
| Reproducible native predictions | Native adapters/build identity records exist; input/artifact drift is checked | Compile and run both engine stages on a compatible Mac with the actual model artifacts |
| Per-performance onset/offset results | JSON/CSV/Markdown and grouped summaries work; semantics control headline offset availability | Save real native outputs under a verified offset convention; keep unknown conventions diagnostic |
| Reproduction without private clip names or hand alignment | Every run preserves input bytes, replay manifest, predictions and integrity receipt; saved scoring replay is tested | Produce and retain a real-data evidence run; declared alignment must come from labels/independent measurement, not fitting to predictions |

The two 32-case demo runs use original toy tones and artificial oracle/degraded
predictions. They validate the tester, never the accuracy of Semitone. Source
inspection and host command/build-receipt checks do not establish native
compilation, Core ML inference or device behavior. SEM-001 must stay open until
its actual-data/native acceptance artifacts are available and reviewed.

To finish acceptance:

1. Prepare a reviewed real-data suite using the linked releases in `DATASETS.md`
   and independently paired microphone recordings. Keep development/test
   grouping separate and record the intended difficulty/recording coverage.
   Toy diagnostics can supplement simple/negative cases but cannot stand in
   for real piano. The tier labels are engineering complexity, not pianist grades.
2. Build `native/build.sh` on a Mac. Freeze commit/configuration and model/weight
   identities. Run Transkun and the fixed piano-preset Basic Pitch stage on the
   same suite; record their compute profiles and stage differences.
3. Confirm checkpoint/output offset semantics before requesting headline
   duration scores. Use `compare --onset-only` if conventions differ; do not
   invent an offset convention merely to obtain a duration delta.
4. Keep all outputs, `input_manifest.json`, `replay_manifest.json`, per-piece
   results and `run_integrity.json`. Run `verify-run`, then score the saved
   canonical outputs from `replay_manifest.json` in a new directory. Input
   fingerprints/counts and per-piece metrics must agree under the same scorer.
5. Review failures, missing tiers, real/synthetic separation, source identity,
   independent groups and native validity decisions. A valid checksum receipt
   is an integrity result; it cannot certify fabricated or mislabeled evidence.

The current native stages are raw refined output and fixed-preset quick output.
Capture, auto/custom presets, fallback, AI cleanup and MIDI export need their
own accepted-output manifests before claims about those stages. No recorded
F1 from the demos should be copied into an app accuracy claim.
