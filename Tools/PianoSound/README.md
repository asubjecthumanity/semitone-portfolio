# Playback piano sound

`Semitone/GrandPiano.sf2` (34.6 MB) is what `MidiPlayer` plays notes through (AVAudioUnitSampler,
driven by AVAudioSequencer). It is a slimmed copy of:

| | |
|---|---|
| Source | `YDP-GrandPiano-SF2-20160804.tar.bz2` from https://freepats.zenvoid.org/Piano/acoustic-grand-piano.html |
| Instrument | Yamaha Disklavier Pro grand, recorded by Zenph Studios for the OLPC sound library; SoundFont by FreePats |
| License | Creative Commons Attribution 3.0. The credit shown in the app's Settings → Playback footer satisfies it; keep it if the sound ships |
| Original size | 118.4 MB (121 mono 44.1 kHz samples, 30 root keys, ~4 velocity layers) |

`slim_sf2.py` only rewrites the sample data (presets, zones and envelopes are untouched):
bass samples go to 22.05 kHz and at most 9 s, the rest to 32 kHz and at most 6 s (C3–B4) or 4 s (C5 up),
each cut where it has decayed below −50 dB or at the cap, with a fade.

```
python slim_sf2.py YDP-GrandPiano-20160804.sf2 GrandPiano.sf2    # needs numpy + scipy
```

Check (2026-09-22, 30 s of clip 3 with its detected pedal): the slimmed render differs from the full one by
−52 dB overall and is identical below 8 kHz; resampling images sit 60 dB below the music.

Playback uses the piano model's sustain pedal (decoded from Transkun's pedal symbol, see
`Tools/PianoModel/README.md`) as CC 64 and its detected velocities; quick-detector notes play without pedal.
