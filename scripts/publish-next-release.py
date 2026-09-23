#!/usr/bin/env python3
"""Publish a verified Next archive without touching the stable release/feed."""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "kafeifei/XDial"
TAG_PATTERN = re.compile(r"next-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")


def run(*args, **kwargs):
    return subprocess.check_output(args, cwd=ROOT, text=True, **kwargs).strip()


def gh(*args):
    return json.loads(run("gh", *args))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_remote_source(tag, revision, refs):
    require(TAG_PATTERN.fullmatch(tag), "tag must be next-vMAJOR.MINOR.PATCH")
    require(refs.get("refs/heads/xdial-next") == revision, "release must match remote xdial-next HEAD")
    tagged = refs.get(f"refs/tags/{tag}^{{}}", refs.get(f"refs/tags/{tag}"))
    require(tagged == revision, "remote Next tag does not match the verified source")


def validate_assets(release, tag, digests):
    require(release.get("tag_name") == tag and release.get("prerelease") is True,
            "release must belong to the exact Next prerelease tag")
    assets = release.get("assets", [])
    require(len(assets) == len(digests), "unexpected or missing Next release assets")
    for asset in assets:
        name = asset.get("name")
        require(name in digests, "unexpected Next release asset")
        require(asset.get("state") == "uploaded", "Next asset upload is incomplete")
        require(asset.get("digest") == "sha256:" + digests[name],
                f"GitHub asset differs from verified local archive: {name}")
    require({asset.get("name") for asset in assets} == set(digests), "duplicate Next assets")


def publish(tag):
    require(TAG_PATTERN.fullmatch(tag), "tag must be next-vMAJOR.MINOR.PATCH")
    require(not run("git", "status", "--porcelain"), "Next release worktree must be clean")
    revision = run("git", "rev-parse", "HEAD")
    require(run("git", "rev-parse", f"refs/tags/{tag}^{{commit}}") == revision,
            "local Next tag must match HEAD")
    repository_url = f"https://github.com/{REPOSITORY}.git"
    refs = {ref: sha for sha, ref in (line.split() for line in run(
        "git", "ls-remote", repository_url, "refs/heads/xdial-next",
        f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}"
    ).splitlines())}
    validate_remote_source(tag, revision, refs)
    require(gh("api", f"repos/{REPOSITORY}").get("visibility") == "public", "unexpected repository visibility")
    archive = ROOT / "build/next-release" / f"XDial-Next-{tag}.zip"
    checksum = archive.with_suffix(archive.suffix + ".sha256")
    app = ROOT / "build/next-release/XDial Next.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    environment = {**os.environ, "XDIAL_RELEASE_CHANNEL": "next"}
    subprocess.run([str(ROOT / "scripts/release-contract.sh"), "verify-archive",
                    str(archive), tag, info["CFBundleVersion"]],
                   env=environment, cwd=ROOT, check=True)
    notes = ROOT / "NEXT_RELEASE_NOTES.md"
    subprocess.run([str(ROOT / "scripts/release-contract.sh"), "validate-notes", tag, str(notes)],
                   env=environment, cwd=ROOT, check=True)
    digests = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in (archive, checksum)}
    pages = gh("api", f"repos/{REPOSITORY}/releases?per_page=100", "--paginate", "--slurp")
    matching = [release for page in pages for release in page if release.get("tag_name") == tag]
    require(len(matching) <= 1, "ambiguous Next release")
    if not matching:
        subprocess.run(["gh", "release", "create", tag, str(archive), str(checksum),
                        "--repo", REPOSITORY, "--verify-tag", "--draft", "--prerelease", "--latest=false",
                        "--target", revision, "--title", f"XDial Next {tag.removeprefix('next-')}",
                        "--notes-file", str(notes)], cwd=ROOT, check=True)
    release = gh("api", f"repos/{REPOSITORY}/releases/tags/{tag}")
    validate_assets(release, tag, digests)
    require(release.get("body", "").strip() == notes.read_text().strip(), "remote Next release notes differ")
    if release.get("draft"):
        subprocess.run(["gh", "release", "edit", tag, "--repo", REPOSITORY,
                        "--draft=false", "--prerelease", "--latest=false"], cwd=ROOT, check=True)
    release = gh("api", f"repos/{REPOSITORY}/releases/tags/{tag}")
    validate_assets(release, tag, digests)
    require(release.get("draft") is False, "Next release is still a draft")
    print(release["html_url"])


if __name__ == "__main__":
    try:
        require(len(sys.argv) == 2, "usage: publish-next-release.py next-vMAJOR.MINOR.PATCH")
        publish(sys.argv[1])
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
