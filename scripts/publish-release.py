#!/usr/bin/env python3
"""Promote a verified release and explicitly deploy its Pages update feed.

Run on the signing/verification Mac with the operator's existing `gh` login.
No cross-repository credential is copied into Actions or the application.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
import zipfile
from pathlib import Path

SOURCE_REPOSITORY = "kafeifei/XDial"
SOURCE_GIT_URL = f"https://github.com/{SOURCE_REPOSITORY}.git"
PAGES_REPOSITORY = "saymiao/xdial-updates"
FEED_URL = "https://saymiao.github.io/xdial-updates/stable.json"
ROOT = Path(__file__).resolve().parents[1]
TAG_PATTERN = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
DRAFT_RELEASE_PATTERN = re.compile(r"untagged-[0-9a-f]{20}\Z")


def gh_json(*arguments: str):
    return json.loads(subprocess.check_output(["gh", *arguments], text=True))


def verify_remote_tag_on_main(tag: str, source_url: str = SOURCE_GIT_URL) -> str:
    """Return the remote tag's peeled commit after proving main first-parent ownership."""
    if not TAG_PATTERN.fullmatch(tag):
        raise ValueError("release tag must be canonical vMAJOR.MINOR.PATCH")
    with tempfile.TemporaryDirectory(prefix="xdial-source-git-") as directory_name:
        repository = Path(directory_name) / "source.git"
        subprocess.run(
            ["git", "init", "--bare", "--quiet", str(repository)],
            check=True,
        )
        main_ref = "refs/xdial-release/main"
        tag_ref = "refs/xdial-release/tag"
        try:
            subprocess.run(
                [
                    "git", "-C", str(repository), "fetch", "--no-tags",
                    source_url,
                    f"+refs/heads/main:{main_ref}",
                    f"+refs/tags/{tag}:{tag_ref}",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
        except subprocess.CalledProcessError:
            raise ValueError(
                f"cannot fetch {tag} and main from {SOURCE_REPOSITORY}"
            ) from None
        tagged_commit = subprocess.check_output(
            ["git", "-C", str(repository), "rev-parse", f"{tag_ref}^{{commit}}"],
            text=True,
        ).strip()
        main_commit = subprocess.check_output(
            ["git", "-C", str(repository), "rev-parse", f"{main_ref}^{{commit}}"],
            text=True,
        ).strip()
        main_history = set(
            subprocess.check_output(
                ["git", "-C", str(repository), "rev-list", "--first-parent", main_commit],
                text=True,
            ).splitlines()
        )
        if tagged_commit not in main_history:
            raise ValueError(
                f"remote tag {tag} must point to a commit on "
                f"{SOURCE_REPOSITORY} main's first-parent history"
            )
        return tagged_commit


def find_source_release(tag: str) -> dict:
    pages = gh_json(
        "api", f"repos/{SOURCE_REPOSITORY}/releases?per_page=100",
        "--paginate", "--slurp",
    )
    if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
        raise ValueError("cannot enumerate source releases")
    matches = [
        release
        for page in pages
        for release in page
        if isinstance(release, dict) and release.get("tag_name") == tag
    ]
    if len(matches) != 1:
        raise ValueError(f"expected exactly one source release for {tag}")
    release_id = matches[0].get("id")
    if not isinstance(release_id, int) or isinstance(release_id, bool) or release_id <= 0:
        raise ValueError("source release ID is missing")
    return matches[0]


def validate_release(release: dict, tag: str) -> tuple[str, str]:
    if not TAG_PATTERN.fullmatch(tag):
        raise ValueError("release tag must be canonical vMAJOR.MINOR.PATCH")
    if release.get("tag_name") != tag or release.get("prerelease") is not False:
        raise ValueError("only the exact stable release can be promoted")
    if not isinstance(release.get("draft"), bool):
        raise ValueError("release draft state is missing")
    if not isinstance(release.get("body"), str) or not release["body"].strip():
        raise ValueError("release notes must not be empty")
    archive = f"XDial-{tag}.zip"
    checksum = f"{archive}.sha256"
    if release["draft"]:
        html_prefix = f"https://github.com/{SOURCE_REPOSITORY}/releases/tag/"
        html_url = release.get("html_url", "")
        draft_name = html_url.removeprefix(html_prefix)
        if not html_url.startswith(html_prefix) or not DRAFT_RELEASE_PATTERN.fullmatch(draft_name):
            raise ValueError("draft release URL is unexpected")
        download_name = draft_name
    else:
        expected_html_url = f"https://github.com/{SOURCE_REPOSITORY}/releases/tag/{tag}"
        if release.get("html_url") != expected_html_url:
            raise ValueError("published release URL is unexpected")
        download_name = tag
    for name in (archive, checksum):
        assets = [asset for asset in release.get("assets", []) if asset.get("name") == name]
        expected = f"https://github.com/{SOURCE_REPOSITORY}/releases/download/{download_name}/{name}"
        if len(assets) != 1 or assets[0].get("browser_download_url") != expected:
            raise ValueError(f"missing or unexpected release asset: {name}")
        if assets[0].get("state") != "uploaded" or assets[0].get("size", 0) <= 0:
            raise ValueError(f"release asset is not ready: {name}")
    return archive, checksum


def verify_archive(directory: Path, archive: str, tag: str) -> tuple[str, str]:
    path = directory / archive
    if not 0 < path.stat().st_size <= 512 * 1024 * 1024:
        raise ValueError("release archive exceeds the supported size")
    with zipfile.ZipFile(path) as bundle:
        info_entry = bundle.getinfo("XDial.app/Contents/Info.plist")
        if info_entry.file_size > 128 * 1024:
            raise ValueError("invalid application Info.plist size")
        info = plistlib.loads(bundle.read(info_entry))
    build = info.get("CFBundleVersion", "")
    if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("invalid application build number")
    acceptance_id = info.get("XDialUpdateAcceptanceID", "")
    if not isinstance(acceptance_id, str) or acceptance_id:
        raise ValueError("an acceptance package must never become a stable public update")
    subprocess.run(
        [str(ROOT / "scripts/release-contract.sh"), "verify-archive", str(path), tag, build],
        check=True,
    )
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return build, digest.hexdigest()


def dispatch_and_wait(tag: str, timeout: int) -> str:
    request_id = uuid.uuid4().hex
    subprocess.run(
        ["gh", "workflow", "run", "publish.yml", "--repo", PAGES_REPOSITORY,
         "--ref", "main", "-f", f"release_tag={tag}", "-f", "operation=publish",
         "-f", f"request_id={request_id}"],
        check=True,
    )
    deadline = time.monotonic() + timeout
    run = None
    while time.monotonic() < deadline:
        result = gh_json(
            "api", f"repos/{PAGES_REPOSITORY}/actions/workflows/publish.yml/runs"
            "?event=workflow_dispatch&per_page=30",
        )
        run = next((item for item in result["workflow_runs"]
                    if request_id in item.get("display_title", "")), None)
        if run:
            break
        time.sleep(5)
    if not run:
        raise TimeoutError(f"Pages workflow was dispatched but its run was not found ({request_id})")
    print(f"Pages deployment: {run['html_url']}", flush=True)
    subprocess.run(
        ["gh", "run", "watch", str(run["id"]), "--repo", PAGES_REPOSITORY,
         "--interval", "10", "--exit-status"],
        check=True,
        timeout=max(1, deadline - time.monotonic()),
    )
    return run["html_url"]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("the canonical Pages feed must not redirect")


def verify_feed(tag: str, build: str, digest: str) -> None:
    opener = urllib.request.build_opener(NoRedirect())
    deadline = time.monotonic() + 180
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            request = urllib.request.Request(FEED_URL, headers={"Cache-Control": "no-cache"})
            with opener.open(request, timeout=10) as response:
                data = response.read(512 * 1024 + 1)
                if response.status != 200 or len(data) > 512 * 1024:
                    raise ValueError("invalid Pages response")
            feed = json.loads(data)
            release = feed.get("release") or {}
            if (feed.get("schemaVersion") != 1 or feed.get("channel") != "stable"
                    or release.get("tag") != tag or release.get("build") != build
                    or release.get("archiveSHA256") != digest
                    or not release.get("releaseNotes", "").strip()):
                raise ValueError("Pages has not served the verified release and its complete notes")
            return
        except (OSError, ValueError) as error:
            last_error = error
            time.sleep(5)
    raise RuntimeError(f"release is public but Pages verification is incomplete: {last_error}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="the already built and accepted stable release tag")
    parser.add_argument("--pages-timeout", type=int, default=900)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("run on macOS so the downloaded app can pass signing and notarization gates")
    if not TAG_PATTERN.fullmatch(args.tag) or args.pages_timeout <= 0:
        parser.error("provide a canonical stable tag and a positive timeout")

    verify_remote_tag_on_main(args.tag)
    release = find_source_release(args.tag)
    archive, checksum = validate_release(release, args.tag)
    latest = gh_json("api", f"repos/{SOURCE_REPOSITORY}/releases/latest")
    latest_tag = latest.get("tag_name", "")
    if not TAG_PATTERN.fullmatch(latest_tag):
        raise ValueError("cannot verify the currently published stable release")
    if tuple(map(int, latest_tag[1:].split("."))) > tuple(map(int, args.tag[1:].split("."))):
        raise ValueError("refusing to replace a newer published release with an older tag")
    with tempfile.TemporaryDirectory(prefix="xdial-publish-") as directory_name:
        directory = Path(directory_name)
        print("Downloading and verifying the exact release assets before publication…", flush=True)
        subprocess.run(
            ["gh", "release", "download", args.tag, "--repo", SOURCE_REPOSITORY,
             "--pattern", archive, "--pattern", checksum, "--dir", str(directory)],
            check=True,
        )
        build, digest = verify_archive(directory, archive, args.tag)
        if release["draft"]:
            subprocess.run(
                ["gh", "release", "edit", args.tag, "--repo", SOURCE_REPOSITORY,
                 "--draft=false", "--latest"],
                check=True,
            )
            published = gh_json(
                "api", f"repos/{SOURCE_REPOSITORY}/releases/{release['id']}"
            )
            if published.get("id") != release["id"] or published.get("draft") is not False:
                raise ValueError("the exact source release was not published")
            validate_release(published, args.tag)
        print(f"Release is public: https://github.com/{SOURCE_REPOSITORY}/releases/tag/{args.tag}", flush=True)
        dispatch_and_wait(args.tag, args.pages_timeout)
        verify_feed(args.tag, build, digest)
        print(f"Publication verified: {FEED_URL} ({args.tag}, build {build})", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
