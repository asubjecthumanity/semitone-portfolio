import numpy as np
import pytest
import json
import mir_eval.transcription as mir
from pianobench import Note, Pedal, Performance, ScoreConfig, evaluate_performance, match_notes, pedal_extended

def perf(notes, semantics="key_release", pedals=None):
    return Performance(notes, pedals or [], 4, semantics, {"velocity_semantics": "midi_velocity"}, {64, 67})

def test_greedy_counterexample_requires_augmenting_path():
    reference = [Note(0, .2, 60), Note(.06, .26, 60)]
    prediction = [Note(.04, .24, 60), Note(.10, .30, 60)]
    assert len(match_notes(reference, prediction)) == 2
    assert evaluate_performance(perf(reference), perf(prediction))["onset"]["f1"] == 1

def test_duplicates_are_false_positives_not_double_matches():
    n = Note(.5, 1, 60)
    score = evaluate_performance(perf([n]), perf([n, n]))["onset"]
    assert score == {"tp": 1, "fp": 1, "fn": 0, "precision": .5, "recall": 1, "f1": 2/3}

def test_boundary_and_strict_thresholds():
    ref, pred = [Note(.5, 1, 60)], [Note(.55, 1.05, 60)]
    assert len(match_notes(ref, pred)) == 1
    assert len(match_notes(ref, pred, config=ScoreConfig(strict=True))) == 0
    assert len(match_notes(ref, [Note(.550049, 1, 60)])) == 1
    assert len(match_notes(ref, [Note(.550051, 1, 60)])) == 0

def test_wrong_pitch_duration_and_loose_timing_are_separate():
    ref = perf([Note(.5, 1, 60, 70), Note(2, 2.5, 64)])
    pred = perf([Note(.51, 1.5, 60, 80), Note(2.01, 2.5, 76)])
    scores = evaluate_performance(ref, pred)
    assert scores["onset"]["tp"] == 1
    assert scores["onset_offset"]["tp"] == 0
    assert scores["diagnostics"]["possible_octave_errors"] == 1
    assert scores["velocity_error_midi"]["mean"] == 10
    late = evaluate_performance(perf([Note(1, 2, 60)]), perf([Note(1.08, 2, 60)]))
    assert late["onset"]["f1"] == 0
    assert late["diagnostics"]["additional_matches_at_150ms"] == 1

def test_offsets_use_max_of_20_percent_or_50ms():
    assert len(match_notes([Note(0, 2, 60)], [Note(0, 2.4, 60)], offsets=True)) == 1
    assert len(match_notes([Note(0, .1, 60)], [Note(0, .15, 60)], offsets=True)) == 1
    assert len(match_notes([Note(0, .1, 60)], [Note(0, .151, 60)], offsets=True)) == 0

def test_sustain_preserves_key_releases_and_caps_at_restrike():
    original = perf([Note(.1, .4, 60), Note(.8, 1, 60), Note(2, 2.4, 62)], pedals=[Pedal(.2, 1.5)])
    extended = pedal_extended(original)
    assert [n.offset for n in extended.notes] == [.8, 1.5, 2.4]
    assert original.notes[0].offset == .4
    scores = evaluate_performance(original, extended)
    assert scores["onset_offset"]["f1"] == 1
    assert scores["offset_diagnostics"]["raw_prediction_vs_key_release"]["note"]["f1"] < 1
    assert pedal_extended(extended) is extended

def test_unknown_offsets_do_not_claim_duration_accuracy():
    scores = evaluate_performance(perf([Note(.5, 1, 60)]), perf([Note(.5, 1, 60)], "unspecified"))
    assert scores["onset"]["f1"] == 1
    assert scores["onset_offset"] is None
    assert not scores["offset_semantics"]["headline_comparable"]

def test_empty_sets_and_negative_control_rates():
    score = evaluate_performance(perf([]), perf([]))
    assert score["onset"]["f1"] is None
    assert score["negative_control"]["false_notes_per_minute"] == 0
    ghost = evaluate_performance(perf([]), perf([Note(.5, 1, 60)]))
    assert ghost["negative_control"]["false_notes_per_minute"] == 15
    missed = evaluate_performance(perf([Note(.5, 1, 60)]), perf([]))
    assert missed["onset"]["f1"] == 0

def test_pitch_activity_unions_duplicates():
    ref = perf([Note(0, 1, 60)])
    pred = perf([Note(.5, 1.5, 60), Note(.5, 1.5, 60)])
    value = evaluate_performance(ref, pred)["pitch_activity"]
    assert value["f1"] == .5
    assert value["prediction_pitch_seconds"] == 1

def test_report_with_false_positives_serializes_and_has_window_counts():
    result = evaluate_performance(perf([Note(.5, 1, 60)]), perf([Note(.5, 1, 60), Note(2, 3, 66)]))
    json.dumps(result, allow_nan=False)
    assert result["windows"][0]["onset"]["fp"] == 1

def test_loose_diagnostic_is_unavailable_when_baseline_is_even_looser():
    result = evaluate_performance(perf([Note(1, 2, 60)]), perf([Note(1.18, 2, 60)]),
                                  config=ScoreConfig(onset_tolerance=.2))
    assert result["onset"]["f1"] == 1
    assert result["diagnostics"]["additional_matches_at_150ms"] is None

@pytest.mark.parametrize("offsets", [False, True])
def test_sparse_matcher_agrees_with_mir_eval_randomized(offsets):
    rng = np.random.default_rng(88)
    for _ in range(250):
        rcount, pcount = int(rng.integers(1, 25)), int(rng.integers(1, 25))
        rstart, pstart = rng.integers(0, 100, rcount) / 100, rng.integers(0, 100, pcount) / 100
        reference = [Note(s, s + float(rng.uniform(.03, .8)), int(rng.integers(60, 65))) for s in rstart]
        prediction = [Note(s, s + float(rng.uniform(.03, .8)), int(rng.integers(60, 65))) for s in pstart]
        for strict in (False, True):
            cfg = ScoreConfig(strict=strict)
            actual = match_notes(reference, prediction, config=cfg, offsets=offsets)
            interval = lambda notes: np.asarray([[n.onset, n.offset] for n in notes])
            hz = lambda notes: np.asarray([440 * 2**((n.pitch - 69)/12) for n in notes])
            expected = mir.match_notes(interval(reference), hz(reference), interval(prediction), hz(prediction),
                                       offset_ratio=.2 if offsets else None, strict=strict)
            assert len(actual) == len(expected)

@pytest.mark.parametrize("kwargs", [dict(onset=float("nan"),offset=1,pitch=60), dict(onset=0,offset=0,pitch=60),
                                   dict(onset=0,offset=1,pitch=60.5), dict(onset=0,offset=1,pitch=128),
                                   dict(onset=0,offset=1,pitch=60,velocity=128)])
def test_invalid_events_fail_loudly(kwargs):
    with pytest.raises(ValueError):
        Note(**kwargs)
