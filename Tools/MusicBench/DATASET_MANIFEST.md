# Version-1 benchmark inputs

`dataset_manifest.py` adds a portable verified-input path around MusicBench.
It runs offline with the Python standard library (Python 3.9 or newer).

```sh
# Validate bytes/headers/events/metadata without starting native inference.
python3 Tools/MusicBench/dataset_manifest.py dataset/manifest.json --set dev

# Optional native launch after the portable preflight.
python3 Tools/MusicBench/dataset_manifest.py dataset/manifest.json --set test \
  --bench Tools/MusicBench/.build/musicbench --json results.json
```

The first command is entirely portable. The second needs the existing native
binary and its models on macOS. Its transport/preflight is tested with a stub
child process; actual native inference was not run when this tool was added.
The original direct MusicBench CLI remains available and bypasses this wrapper.

## Required data

The root JSON has integer `schema_version: 1`, stable `dataset_id`, nonempty
`dataset_version`, `assets`, and a nonempty `performances` list. JSON duplicate
keys and non-finite numbers are rejected. Assets use the registry described
in the main README; audio and annotations have separate rights/source/hash
records. Compute hashes from the actual immutable file bytes with, for example,
`sha256sum dataset/dev01.wav dataset/dev01.json`.

Each performance declares:

| Field | Meaning |
|---|---|
| `performance_id` | Unique recording/render ID |
| `composition_id` | Underlying musical work/arrangement ID |
| `session_id` | Source recording/performance-session group |
| `lineage_id` | Original performance group before derivatives |
| `parent_performance_id` | Null for an original; existing performance ID for a derivative |
| `split` | `dev` or `test` |
| `audio_asset`, `truth_asset` | Registered asset IDs |
| `instruments`, `microphone` | Nonempty instrument list and declared capture context; use an explicit `unknown`/`not_applicable_synthetic` value where appropriate |
| `transforms` | List of `{name, parameters}` objects; a derivative must declare its transforms |
| `audio` | Positive integer `sample_rate`, `channels`, `frames` matching the PCM WAV header/payload |
| `annotation` | Format, timing semantics, source URI, alignment and supported pitch range |

A parent must resolve and be acyclic. Derivatives retain the source composition,
session and lineage IDs; renderer/bank/environment changes can be recorded in
transform parameters. These group IDs and exact audio hashes cannot cross
dev/test splits. Checks use the declared metadata; they do not infer whether
two differently named performances are really the same musical work. Human
dataset curation and composition deduplication remain necessary (SEM-093).

The annotation object requires:

```json
{
  "format": "song_truth_v1",
  "source_uri": "generated:MusicBench-seed-7",
  "onset": "sampler_note_on",
  "offset": "key_release",
  "timing_offset_seconds": 0,
  "pitch_min": 21,
  "pitch_max": 108
}
```

The example describes the contract, not the provenance of an existing song.
Declare the actual source. `format` can also be `note_csv_v1` with the same
start,end,pitch,velocity format used by PianoModel. Onsets can be
`sampler_note_on`, `acoustic_onset`, or `reference_midi`; offsets can be
`key_release` or `acoustic_end`. Positive alignment means
`audio_time = label_time + timing_offset_seconds`. Verification checks mapped
events against audio duration with a one-sample end-boundary tolerance.

For SongTruth, required native fields, event bounds, dynamics, programs, drum
triggers, beats, chords and duration are checked. A silent recording with no
notes is valid; zero-frame files are not evaluation performances. Version 1
supports PCM WAV, not FLAC/MP3/IEEE-float WAV. Conversion of another format is
a dataset derivative with its own hash and declared transform/alignment.

## Launch and report behavior

The CLI validates metadata for all splits (including declared leakage), then
checks selected assets' recorded use, SHA-256, actual WAV payload and labels.
By default `--use local_evaluation` is required for each selected input;
`--use ci` is available for CI fixtures. Unknown records remain visible through
the registry but cannot satisfy a requested use. Unselected asset bytes are
not needed to verify the selected split.

The native launch accepts only zero-offset, scheduled `song_truth_v1` labels:
the existing benchmark does not consume acoustic/CSV or shifted labels.
Song names must start with their declared split and be unique. Selected WAVs
and truth JSONs are copied to a temporary snapshot, then hashed again. The
manifest and unrelated JSONs are excluded, including under `--set all`.
The snapshot and executable are rechecked after a successful child run.

The wrapper appends `verified_dataset` to the native JSON report: manifest and
binary digests, dataset version, per-performance audio/label hashes, label
semantics, group/parent IDs, transforms and independent source counts. It
writes the final output atomically only after success. A failed child returns
its positive exit code; malformed input returns 2; a previously saved report
survives failure. An output path cannot overwrite input assets or the manifest.
Sweeps remain dev-only. Freeze model/config settings before held-out reporting.

Hash/structure checks do not measure acoustic annotation alignment or model
accuracy. Model artifact provenance (SEM-023), broader real-data adapters and
scoring (SEM-001/003), and grouped uncertainty reports (SEM-037) remain separate.
