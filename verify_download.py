#!/usr/bin/env python3
"""Verify a SuSo extracted folder against its locally recorded file hashes.

Usage: python3 tools/verify_download.py /path/to/extracted/folder
   or: python3 tools/verify_download.py /path/from/r(manifest)
This is a local integrity check, not authentication of the manifest or proof
that the server exported every survey record. No network requests are made.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath


def verify(location: Path) -> dict:
    location = location.absolute()
    if location.is_symlink():
        raise ValueError("The verification location must not be a symbolic link")
    if location.is_file():
        manifest = location
        if manifest.name == ".suso-manifest.json":
            folder = manifest.parent
        elif manifest.parent.name == ".suso-manifests" and manifest.suffix == ".json":
            folder = manifest.parent.parent
        else:
            raise ValueError("Use the extraction folder or the recorded r(manifest) path")
    else:
        folder = location
        manifest = folder / ".suso-manifest.json"
    if folder.is_symlink() or not folder.is_dir():
        raise ValueError("The extraction folder must be a real directory")
    if manifest.parent.is_symlink():
        raise ValueError("The manifest directory must not be a symbolic link")
    if manifest.is_symlink() or not manifest.is_file():
        raise ValueError("No regular extraction manifest found at the requested location")
    data = json.loads(manifest.read_text(encoding="utf-8"))
    version = data.get("version")
    if data.get("format") != "suso-extraction-manifest" or version not in (1, 2):
        raise ValueError("Unsupported extraction manifest format")
    if version == 2 and data.get("scope") != "archive-files":
        raise ValueError("Unsupported extraction manifest scope")
    entries = data.get("files")
    if not isinstance(entries, list) or len(entries) != data.get("file_count"):
        raise ValueError("Manifest file count is inconsistent")
    expected = set()
    total = 0
    problems = []
    for entry in entries:
        name = entry.get("path", "")
        path = PurePosixPath(name)
        if not name or path.is_absolute() or ".." in path.parts or "\\" in name or ":" in name:
            raise ValueError("Unsafe file path in manifest")
        if name in expected or name == ".suso-manifest.json" or (
                version == 2 and path.parts and path.parts[0].startswith(".suso-")):
            raise ValueError("Duplicate or reserved file path in manifest")
        expected.add(name)
        target = folder.joinpath(*path.parts)
        if any(p.is_symlink() for p in [target, *target.parents] if p != folder.parent):
            problems.append(f"Symbolic link rejected: {name}")
            continue
        if not target.is_file():
            problems.append(f"Missing file: {name}")
            continue
        size = target.stat().st_size
        total += size
        digest = hashlib.sha256()
        with target.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        if size != entry.get("bytes") or digest.hexdigest() != entry.get("sha256"):
            problems.append(f"Changed or damaged file: {name}")
    if version == 1:
        # Legacy manifests describe an isolated folder. Version 2 describes
        # one archive in a shared destination, where unrelated files stay.
        actual = set()
        for p in folder.rglob("*"):
            if p.is_symlink():
                problems.append(f"Unexpected symbolic link: {p.relative_to(folder).as_posix()}")
            elif p.is_file() and p != manifest:
                actual.add(p.relative_to(folder).as_posix())
        for extra in sorted(actual - expected):
            problems.append(f"Unrecorded file: {extra}")
    if total != data.get("bytes"):
        problems.append("Total file bytes differ from the recorded total")
    return {"ok": not problems, "scope": "archive-files" if version == 2 else "whole-folder",
            "manifest": str(manifest), "files": len(entries), "bytes": total, "problems": problems}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("location", type=Path)
    args = parser.parse_args()
    try:
        result = verify(args.location)
    except (OSError, ValueError, TypeError, KeyError, AttributeError) as error:
        parser.exit(1, f"FAIL: {error}\n")
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result["ok"] else 1)
