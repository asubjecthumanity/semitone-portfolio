"""Original controlled piano schedules plus silence/noise negative controls."""
from dataclasses import replace
from pathlib import Path
import json
import shutil
import subprocess
import mido
import numpy as np
import soundfile as sf
from .models import Note, Pedal, Performance, pedal_extended
from .io import sha256, write_performance
from .difficulty import complexity
from .datasets import write_manifest

def write_midi(performance, path):
    # Constant 120 BPM, 960 PPQ => 1920 ticks/second. Ground truth is the MIDI
    # reloaded after serialization, so event rounding never differs from labels.
    midi = mido.MidiFile(ticks_per_beat=960)
    track = mido.MidiTrack()
    midi.tracks.append(track)
    track.append(mido.MetaMessage("set_tempo", tempo=500000, time=0))
    track.append(mido.Message("program_change", program=0, time=0))
    events = []
    for n in performance.notes:
        events.extend([(round(n.onset * 1920), 1, mido.Message("note_on", note=n.pitch, velocity=max(1, int(n.velocity or 72)))),
                       (round(n.offset * 1920), 0, mido.Message("note_off", note=n.pitch, velocity=0))])
    for p in performance.pedals:
        events.extend([(round(p.onset * 1920), 0, mido.Message("control_change", control=p.controller, value=127)),
                       (round(p.offset * 1920), 0, mido.Message("control_change", control=p.controller, value=0))])
    previous = 0
    for tick, _, msg in sorted(events, key=lambda x: (x[0], x[1])):
        track.append(msg.copy(time=tick - previous))
        previous = tick
    end = max(previous, round(performance.duration * 1920))
    track.append(mido.MetaMessage("end_of_track", time=end - previous))
    midi.save(path)

def _toy_render(performance, sample_rate, rng, noise=False):
    audio = np.zeros(round(performance.duration * sample_rate), dtype=np.float64)
    for n in pedal_extended(performance).notes:
        begin = round(n.onset * sample_rate)
        length = min(len(audio) - begin, round((n.offset - n.onset + .06) * sample_rate))
        if length <= 0:
            continue
        t = np.arange(length) / sample_rate
        frequency = 440 * 2 ** ((n.pitch - 69) / 12)
        tone = np.zeros(length)
        for harmonic in range(1, 7):
            if frequency * harmonic < sample_rate / 2:
                tone += np.sin(2 * np.pi * frequency * harmonic * t) / harmonic ** 1.8
        release = n.offset - n.onset
        envelope = np.minimum(t / .005, 1) * np.exp(-.5 * t)
        envelope *= np.maximum(0, np.minimum((release + .06 - t) / .06, 1))
        audio[begin:begin + length] += tone * envelope * (n.velocity or 72) / 127 * .07
    if noise:
        audio += rng.normal(0, .004, len(audio))
    # Consistent gain, no per-note/file peak normalization that erases quiet tests.
    return np.clip(audio, -.99, .99).astype("float32")

def _schedule(level, pattern, duration):
    notes, pedals = [], []
    steps = [1.05, .60, .28, .14, .065]
    chord_sizes = [1, 2, 4, 6, 9]
    step = steps[level - 1]
    size = chord_sizes[level - 1]
    rng = np.random.default_rng(1000 + level * 10 + pattern)
    if pattern == 1:
        step = [1.25, 1.0, .70, .50, .38][level - 1]
    for k, start in enumerate(np.arange(.5, duration - 1.0, step)):
        velocity = int(rng.integers(48, 110))
        if pattern == 3:
            velocity = [24, 34, 64, 100][k % 4]
        length = min(step * (.35 if pattern == 2 else .75), .65)
        if pattern == 1:
            pitches = [42 + (k % 5)] + [60 + 3 * j + k % 3 for j in range(size - 1)]
        elif pattern == 2:
            pitches = [60 if k % 8 < 4 else 72]
        elif pattern == 4:
            pitches = [48 + k % 12]
        elif pattern == 5:
            # Traverse the entire actual piano range, including both endpoints.
            pitches = [21 + (k * 7) % 88]
        else:
            pitches = [48 + ((k * 3) % 36)]
        notes += [Note(float(start), float(start + length), pitch, velocity) for pitch in pitches]
    if pattern == 4:
        pedals = [Pedal(1.0, 5.0), Pedal(7.7, 12.0), Pedal(15.7, 21.5), Pedal(3, 6, 67)]
        pedals = [replace(p, offset=min(p.offset, duration)) for p in pedals if p.onset < duration]
    if pattern == 5:
        for start, pitch in ((7.94, 108), (8.06, 21), (15.94, 108), (16.06, 21)):
            notes.append(Note(start, start + .09, pitch, 35))
    return Performance(notes, pedals, duration, "key_release", {"velocity_semantics": "midi_velocity"}, {64, 67})

