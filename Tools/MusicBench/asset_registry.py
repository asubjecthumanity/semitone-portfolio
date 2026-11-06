"""Validate explicit per-asset provenance/rights records (standard library).

This checks recorded metadata and selected uses. It does not infer permission
from a public download URL, validate legal terms, or fetch any remote files.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit

SCHEMA_VERSION = 1
USES = {"local_evaluation", "ci", "redistribution", "training"}
KINDS = {"audio", "song_truth", "notes_csv", "pedal_csv", "other"}


def load_json_bytes(payload, path="JSON"):
    def object_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"{path}: duplicate JSON key {key!r}")
            result[key] = value
        return result
    def invalid_constant(value):
        raise ValueError(f"{path}: non-finite JSON number {value}")
    def finite_float(value):
        converted = float(value)
        if not math.isfinite(converted):
            raise ValueError(f"{path}: non-finite JSON number {value}")
        return converted
    return json.loads(payload, object_pairs_hook=object_pairs, parse_constant=invalid_constant, parse_float=finite_float)


def load_json(path):
    return load_json_bytes(Path(path).read_bytes(), str(path))


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def text(value, context, *, allow_empty=False):
    if not isinstance(value, str) or (not allow_empty and not value.strip()):
        raise ValueError(f"{context}: expected {'a string' if allow_empty else 'nonempty text'}")
    return value


def identifier(value, context):
    text(value, context)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", value):
        raise ValueError(f"{context}: use a stable 1–128 character identifier")
    return value


def relative_path(value, context):
    text(value, context)
    if ("\\" in value or "\0" in value or value.startswith("/") or
            re.match(r"^[A-Za-z]:", value) or any(part in {"", ".", ".."} for part in value.split("/"))):
        raise ValueError(f"{context}: expected a normalized relative file path without traversal")
    return value


def source_uri(value, context, *, unknown=False):
    text(value, context)
    if unknown and value == "unknown":
        return value
    parsed = urlsplit(value)
    if parsed.scheme not in {"https", "http", "file", "generated"} or not (parsed.netloc or parsed.path):
        raise ValueError(f"{context}: expected a source URI or explicit 'unknown'")
    if parsed.scheme in {"http", "https"} and not parsed.netloc:
        raise ValueError(f"{context}: web source must name its host")
    return value


def validate_assets(assets, *, use=None):
    if use is not None and use not in USES:
        raise ValueError(f"unknown intended use {use!r}")
    if not isinstance(assets, list):
        raise ValueError("assets: expected a list")
    indexed, paths = {}, set()
    for position, asset in enumerate(assets):
        where = f"assets[{position}]"
        if not isinstance(asset, dict):
            raise ValueError(f"{where}: expected an object")
        ident = identifier(asset.get("asset_id"), f"{where}.asset_id")
        if ident in indexed:
            raise ValueError(f"{where}: duplicate asset_id {ident!r}")
        path = relative_path(asset.get("path"), f"{where}.path")
        if path.casefold() in paths:
            raise ValueError(f"{where}: duplicate/case-colliding asset path {path!r}")
        paths.add(path.casefold())
        digest = asset.get("sha256")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError(f"{where}.sha256: expected a lowercase SHA-256 digest")
        if asset.get("kind") not in KINDS:
            raise ValueError(f"{where}.kind: unknown asset kind")
        source = asset.get("source")
        if not isinstance(source, dict):
            raise ValueError(f"{where}.source: expected URI and release")
        source_uri(source.get("uri"), f"{where}.source.uri", unknown=True)
        text(source.get("release"), f"{where}.source.release")
        rights = asset.get("rights")
        if not isinstance(rights, dict) or rights.get("status") not in {"unknown", "recorded"}:
            raise ValueError(f"{where}.rights: status must be unknown or recorded")
        license_name = text(rights.get("license"), f"{where}.rights.license")
        note = text(rights.get("permission_note"), f"{where}.rights.permission_note", allow_empty=True)
        text(rights.get("attribution"), f"{where}.rights.attribution", allow_empty=True)
        terms = rights.get("terms_uri")
        if terms is not None:
            source_uri(terms, f"{where}.rights.terms_uri")
        permitted = rights.get("permitted_uses")
        if (not isinstance(permitted, list) or any(not isinstance(item, str) or item not in USES for item in permitted)
                or len(set(permitted)) != len(permitted)):
            raise ValueError(f"{where}.rights.permitted_uses: expected distinct declared uses")
        if rights["status"] == "unknown" and (permitted or license_name != "unknown"):
            raise ValueError(f"{where}: unknown rights cannot declare a license or permitted uses")
        if rights["status"] == "recorded" and license_name == "unknown" and not note.strip():
            raise ValueError(f"{where}: recorded rights require a license or permission note")
        if use is not None and (rights["status"] != "recorded" or use not in permitted):
            raise ValueError(f"{where} ({ident}): no recorded permission for {use}")
        indexed[ident] = asset
    return indexed


def validate_registry(document, *, use=None):
    if not isinstance(document, dict) or type(document.get("schema_version")) is not int or document["schema_version"] != SCHEMA_VERSION:
        raise ValueError("unsupported asset registry schema_version (expected integer 1)")
    return validate_assets(document.get("assets"), use=use)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("registry")
    parser.add_argument("--use", choices=sorted(USES), help="require an explicit recorded permission for this use")
    args = parser.parse_args(argv)
    try:
        records = validate_registry(load_json(args.registry), use=args.use)
    except (OSError, ValueError, TypeError) as error:
        parser.error(str(error))
    print(json.dumps(dict(status="valid", schema_version=SCHEMA_VERSION, assets=len(records),
                          unknown_rights=sum(a["rights"]["status"] == "unknown" for a in records.values()),
                          intended_use=args.use, verified_file_bytes=False), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
