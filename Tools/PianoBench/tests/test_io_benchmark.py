from pathlib import Path
import json
import sys
import mido
import pytest
import numpy as np
import soundfile as sf
from pianobench import Note, Performance, evaluate_version, compare_runs, read_midi, CommandRunner
from pianobench.io import write_performance, sha256
from pianobench.manifest import load_manifest
from pianobench.difficulty import complexity

def test_midi_default_tempo_changes_and_cross_track_note_off(tmp_path):
    midi = mido.MidiFile(ticks_per_beat=480)
    conductor, notes = mido.MidiTrack(), mido.MidiTrack()
    midi.tracks.extend([conductor, notes])
    conductor.extend([mido.MetaMessage("set_tempo", tempo=1000000, time=480),
                      mido.MetaMessage("end_of_track", time=960)])
    notes.extend([mido.Message("note_on", note=60, velocity=90, time=240),
                  mido.Message("note_on", note=60, velocity=0, time=480)])
    path = tmp_path / "tempo.mid"
    midi.save(path)
    performance = read_midi(path)
    assert performance.notes[0].onset == .25
    assert performance.notes[0].offset == 1.0
    assert performance.duration == 2.5

def test_midi_sustain_and_soft_are_separate(tmp_path):
    midi, track = mido.MidiFile(), mido.MidiTrack()
    midi.tracks.append(track)
    track.extend([mido.Message("control_change", control=64, value=127, time=0),
                  mido.Message("control_change", control=67, value=100, time=0),
                  mido.Message("note_on", note=60, velocity=70, time=0),
                  mido.Message("note_off", note=60, time=480),
                  mido.Message("control_change", control=64, value=63, time=480),
                  mido.Message("control_change", control=67, value=0, time=480)])
    path = tmp_path / "pedal.mid"
    midi.save(path)
    value = read_midi(path)
    assert value.notes[0].offset == .5
    assert {p.controller: p.offset for p in value.pedals} == {64: 1, 67: 1.5}

@pytest.fixture
def suite(tmp_path):
    pieces = []
    for index in range(3):
        wav, ref = tmp_path / f"audio {index}.wav", tmp_path / f"reference{index}.json"
        sf.write(str(wav), np.zeros(8000), 8000)
        performance = Performance([Note(.1, .3, 60)] if index < 2 else [], duration=1,
                                  offset_semantics="key_release", pedal_controllers={64})
        write_performance(performance, ref)
        pieces.append({"id": f"case{index}", "audio": wav.name, "reference": ref.name,
                       "audio_sha256": sha256(wav), "reference_sha256": sha256(ref), "duration_seconds": 1,
                       "dataset": "TEST", "difficulty_level": 1 if index < 2 else 0,
                       "group_id": f"group{index}", "split": "test", "kind": "real",
                       "reference_offset_semantics": "key_release",
                       "alignment": {"offset_seconds": 0, "status": "verified"}})
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps({"schema_version": 1, "pieces": pieces}))
    return path, pieces

def test_changed_bytes_and_split_leakage_rejected(suite):
    path, pieces = suite
    pieces[1]["split"] = "validation"
    path.write_text(json.dumps({"schema_version": 1, "pieces": pieces}))
    with pytest.raises(ValueError, match="multiple splits"):
        load_manifest(path)
    pieces[1]["split"] = "test"
    pieces[0]["audio_sha256"] = "0" * 64
    path.write_text(json.dumps({"schema_version": 1, "pieces": pieces}))
    with pytest.raises(ValueError, match="changed audio"):
        load_manifest(path)

def test_version_missing_output_counts_as_zero_and_silence_cannot_inflate(suite, tmp_path):
    manifest, _ = suite
    predictions = tmp_path / "preds"
    predictions.mkdir()
    write_performance(Performance([Note(.1, .3, 60)], duration=1, offset_semantics="key_release"), predictions / "case0.json")
    write_performance(Performance([], duration=1, offset_semantics="key_release"), predictions / "case2.json")
    report = evaluate_version(manifest, version="version1", output_dir=tmp_path / "run1",
                              prediction_dir=predictions, prediction_offset_semantics="key_release", bootstrap_samples=20)
    assert report["summary"]["onset"]["macro_f1"] == .5
    assert report["summary"]["onset_offset"]["macro_f1"] == .5
    assert report["summary"]["all_failed_cases"] == 1
    assert report["pieces"][1]["scores"]["onset"]["fn"] == 1
    assert (tmp_path / "run1/pieces.csv").is_file()
    improved = evaluate_version(manifest, version="version2", output_dir=tmp_path / "run2",
                                transcriber=lambda audio: Performance([] if audio.name == "audio 2.wav" else [Note(.1, .3, 60)],
                                                                     duration=1, offset_semantics="key_release"),
                                prediction_offset_semantics="key_release", bootstrap_samples=20)
    delta = compare_runs(report, improved, bootstrap_samples=20)
    assert delta["metrics"]["onset"]["macro_f1_delta"] == .5
    altered = dict(improved, score_config_sha256="changed")
    with pytest.raises(ValueError, match="score_config"):
        compare_runs(report, altered)

def test_prediction_from_wrong_audio_is_failed_case(suite, tmp_path):
    manifest, _ = suite
    def wrong(_):
        return Performance([Note(.1, .3, 60)], duration=1, offset_semantics="key_release", metadata={"audio_sha256": "wrong"})
    report = evaluate_version(manifest, version="wrong", output_dir=tmp_path / "wrong", transcriber=wrong, bootstrap_samples=0)
    assert report["summary"]["onset"]["macro_f1"] == 0
    assert report["summary"]["all_failed_cases"] == 3

def test_command_adapter_works_with_spaces_without_shell(tmp_path):
    script = tmp_path / "predict program.py"
    script.write_text('import pathlib,sys,json\npathlib.Path(sys.argv[2]).write_text(json.dumps({"notes":[],"duration_seconds":1}))\n')
    audio = tmp_path / "audio with spaces.wav"
    audio.touch()
    runner = CommandRunner([sys.executable, str(script), "{audio}", "{output}"])
    result = runner(audio)
    assert result.notes == []
    assert result.metadata["subprocess_wall_seconds"] > 0

def test_reference_complexity_simple_and_dense():
    assert complexity([Note(i, i+.3, 60+i%5) for i in range(10)])["level"] == 1
    dense = [Note(i*.04, i*.04+.2, 48+i%40) for i in range(100)]
    assert complexity(dense)["level"] == 5