def generate_fixtures(output, *, renderer="toy", soundfont=None, seed=20261002, duration=24.0,
                      sample_rate=22050, split="validation"):
    if duration < 18:
        raise ValueError("fixtures need at least 18 seconds for segment-boundary tests")
    if renderer not in ("toy", "fluidsynth"):
        raise ValueError("renderer must be toy or fluidsynth")
    if renderer == "fluidsynth" and (not soundfont or not Path(soundfont).is_file() or not shutil.which("fluidsynth")):
        raise ValueError("FluidSynth rendering requires a local .sf2 and the fluidsynth executable")
    output = Path(output).resolve()
    if output.exists() and any(output.iterdir()):
        raise FileExistsError("fixture output directory is not empty")
    (output / "audio").mkdir(parents=True, exist_ok=True)
    (output / "midi").mkdir(exist_ok=True)
    from .io import read_midi
    rng, pieces = np.random.default_rng(seed), []
    patterns = ["melody", "chords", "restrikes", "dynamics", "pedal", "range-seams"]
    renderer_hash = sha256(soundfont) if soundfont else "original-additive-toy-v1"
    for level in range(1, 6):
        for pattern, name in enumerate(patterns):
            identity = f"fixture-L{level}-{name}"
            midi_path, wav_path = output / "midi" / (identity + ".mid"), output / "audio" / (identity + ".wav")
            write_midi(_schedule(level, pattern, duration), midi_path)
            truth = read_midi(midi_path, offset_semantics="key_release")
            truth.duration = duration
            if renderer == "fluidsynth":
                process = subprocess.run(["fluidsynth", "-ni", "-r", str(sample_rate), "-F", str(wav_path),
                                          "-T", "wav", "-o", "synth.reverb.active=0", "-o", "synth.chorus.active=0",
                                          str(Path(soundfont).resolve()), str(midi_path)], capture_output=True, text=True)
                if process.returncode:
                    raise RuntimeError(process.stderr[-4000:])
                data, rate = sf.read(str(wav_path), always_2d=True)
                count = round(duration * rate)
                data = np.pad(data, ((0, max(0, count - len(data))), (0, 0)))[:count]
                sf.write(str(wav_path), data, rate, subtype="PCM_16")
            else:
                sf.write(str(wav_path), _toy_render(truth, sample_rate, rng), sample_rate, subtype="PCM_16")
            pieces.append({"id": identity, "dataset": "ORIGINAL_FIXTURES", "dataset_release": "1.0",
                           "audio": f"audio/{identity}.wav", "reference": f"midi/{identity}.mid",
                           "audio_sha256": sha256(wav_path), "reference_sha256": sha256(midi_path),
                           "duration_seconds": duration, "difficulty_level": level,
                           "difficulty_source": "designed diagnostic tier; see computed reference complexity",
                           "complexity": complexity(truth.notes),
                           "group_id": "fixture-family-" + ("melody" if name == "dynamics" else name),
                           "split": split, "kind": "synthetic_toy" if renderer == "toy" else "synthetic_sampled",
                           "tags": [name, renderer], "reference_offset_semantics": "key_release",
                           "alignment": {"offset_seconds": 0, "status": "verified",
                                         "basis": "Original render/event timeline; FluidSynth block latency should be independently checked for strict sub-10ms work."},
                           "renderer_sha256": renderer_hash, "terms": "Original generated schedules; soundfont terms apply to sampled renders."})
    for identity, noisy in (("negative-silence", False), ("negative-noise", True)):
        truth = Performance([], duration=duration, offset_semantics="key_release", pedal_controllers={64, 67})
        reference, wav = output / (identity + ".json"), output / "audio" / (identity + ".wav")
        write_performance(truth, reference)
        sf.write(str(wav), _toy_render(truth, sample_rate, rng, noise=noisy), sample_rate, subtype="PCM_16")
        pieces.append({"id": identity, "dataset": "ORIGINAL_FIXTURES", "dataset_release": "1.0",
                       "audio": f"audio/{identity}.wav", "reference": reference.name,
                       "audio_sha256": sha256(wav), "reference_sha256": sha256(reference),
                       "duration_seconds": duration, "difficulty_level": 0, "difficulty_source": "verified no notes",
                       "group_id": identity, "split": split, "kind": "negative", "tags": ["negative"],
                       "reference_offset_semantics": "key_release",
                       "alignment": {"offset_seconds": 0, "status": "verified", "basis": "Generated no-note control"},
                       "terms": "Original generated control"})
    return write_manifest(pieces, output / "manifest.json", "original-piano-diagnostic-ladder",
                          notes=["Toy additive tones validate software plumbing, not real-piano accuracy.",
                                 "For meaningful acoustic results, combine sampled renders and held-out real piano recordings.",
                                 "All fixture derivatives and alternate soundfonts must retain the same group ID."])

def demo_predictions(manifest_path, output, *, degraded=False, seed=17):
    """Known oracle/degraded outputs for testing the tester; never Semitone results."""
    from .manifest import load_manifest
    _, cases, _ = load_manifest(manifest_path)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(seed)
    for piece, truth in cases:
        notes = truth.notes
        if degraded:
            notes = []
            for n in truth.notes:
                if rng.random() < .18:
                    continue
                pitch = min(108, n.pitch + 12) if rng.random() < .12 else n.pitch
                shift = .085 if rng.random() < .14 else .015
                notes.append(replace(n, onset=n.onset + shift, offset=n.offset + shift))
            if not truth.notes:
                notes = [Note(.5, .7, 60, 64)]
        prediction = Performance(notes, [] if degraded else truth.pedals, piece["duration_seconds"], "key_release",
                                 {"velocity_semantics": "midi_velocity", "source": "TESTER DEMO; not an app prediction",
                                  "audio_sha256": piece["audio_sha256"]}, {64, 67})
        write_performance(prediction, output / (piece["id"] + ".json"))
    return output
