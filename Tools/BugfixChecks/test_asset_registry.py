"""Verify provenance metadata and explicit unknown/usage behavior offline."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BENCH = Path(__file__).resolve().parents[1] / "MusicBench"
sys.path.insert(0, str(BENCH))
from asset_registry import load_json, validate_registry


def asset(ident="audio-1", path="dev01.wav", kind="audio"):
    return dict(asset_id=ident, path=path, kind=kind, sha256="a" * 64,
                source=dict(uri="generated:unit-test", release="fixture-v1"),
                rights=dict(status="recorded", license="unknown", terms_uri=None,
                            attribution="Synthetic unit-test fixture", permission_note="Created for this local test",
                            permitted_uses=["local_evaluation", "ci"]))


class AssetRegistryTests(unittest.TestCase):
    def test_explicit_unknown_is_preserved_and_not_authorized(self):
        item = asset()
        item["rights"].update(status="unknown", license="unknown", permission_note="", permitted_uses=[])
        registry = dict(schema_version=1, assets=[item])
        original = copy.deepcopy(registry)
        self.assertEqual(validate_registry(registry)["audio-1"]["rights"]["status"], "unknown")
        self.assertEqual(registry, original)
        for use in ["local_evaluation", "ci", "redistribution", "training"]:
            with self.subTest(use=use), self.assertRaisesRegex(ValueError, "no recorded permission"):
                validate_registry(registry, use=use)

    def test_uses_are_explicit_and_per_asset(self):
        registry = dict(schema_version=1, assets=[asset(), asset("truth-1", "dev01.json", "song_truth")])
        self.assertEqual(len(validate_registry(registry, use="ci")), 2)
        registry["assets"][1]["rights"]["permitted_uses"] = ["local_evaluation"]
        with self.assertRaisesRegex(ValueError, "truth-1"):
            validate_registry(registry, use="ci")

    def test_malformed_identity_paths_hashes_and_sources(self):
        changes = [("asset_id", ""), ("path", "../private.wav"), ("path", "/absolute.wav"),
                   ("path", "C:\\take.wav"), ("path", "./take.wav"), ("sha256", "a" * 63),
                   ("kind", "unknown_kind"), ("source", dict(uri="bare-path", release="v1"))]
        for field, value in changes:
            item = asset(); item[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                validate_registry(dict(schema_version=1, assets=[item]))
        for version in [True, "1", 2]:
            with self.assertRaises(ValueError):
                validate_registry(dict(schema_version=version, assets=[]))

    def test_duplicates_and_false_unknown_permissions(self):
        for duplicate in [asset(), asset("audio-2", "DEV01.WAV")]:
            with self.assertRaises(ValueError):
                validate_registry(dict(schema_version=1, assets=[asset(), duplicate]))
        for patch in [dict(status="unknown", permitted_uses=["ci"]), dict(status="unknown", license="MIT"),
                      dict(permitted_uses=["ci", "ci"]), dict(permitted_uses=["anything"]),
                      dict(permission_note="", license="unknown")]:
            item = asset(); item["rights"].update(patch)
            with self.assertRaises(ValueError):
                validate_registry(dict(schema_version=1, assets=[item]))

    def test_strict_json_rejects_duplicate_keys_and_nonfinite(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "registry.json"
            for content in ['{"schema_version":1,"schema_version":2}', '{"assets":NaN}', '{"value":1e999}']:
                path.write_text(content)
                with self.assertRaises(ValueError):
                    load_json(path)

    def test_actual_cli_reports_unknown_and_rejects_unrecorded_use(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "registry.json"
            item = asset(); item["rights"].update(status="unknown", permitted_uses=[], permission_note="")
            path.write_text(json.dumps(dict(schema_version=1, assets=[item])))
            command = [sys.executable, str(BENCH / "asset_registry.py"), str(path)]
            okay = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(okay.returncode, 0, okay.stderr)
            self.assertEqual(json.loads(okay.stdout)["unknown_rights"], 1)
            self.assertFalse(json.loads(okay.stdout)["verified_file_bytes"])
            refused = subprocess.run(command + ["--use", "ci"], capture_output=True, text=True)
            self.assertEqual(refused.returncode, 2)
            self.assertNotIn("Traceback", refused.stderr)
