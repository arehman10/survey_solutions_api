#!/usr/bin/env python3
"""Create consistent local SuSo distribution artifacts from a verified checkout.

This script does not build Java, run Stata, or upload anything. Run the tests
first. Only explicit distribution files are included; no credentials or git
metadata are read into the archive.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
import shutil
import zipfile
from pathlib import Path


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_zip(path: Path, entries: dict[str, bytes]) -> None:
    """Stable file order and timestamps make byte comparisons meaningful."""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name, data in sorted(entries.items()):
            info = zipfile.ZipInfo(name, (2026, 9, 5, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = (0o755 if name.endswith('.sh') else 0o644) << 16
            z.writestr(info, data)


def package(repo: Path, output: Path) -> Path:
    names = ("suso.ado", "suso.sthlp", "suso.jar", "suso.pkg", "stata.toc")
    for name in names:
        if not (repo / name).is_file():
            raise ValueError(f"Missing required distribution file: {name}")
    ado = (repo / "suso.ado").read_text(encoding="utf-8")
    match = re.match(r"\*! suso v(\d+\.\d+\.\d+) build ([^ ]+)", ado)
    if not match:
        raise ValueError("The ADO must start with a release version/build header")
    version, build = match.groups()
    if f'return local version "{version}"' not in ado:
        raise ValueError("suso version disagrees with the first ADO header")
    if f"v{version}" not in (repo / "suso.pkg").read_text():
        raise ValueError("Package version disagrees with the ADO")
    backend = re.search(r'return local expected_backend "([^"]+)"', ado)
    if not backend:
        raise ValueError("The ADO must declare its expected backend build")
    with zipfile.ZipFile(repo / "suso.jar") as jar:
        members = set(jar.namelist())
        required = {"org/worldbank/suso/Stata.class", "org/worldbank/suso/Qx.class",
                    "org/worldbank/suso/SfiCheck.class", "org/worldbank/suso/Http.class",
                    "org/worldbank/suso/Zip.class", "org/worldbank/suso/TransferFiles.class",
                    "org/worldbank/suso/ZipPublisher.class", "org/worldbank/suso/AtomicFiles.class"}
        if not required <= members:
            raise ValueError(f"JAR missing runtime classes: {required - members}")
        if any(n.startswith("com/stata/") for n in members):
            raise ValueError("Compile-only SFI classes must not be shipped in suso.jar")
        if backend.group(1).encode("ascii") not in jar.read("org/worldbank/suso/Stata.class"):
            raise ValueError("The packaged backend build disagrees with the ADO")
    for stem in ("Stata", "Qx", "SfiCheck", "Http", "Zip", "Json", "TransferFiles", "ZipPublisher", "AtomicFiles"):
        if not (repo / "src/org/worldbank/suso" / f"{stem}.java").is_file():
            raise ValueError(f"Missing backend source: {stem}.java")

    # Copy only after validating the canonical set.
    install = repo / "install"
    install.mkdir(exist_ok=True)
    for name in names:
        shutil.copy2(repo / name, install / name)
    digest = sha256(repo / "suso.jar")
    (repo / "suso.jar.sha256").write_text(digest + "  suso.jar\n", encoding="ascii")
    (repo / "suso_jar_base64.txt").write_text(
        base64.b64encode((repo / "suso.jar").read_bytes()).decode("ascii") + "\n",
        encoding="ascii",
    )
    if base64.b64decode((repo / "suso_jar_base64.txt").read_text()) != (repo / "suso.jar").read_bytes():
        raise ValueError("Base64 round trip failed")

    ssc = {f"install/{name}": (install / name).read_bytes() for name in names}
    if (install / "INSTALL.md").is_file():
        ssc["install/INSTALL.md"] = (install / "INSTALL.md").read_bytes()
    write_zip(repo / "ssc_submission.zip", ssc)

    entries: dict[str, bytes] = {}
    roots = [*names, "README.md", "LICENSE", "CHANGELOG_LOCAL.md", "TEST_RESULTS.md", "DOWNLOAD_SAFETY.md",
             "build.sh", "build.bat", "rebuild_jar.ps1", "suso.jar.sha256",
             "suso_jar_base64.txt", "suso_examples.do", "ssc_submission.zip"]
    for name in roots:
        p = repo / name
        if p.is_file():
            entries[name] = p.read_bytes()
    allowed_exts = {".py", ".js", ".mjs", ".java", ".md", ".json", ".html",
                    ".do", ".tab", ".csv", ".txt", ".sthlp", ".ado", ".pkg", ".toc", ".jar", ".zip", ".sh", ".bat", ".ps1"}
    for dirname in ("src", "install", "tools", "tests", "examples"):
        for p in sorted((repo / dirname).rglob("*")):
            if not p.is_file() or p.suffix not in allowed_exts:
                continue
            if any(part in {"node_modules", "__pycache__", ".pytest_cache", "build", "artifacts"}
                   for part in p.relative_to(repo / dirname).parts):
                continue
            entries[p.relative_to(repo).as_posix()] = p.read_bytes()
    manifest = {
        "version": version, "build": build,
        "upstream_commit": "0c41c81fa192b438b86ddb6db377942bd1e40104",
        "publication": "Local review build; not pushed to GitHub",
        "files": {name: hashlib.sha256(data).hexdigest() for name, data in sorted(entries.items())},
    }
    entries["release-manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"suso_v{version}_local_review.zip"
    write_zip(archive, entries)
    with zipfile.ZipFile(archive) as z:
        for name in names:
            if z.read(name) != z.read(f"install/{name}"):
                raise ValueError(f"Archive root/install mismatch: {name}")
        if base64.b64decode(z.read("suso_jar_base64.txt")) != z.read("suso.jar"):
            raise ValueError("Archive recovery payload mismatch")
        for name, expected in manifest["files"].items():
            if hashlib.sha256(z.read(name)).hexdigest() != expected:
                raise ValueError(f"Archive manifest mismatch: {name}")
    (output / f"{archive.name}.sha256").write_text(sha256(archive) + "  " + archive.name + "\n")
    print(json.dumps({"archive": str(archive), "version": version, "files": len(entries),
                      "sha256": sha256(archive), "root_install_equal": True,
                      "recovery_equal": True, "manifest_verified": True}, indent=2))
    return archive


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    package(args.repo.resolve(), args.output.resolve())
