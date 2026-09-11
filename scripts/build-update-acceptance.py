#!/usr/bin/env python3
"""Build two notarized, formal-identity applications for an isolated update test.

This creates local artifacts only. It never installs, launches, uploads, or
changes the public stable feed.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
ACCEPTANCE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,79}\Z")
NOTES = """- 从 GitHub Pages 获取版本、完整更新说明和安装包信息。
- 下载后核对大小、SHA-256、签名及组件版本，安装前重新确认更新仍有效。
- 此包仅用于正式身份的更新验收，不进入正式更新清单。
"""


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--id", required=True, dest="acceptance_id")
    parser.add_argument("--lower-version", required=True)
    parser.add_argument("--higher-version", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--notary-profile", required=True)
    args = parser.parse_args()
    if not ACCEPTANCE_ID.fullmatch(args.acceptance_id):
        parser.error("invalid acceptance ID")
    versions = [args.lower_version, args.higher_version]
    if not all(VERSION.fullmatch(version) for version in versions):
        parser.error("both versions must be canonical MAJOR.MINOR.PATCH")
    if tuple(map(int, versions[0].split("."))) >= tuple(map(int, versions[1].split("."))):
        parser.error("the target version must be newer than the starting version")
    output = args.output.expanduser().resolve()
    if output.exists():
        parser.error("output directory already exists; choose a new acceptance run")
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip():
        parser.error("commit the accepted source changes before building the pair")
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    output.mkdir(parents=True)
    build_number = int(time.time())
    environment = dict(os.environ, NOTARY_KEYCHAIN_PROFILE=args.notary_profile)
    records = []
    for index, version in enumerate(versions):
        label = "A" if index == 0 else "B"
        target = output / f"{label}-{version}"
        target.mkdir()
        notes = target / "RELEASE_NOTES.md"
        notes.write_text(f"# XDial v{version}\n\n## 更新了什么\n\n{NOTES}", encoding="utf-8")
        log = target / "build.log"
        print(f"Building and notarizing {label}: {version} / {build_number + index}", flush=True)
        with log.open("w") as stream:
            subprocess.run(
                ["make", "release", f"RELEASE_TAG=v{version}",
                 f"RELEASE_BUILD_NUMBER={build_number + index}",
                 f"RELEASE_UPDATE_ACCEPTANCE_ID={args.acceptance_id}",
                 f"RELEASE_NOTES_FILE={notes}"],
                cwd=ROOT, env=environment, stdout=stream, stderr=subprocess.STDOUT, check=True,
            )
        source = ROOT / "build/release"
        names = ["XDial.app", f"XDial-v{version}.zip", f"XDial-v{version}.zip.sha256",
                 f"XDial-v{version}-notarization.json"]
        for name in names:
            subprocess.run(["ditto", str(source / name), str(target / name)], check=True)
        info = plistlib.loads((target / "XDial.app/Contents/Info.plist").read_bytes())
        if (info.get("CFBundleShortVersionString") != version
                or info.get("CFBundleVersion") != str(build_number + index)
                or info.get("CFBundleIdentifier") != "com.kafeifei.xdial.app"
                or info.get("XDialUpdateAcceptanceID") != args.acceptance_id):
            raise RuntimeError("signed acceptance package identity does not match the requested build")
        archive = target / f"XDial-v{version}.zip"
        records.append({
            "role": label, "version": version, "tag": f"v{version}",
            "build": str(build_number + index), "acceptanceID": args.acceptance_id,
            "minimumSystemVersion": info["LSMinimumSystemVersion"],
            "archive": str(archive), "archiveSize": archive.stat().st_size,
            "archiveSHA256": digest(archive), "releaseNotes": NOTES.strip(),
        })
        (output / "BUILD-INFO.json").write_text(json.dumps({
            "sourceCommit": commit, "acceptanceID": args.acceptance_id,
            "createdAt": dt.datetime.now(dt.timezone.utc).isoformat(), "packages": records,
            "installed": False, "launched": False, "uploaded": False,
        }, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Acceptance pair ready: {output}", flush=True)


if __name__ == "__main__":
    main()
