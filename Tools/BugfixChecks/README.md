# Semitone bugfix regression checks

Run from the repository root:

```sh
sh Tools/BugfixChecks/run.sh
sh Tools/MidiExportTest/build.sh
```

The first command runs Python CLI/matching regression tests against the actual
`Tools/PianoModel/compare.py`, then compiles and runs the real Swift cleanup,
payload and benchmark-option code. It needs the same recent Swift/Xcode
toolchain as the app; no API key, network call or model is used. Python checks
alone can run on Linux:

```sh
python3 -m unittest discover -s Tools/BugfixChecks -p 'test_*.py' -v
# Or run the portable suite from any working directory:
sh Tools/BugfixChecks/run_python.sh
```

The MIDI export suite needs macOS and checks that filenames retain the local
date/time, contain a UUID, and differ even for identical export timestamps.
The Swift checks cover duplicate/conflicting shifts, duplicate merge IDs and
groups, overlapping operation ownership, invalid IDs, actual time-local lead
flags, dev-only sweeps, and normal held-out evaluations.

The first implementation was prepared in Linux: the seven Python tests and
diff checks passed; Swift compilation, MIDI parsing and device checks were
not run there. Build the app in Xcode and check these behaviors on iOS:

- Import notes A0 (21) and C8 (108); verify both ends of the horizontal roll.
- Export twice within the same minute; open both shared files.
- Seek before the first chord, inside a chord, at its exact end and into a long
  rest. The label should appear only inside a chord segment. ChordAnalyzer's
  existing short-rest bridging (up to 2 seconds) is preserved.
- Play a final note ending at 1 second with sustain held until 3 seconds.
  Natural completion should wait until 4.5 seconds (release plus the explicit
  1.5-second decay tail). Manual Stop should still release immediately. Also
  check note-only takes and playback after a route interruption.
- Send a cleanup containing conflicting operations. It should preserve the
  raw take and show a cleanup error, rather than applying part of the request.

`compare.py` now uses maximum-cardinality onset matching (SEM-002), retaining
its strict 30 ms window. SEM-040 now enforces configured offset/velocity and
optional sustain/frontend limits. Broader native/model parity work remains open.
No native model accuracy gain is claimed for these fixes.

## Medium batch: audio failure handling (SEM-015)

`run.sh` also builds `AudioChecks/main.swift` against the real audio loader on
macOS. It injects a read error after one full input buffer, checks that the
original error escapes instead of returning the prefix, checks converter
error status without NSError, validates rates, exercises a multi-chunk
resample, and distinguishes legitimate empty input from corrupt files.
These native checks were added on Linux and have not been executed there.

On iOS, record using the built-in mic and an external stereo interface, change
the route, interrupt the take, and restart immediately. A conversion failure
must end the affected take once with a visible reason, retain its previously
recorded prefix, and never stop the replacement take. A converter that is
temporarily buffering must not produce a false failure. The tap still has
allocations; this change does not complete the separate real-time capture
redesign in SEM-016.

## Medium batch: reanalysis generations (SEM-043)

`GenerationChecks/main.swift` calls the app's generation helper from 10,000
concurrent operations and checks that every increment is unique and that only
the latest token survives. It is included in `run.sh`; native execution is
pending. With Xcode's Thread Sanitizer, rapidly drag the custom detection pad,
change beat settings, and start a new take while reanalysis is queued. Confirm
the final settings win and no old-take config appears. The counter is atomic;
the rest of the analysis data remains owned by the transcription queue.

## Medium batch: preserve cleanup during beat changes (SEM-056)

`SettingsChecks/main.swift` tests the real effective-settings policy: changing
the mode or an active custom-pad value requires extraction; an inactive pad
value does not. Native execution and the following UI integration check are
pending; the small policy test does not establish UI behavior by itself.

1. Finish/import a take, apply cleanup with at least one removal, shift or
   merge, and record the displayed note tuples, source and pedal.
2. Change beats per measure, downbeat pitch, tempo octave and bar shift,
   individually and rapidly. The note tuples and cleanup summary must remain
   identical while the grid/chords update. Playback must not reload notes.
3. Revert cleanup. Confirm the original detector notes are restored. Repeat
   with a cleanup that removed every note and with a no-change cleanup.
4. Change an effective detection setting. This intentionally still replaces
   the notes and clears cleanup. Refine/mode changes retain that behavior too.
5. Race cleanup completion and a beat change, then immediately begin a new
   take. Check that metadata follows the latest displayed note version and
   that an old take never publishes into the new one.

The worker stores the current reviewed notes and updates that cache on
extraction, cleanup, revert and take reset. Beat-only publication changes
melody/chords/grid/config without incrementing the note version or touching
cleanup state. Preserving edits across a detector/model replacement is still
the broader SEM-009 task.

## Medium batch: maximum-cardinality scoring (SEM-002)

The Python suite covers the previous seven CLI cases plus a greedy-matching
counterexample and strict-boundary behavior. It tests the actual production
matching helper against exhaustive small graphs, randomized note cases and
a long augmenting path. Committed oracle cases cover note/event eligibility,
pitch range, repeated onsets, empty lists and tolerance boundaries using
`mir_eval 0.8.2` as the independent count reference.

`ScoringChecks/main.swift` uses those same fixtures with the actual Swift
scorer and validates counts, unique pairs, pitch/onset eligibility and PRF
counts. It is included in `run.sh`; Swift execution remains pending. The
matching count must agree with mir_eval; a particular ambiguous pairing need
not. Recompute historical benchmark numbers before comparing scorer versions.

## Portable batch: host event validity (SEM-046)

`test_event_contracts.py` exercises invalid times, pitch/dynamics/range,
duration bounds, explicit overlap policy, pedal intervals, valid polyphony
and silence through the real CSV CLI and shared validator. These checks run
with the Python standard library. This closes the host CSV boundary only;
the native NoteEvent/cleanup/playback/export boundaries remain open.

## Portable batch: per-asset provenance (SEM-092)

`test_asset_registry.py` checks stable identity/hash/path metadata, strict JSON,
duplicate IDs/paths, explicit unknown rights and per-asset declared uses. The
real CLI reports unknown records and rejects an unrecorded requested use.
These checks run offline; curator claims and actual file hashes are separate
from verification of applicable terms.

## Portable batch: versioned dataset inputs (SEM-034)

`test_dataset_manifest.py` verifies real temporary PCM WAV/JSON/CSV fixtures,
including changed hashes, headers/truncation, label bounds, alignment, declared
split leakage, parent relations and path containment. The actual CLI launch
wrapper is tested with a stub executable for curated snapshots, exclusion of
unrelated JSON, provenance retention, dev-only sweeps, input-change rejection,
child failure propagation and preservation of previous reports.
The stub verifies launch behavior; it does not stand in for native inference.

## Portable batch: enforceable parity (SEM-040)

`test_parity_gates.py` perturbs note offsets, velocities, sustain endpoints/counts
and Float32 features through the real comparison CLI and checks failing exits.
It covers declared/default/exact limits, missing required files, shape/empty/
non-finite/truncated vectors, ambiguity requiring reassignment, incompatible
joint field pairings, and randomized joint graphs against exhaustive search.
Pure reference clipping/pedal extraction is tested without importing the model.
The PyTorch reference model and native inference were not run for these checks.
