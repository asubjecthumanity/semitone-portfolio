from pathlib import Path
import csv
import json
import mido
import numpy as np
import pytest
import soundfile as sf
from pianobench.datasets import prepare_maestro, prepare_paired, combine_manifests
from pianobench.manifest import load_manifest

def pair(root, stem):
    root.mkdir(parents=True, exist_ok=True)
    sf.write(str(root / (stem + ".wav")), np.zeros(8000), 8000)
    midi, track = mido.MidiFile(), mido.MidiTrack()
    midi.tracks.append(track)
    track.extend([mido.Message("note_on", note=60, velocity=70, time=96),
                  mido.Message("note_off", note=60, time=192),
                  mido.MetaMessage("end_of_track", time=672)])
    midi.save(root / (stem + ".mid"))

def test_maestro_preserves_official_split_and_missing_audio_count(tmp_path):
    pair(tmp_path, "heldout")
    csv_path = tmp_path / "maestro-v3.0.0.csv"
    fields = ["split", "audio_filename", "midi_filename", "canonical_composer", "canonical_title"]
    with csv_path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for split, name in (("test", "heldout"), ("train", "heldout"), ("test", "missing")):
            writer.writerow(dict(zip(fields, [split, name + ".wav", name + ".mid", "Composer", "Work"])))
    manifest = prepare_maestro(tmp_path, tmp_path / "selected.json")
    raw, cases, _ = load_manifest(manifest)
    assert len(cases) == 1
    assert cases[0][0]["split"] == "test"
    assert cases[0][0]["group_id"] == "Composer::Work"
    assert raw["notes"][0].startswith("1 split entries")

def test_maps_labels_real_and_synthetic_settings(tmp_path):
    pair(tmp_path, "MAPS_MUS_piece_ENSTDkCl")
    pair(tmp_path, "MAPS_MUS_piece_AkPnBcht")
    manifest = prepare_paired(tmp_path, tmp_path / "maps.json", dataset="MAPS")
    _, cases, _ = load_manifest(manifest)
    assert {p["kind"] for p, _ in cases} == {"real", "synthetic_sampled"}
    assert len({p["group_id"] for p, _ in cases}) == 1

def test_custom_pairs_require_alignment_verification(tmp_path):
    pair(tmp_path, "my-piano")
    manifest = prepare_paired(tmp_path, tmp_path / "custom.json", dataset="CUSTOM")
    with pytest.raises(ValueError, match="unverified"):
        load_manifest(manifest)
    _, cases, _ = load_manifest(manifest, allow_unverified=True)
    assert len(cases) == 1

def test_combine_rejects_duplicate_ids(tmp_path):
    pair(tmp_path, "Bach_BWV849-01_001_20090916-SMD")
    manifest = prepare_paired(tmp_path, tmp_path / "smd.json", dataset="SMD")
    with pytest.raises(ValueError, match="duplicate piece ID"):
        combine_manifests([manifest, manifest], tmp_path / "combined.json")
