#!/usr/bin/env python3
"""Exercise post-download loss/change detection using independent fixtures."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("verify_download", root / "tools/verify_download.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory(prefix="suso-manifest-test-") as temporary:
    folder = Path(temporary)
    path = folder / "paradata.tab"
    payload = b"interview\tevent\n001\tAnswerSet\n"
    path.write_bytes(payload)
    manifest = {"format": "suso-extraction-manifest", "version": 1,
                "file_count": 1, "bytes": len(payload), "files": [
                    {"path": path.name, "bytes": len(payload),
                     "sha256": hashlib.sha256(payload).hexdigest()}]}
    record = folder / ".suso-manifest.json"
    record.write_text(json.dumps(manifest))
    assert module.verify(folder)["ok"]
    path.write_bytes(payload.replace(b"001", b"999"))
    assert not module.verify(folder)["ok"], "same-size corruption missed"
    path.unlink()
    assert not module.verify(folder)["ok"], "missing data file missed"
    path.write_bytes(payload)
    extra = folder / "unrecorded.txt"
    extra.write_text("unexpected")
    assert not module.verify(folder)["ok"], "unrecorded data file missed"
    extra.unlink()
    # An exact-destination manifest tracks its archive, while the user's
    # original ZIP, other exports and reports remain in the same directory.
    manifest.update(version=2, scope="archive-files")
    record.write_text(json.dumps(manifest))
    extra.write_text("my unrelated report")
    assert module.verify(folder)["ok"], "unrelated shared-folder file treated as corruption"
    histories = folder / ".suso-manifests"
    histories.mkdir()
    run_record = histories / "example-run.json"
    run_record.write_text(json.dumps(manifest))
    assert module.verify(run_record)["ok"], "per-run manifest cannot locate destination root"
    path.write_bytes(payload.replace(b"001", b"999"))
    assert not module.verify(run_record)["ok"], "version2 same-size corruption missed"
    path.unlink()
    assert not module.verify(run_record)["ok"], "version2 missing data file missed"
    path.write_bytes(payload)
    manifest["files"][0]["path"] = "../outside.tab"
    record.write_text(json.dumps(manifest))
    try:
        module.verify(folder)
        raise AssertionError("unsafe manifest path accepted")
    except ValueError:
        pass
print("PASS: v1/v2 manifests, same-size corruption, missing files, shared-folder scope, per-run manifests and unsafe paths")
