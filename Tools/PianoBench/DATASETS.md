# Piano data and fixture selection

These are the primary sources checked for this tester. Download third-party
recordings locally and freeze their selected files in a manifest. Generate
original toy diagnostics with `fixtures`; no public recordings or generated
audio are committed in this fork.

| Source | Use in PianoBench | Important label/release detail |
|---|---|---|
| [MAESTRO](https://magenta.withgoogle.com/datasets/maestro) | `prepare-maestro`; broad expressive concert-piano audio/performance-MIDI | Use v3.0.0 and its CSV/splits; group canonical compositions. The project describes millisecond-scale alignment. Many piano checkpoints trained on MAESTRO. |
| [SMD](https://www.audiolabs-erlangen.de/resources/MIR/SMD/midi) | `prepare-smd`; real piano with corrected note/controller labels | Use v2 and original WAV, not historical MIDI or MP3 preview decoding. v2 restores sustain/soft controllers. Physical Disklavier/acoustic delays remain. |
| [SMD v2 WAV release](https://zenodo.org/records/13753319) | Original paired data for the SMD adapter | Official release linked from the SMD project. Choose original `wav_44100_stereo` or `wav_22050_mono`; `midi_wav_22050_mono` is synthesized. |
| [MAPS](https://adasp.telecom-paris.fr/resources/2010-07-08-maps-database/) | `prepare-maps`; isolated notes, chords, full pieces, piano settings | Has MIDI/text reference data and real/synthetic settings. Identify the original piano setting; `ENSTDkCl` and `ENSTDkAm` are real Disklavier conditions. |
| [PianoVAM](https://huggingface.co/datasets/PianoVAM/PianoVAM_v1) | Optional extra real recordings via a curated paired manifest | Keep release-specific audio/MIDI synchronization and solo-piano scope. This package does not implement the dataset's video/TSV/fingering formats. |
| [ASAP](https://github.com/fosfrancesco/asap-dataset) | Later notation/rhythm evaluation and manually aligned performance targets | Distinguish score MIDI from performance MIDI. Its MAESTRO-related lineage and crops require explicit offsets/grouping. No dedicated ASAP adapter is included. |
| [Vienna 4x22](https://github.com/CPJKU/vienna4x22) | Optional score/performance correspondence work | Confirm actual paired audio availability. Symbolic files alone do not measure acoustic transcription accuracy. |

MAESTRO and PianoVAM publish CC BY-NC-SA 4.0 terms; SMD uses CC BY-NC-SA 3.0;
MAPS's page lists CC BY-NC-SA 2.0 France. Retain selected-asset attribution and
terms in manifests. Public access is not a reason to redistribute recordings
as app fixtures. Dataset terms, model weights, soundfonts, and compositions
have separate provenance.

## A useful first suite

Start with the 32 generated original diagnostic cases and a small selection of
real SMD performances. Add an official MAESTRO **test** subset for breadth.
Retain the original splits, and use validation material for decoder tuning.
MAPS note/chord examples help diagnose specific range/polyphony failures.
Your own independent phone/piano/room sessions test the actual microphone
conditions that clean studio datasets do not cover.

The real SMD repertoire checked at the MIDI-parser level in this implementation
includes Bach BWV849-01, Chopin Op.10 No.4, Liszt's Dante sonata,
Rachmaninoff Op.36-01, and Ravel's *Jeux d'eau*. These are suitable demanding
candidate performances, not measured Semitone accuracy results. A slow
single-line exercise may have to come from your own paired capture or
controlled original rendering rather than a concert-repertoire dataset.

## More realistic generated piano audio

Use FluidSynth with a locally obtained piano SoundFont. For example,
[GeneralUser GS](https://github.com/mrbumpy409/GeneralUser-GS) provides a
documented sound bank; preserve its exact license/version and hash. Another
piano bank is useful as a held-out timbre.

```bash
python -m pianobench fixtures data/sampled-piano \
  --renderer fluidsynth --soundfont /data/piano.sf2 --split validation
```

Install the `fluidsynth` executable separately. The command renders exactly the
same original MIDI schedules and records the bank hash. Do not place alternate
renders of the same schedule in different development/test groups. Renderer
note-off is a key-release event; audible decay continues after it. For strict
sub-10 ms comparisons, independently measure renderer block/attack latency.

Simple room/noise/quiet-input variants can be added as paired cases with the
same reference and group ID, preserving pitch/time labels. Time stretching,
pitch shifting, trimming, and re-recording require updated targets and timing
alignment; the tester deliberately does not guess those transformations.

## Evaluation references

The MAESTRO, SMD/MAPS project pages, SMD v2 Zenodo release and mir_eval
transcription documentation were rechecked on October 3, 2026. The SMD release
is the version-specific record `13753319`; do not substitute historical MIDI or
its synthesized audio view when declaring a real-recording suite. These links
identify candidate sources, not assets downloaded/evaluated in this integration.

- [mir_eval transcription](https://mir-eval.readthedocs.io/latest/api/transcription.html):
  one-to-one matching, tolerances, and strict/inclusive threshold rules.
- [Mido timing](https://mido.readthedocs.io/en/stable/files/midi.html):
  track delta ticks, merged tracks, tempo-dependent seconds, default tempo.
- [Transkun](https://github.com/Yujia-Yan/Transkun):
  native model's upstream architecture and checkpoint offset convention.
- The supplied Semitone backlog: recommendations for real-piano evaluation,
  controller/offset contracts, split grouping, data hashes, and repeated-note diagnostics.
