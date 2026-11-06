# Matched MIDI/audio pairs

Made by Freeman Miller.

Each pair is a recording plus a MIDI file of the notes in it, made in Ableton Live: the MIDI is the
answer key for the recording. Semitone listens to the audio, and its notes are scored against the
MIDI. The pairs measure how accurate the transcription is, and that is how its models and settings
were chosen.

The pairs are not used to train a model. The app's note-detection models are open-source models
trained by their authors (see the main README).

**Code comments call this folder `semitone training/`, its name in the working repo.**

## The pairs

| Folder | Audio | MIDI | What it is |
|---|---|---|---|
| `clip1/` | `audioAItraining.wav`: 8 s, 48 kHz, 24-bit stereo | `midiAItraining.mid`: 35 notes | Piano, 4/4 at 120 BPM. A short first test. |
| `clip3/` | `AUDIOTEST3.wav`: 264 s. **Not in this repo** (46 MB) | `MIDITEST3.mid`: 1,295 notes | Solo piano in 10/8. Steady at 175 BPM for the first 101 s, then rubato (the tempo moves freely). |

## How a pair is made

1. Write or play the part as MIDI in Ableton Live.
2. Render the MIDI to audio through a piano instrument.
3. Export both. The MIDI file is the answer key for the audio.

## Format

- **MIDI:** Standard MIDI File, type 0, 96 ticks per beat, one track, no tempo event.
- **Audio:** WAV.
- **Aligned keys** (`clip3/*.json`): lists of `[start seconds, end seconds, MIDI pitch, velocity]`, one per note.

## Lining up clip 3

Clip 3's MIDI has no tempo event, so its beats don't map straight onto seconds. Scoring against the
raw MIDI made every transcriber look about 45% accurate and hid the real differences between them.
Clip 3 was therefore lined up with its recording:

- **First 101 s (steady):** the note times follow from 175 BPM, checked against the recording to
  within ±2 ms. The result is `MIDITEST3_aligned_steady.json`.
- **Rubato part:** a tempo tracker follows each pitch's note starts two bars at a time. On the steady
  part its median error is 3.6 ms. The result is `MIDITEST3_aligned_rubato.json`.
- **Left out of strict scoring:** two passages, 110–130 s and 240–250 s, are still off by more than
  50 ms. About 87% of the notes are scored.

## What the pairs decided

Onset F1 on clip 3's lined-up notes. F1 combines how many of the real notes were found with how many
of the detected notes were real, so 1.0 means every note was found with nothing extra.

| Model | Onset F1 |
|---|---|
| Basic Pitch (Spotify) | 0.845 |
| ByteDance piano model | 0.965 |
| **Transkun v2 (Yujia Yan)** | **0.972** |

Transkun was ported to the app on this result. It also gets all 35 notes of clip 1 right.

The pairs were also used to:
- choose how precise the app's version of the model needs to be;
- tune the beat tracker. It needs 100 frames per second; at 50 it falls to half tempo on clip 3.

The tools that score against them are in `Tools/RealBench` and `Tools/PianoModel`.

## Songs scored but not stored here

These recordings and answer keys stay on the developer's computer only:

- **Ten commercial songs**, each scored against fan-made MIDI downloaded from bitmidi.com and lined
  up with the recording. The tool that lines them up is `Tools/RealBench/bitmidi`.
- **Ableton Live demo songs**, exported from Live, with answer keys made by
  `Tools/RealBench/als2truth`.

The recordings are copyrighted, so they are not shared.
