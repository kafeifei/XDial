#!/usr/bin/env python3
"""Promote a verified release and deploy its Pages update feed.

release.yml runs this after building the draft, with --pages follow: it makes
the release public with the workflow's own token, and the update repository's
follow workflow, which polls public XDial releases, deploys the feed. An
operator can run it on a Mac with their `gh` login, where --pages dispatch (the
default) starts the update repository's publish.yml directly. No
cross-repository credential is copied into Actions or the application.

Stable is the default channel. `--channel beta` promotes the GitHub prerelease
vX.Y.Z-beta.N built from xdial-beta and writes beta.json. Both channels ship
the formal identity; the channel only selects the tag, branch and feed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
import zipfile
from pathlib import Path, PurePosixPath
from types import MappingProxyType
from typing import Mapping, NamedTuple

SOURCE_REPOSITORY = "kafeifei/XDial"
SOURCE_GIT_URL = f"https://github.com/{SOURCE_REPOSITORY}.git"
PAGES_REPOSITORY = "saymiao/xdial-updates"
PAGES_GIT_URL = f"https://github.com/{PAGES_REPOSITORY}.git"
FOLLOW_WORKFLOW_URL = f"https://github.com/{PAGES_REPOSITORY}/actions/workflows/follow.yml"
# dispatch: start the update repository's publish.yml from here.
# follow: leave that to its follow workflow and wait for the feed.
PAGES_MODES = ("dispatch", "follow")
PAGES_TIMEOUTS = {"dispatch": 900, "follow": 3600}
# fetch and clone otherwise start a detached `git maintenance run --auto`,
# which can still be writing objects/maintenance.lock while the temporary
# repository is removed.
GIT_WITHOUT_MAINTENANCE = ("git", "-c", "maintenance.auto=false")
STABLE = "stable"
BETA = "beta"
CHANNELS = (STABLE, BETA)
FEED_URLS = {
    STABLE: "https://saymiao.github.io/xdial-updates/stable.json",
    BETA: "https://saymiao.github.io/xdial-updates/beta.json",
}
ROOT = Path(__file__).resolve().parents[1]
TAG_PATTERN = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
BETA_TAG_PATTERN = re.compile(
    r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-beta\.([1-9][0-9]*)\Z"
)
TAG_PATTERNS = {STABLE: TAG_PATTERN, BETA: BETA_TAG_PATTERN}
TAG_FORMS = {STABLE: "vMAJOR.MINOR.PATCH", BETA: "vMAJOR.MINOR.PATCH-beta.N"}
RELEASE_BRANCHES = {STABLE: "main", BETA: "xdial-beta"}
BUILD_PATTERN = re.compile(r"[1-9][0-9]*\Z")
DRAFT_RELEASE_PATTERN = re.compile(r"untagged-[0-9a-f]{20}\Z")
# Stable kept its paths when the Pages repository gained beta.
FEED_STATE_PATHS = {
    STABLE: ("site/stable.json", "state/ledger.json", "state/history"),
    BETA: ("site/beta.json", "state/beta/ledger.json", "state/beta/history"),
}
FEED_KEYS = ("schemaVersion", "revision", "channel", "generatedAt", "release")
RELEASE_KEYS = (
    "tag", "version", "build", "minimumSystemVersion", "publishedAt",
    "releaseNotes", "archiveURL", "archiveSize", "archiveSHA256",
)
# The Pages publisher serves this section of the release body as releaseNotes.
NOTES_HEADINGS = {"更新了什么", "更新内容", "更新"}
# Only preset configuration packages embed these, and they are never beta.
PRIVATE_CONFIGURATION_NAMES = {"SeedProfile", "RuleSetPresets.json"}
BETA_FOLLOWUPS = ("republish", "withdraw")


def gh_json(*arguments: str):
    return json.loads(subprocess.check_output(["gh", *arguments], text=True))


def tag_key(tag: str, channel: str = STABLE) -> tuple[int, ...]:
    """Order within a channel: (X, Y, Z) for stable, (X, Y, Z, N) for beta."""
    match = TAG_PATTERNS[channel].fullmatch(tag) if isinstance(tag, str) else None
    if not match:
        raise ValueError(f"release tag must be canonical {TAG_FORMS[channel]}")
    return tuple(int(part) for part in match.groups())


def tag_version(tag: str, channel: str) -> tuple[int, int, int]:
    return tag_key(tag, channel)[:3]


def tag_channel(tag) -> str | None:
    for channel in CHANNELS:
        if isinstance(tag, str) and TAG_PATTERNS[channel].fullmatch(tag):
            return channel
    return None


def release_order(tag: str) -> tuple[int, ...]:
    """SemVer order across channels, as clients compare: vX.Y.Z-beta.N < vX.Y.Z."""
    channel = tag_channel(tag)
    if channel is None:
        raise ValueError(f"not a release tag: {tag}")
    key = tag_key(tag, channel)
    return (*key[:3], 1, 0) if channel == STABLE else (*key[:3], 0, key[3])


def next_beta_tag(tag: str) -> str:
    key = tag_key(tag, BETA)
    return f"v{key[0]}.{key[1]}.{key[2]}-beta.{key[3] + 1}"


def latest_remote_stable_tag(source_url: str = SOURCE_GIT_URL) -> str:
    try:
        output = subprocess.run(
            ["git", "ls-remote", "--tags", "--refs", source_url],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    except subprocess.CalledProcessError:
        raise ValueError(f"cannot list the tags of {SOURCE_REPOSITORY}") from None
    tags = [
        line.split("\t", 1)[1].removeprefix("refs/tags/")
        for line in output.splitlines()
        if "\t" in line
    ]
    stable = [tag for tag in tags if TAG_PATTERN.fullmatch(tag)]
    if not stable:
        raise ValueError(f"{SOURCE_REPOSITORY} has no stable release tag")
    return max(stable, key=tag_key)


def verify_remote_tag(tag: str, channel: str = STABLE, source_url: str = SOURCE_GIT_URL) -> str:
    """Return the remote tag's peeled commit after proving its branch ownership.

    The tag must be on the first-parent history of main (stable) or xdial-beta
    (beta). A beta must also contain the newest stable tag and sort above it,
    so it carries every stable fix and the next stable release replaces it,
    and must keep main's shared formats. That gate runs this checkout's
    scripts/check-beta-shared-formats.sh, so a beta cannot shorten the list.
    """
    tag_key(tag, channel)
    branch = RELEASE_BRANCHES[channel]
    latest_stable = latest_remote_stable_tag(source_url) if channel == BETA else None
    with tempfile.TemporaryDirectory(prefix="xdial-source-git-") as directory_name:
        repository = Path(directory_name) / "source.git"
        subprocess.run(
            ["git", "init", "--bare", "--quiet", str(repository)],
            check=True,
        )
        branch_ref = f"refs/xdial-release/{branch}"
        tag_ref = "refs/xdial-release/tag"
        stable_ref = "refs/xdial-release/stable"
        main_ref = "refs/xdial-release/main"
        refspecs = [f"+refs/heads/{branch}:{branch_ref}", f"+refs/tags/{tag}:{tag_ref}"]
        if latest_stable:
            refspecs += [f"+refs/tags/{latest_stable}:{stable_ref}", f"+refs/heads/main:{main_ref}"]
        try:
            subprocess.run(
                [
                    *GIT_WITHOUT_MAINTENANCE, "-C", str(repository), "fetch", "--no-tags",
                    source_url, *refspecs,
                ],
                check=True,
                capture_output=True,
                text=True,
            )
        except subprocess.CalledProcessError:
            raise ValueError(
                f"cannot fetch {tag} and {branch}{', main' if latest_stable else ''} "
                f"from {SOURCE_REPOSITORY}"
            ) from None
        tagged_commit = subprocess.check_output(
            ["git", "-C", str(repository), "rev-parse", f"{tag_ref}^{{commit}}"],
            text=True,
        ).strip()
        branch_commit = subprocess.check_output(
            ["git", "-C", str(repository), "rev-parse", f"{branch_ref}^{{commit}}"],
            text=True,
        ).strip()
        branch_history = set(
            subprocess.check_output(
                ["git", "-C", str(repository), "rev-list", "--first-parent", branch_commit],
                text=True,
            ).splitlines()
        )
        if tagged_commit not in branch_history:
            raise ValueError(
                f"remote tag {tag} must point to a commit on "
                f"{SOURCE_REPOSITORY} {branch}'s first-parent history"
            )
        if latest_stable:
            stable_commit = subprocess.check_output(
                ["git", "-C", str(repository), "rev-parse", f"{stable_ref}^{{commit}}"],
                text=True,
            ).strip()
            contained = subprocess.run(
                ["git", "-C", str(repository), "merge-base", "--is-ancestor",
                 stable_commit, tagged_commit],
                capture_output=True,
            ).returncode == 0
            if not contained:
                raise ValueError(f"beta tag {tag} must contain the latest stable tag {latest_stable}")
            if tag_version(tag, BETA) <= tag_key(latest_stable):
                raise ValueError(f"beta tag {tag} must be newer than the latest stable tag {latest_stable}")
            shared = subprocess.run(
                [str(ROOT / "scripts/check-beta-shared-formats.sh"), main_ref, tag_ref],
                env={**os.environ, "GIT_DIR": str(repository)},
                capture_output=True,
                text=True,
            )
            if shared.returncode != 0:
                raise ValueError(
                    f"beta tag {tag} must keep the formats it shares with {SOURCE_REPOSITORY} main:\n"
                    f"{shared.stderr.strip()}"
                )
        return tagged_commit


def verify_remote_tag_on_main(tag: str, source_url: str = SOURCE_GIT_URL) -> str:
    """Return the remote tag's peeled commit after proving main first-parent ownership."""
    return verify_remote_tag(tag, STABLE, source_url)


def verify_remote_beta_tag(tag: str, source_url: str = SOURCE_GIT_URL) -> str:
    """Return the remote beta tag's peeled commit after proving xdial-beta ownership."""
    return verify_remote_tag(tag, BETA, source_url)


def list_source_releases() -> list[dict]:
    pages = gh_json(
        "api", f"repos/{SOURCE_REPOSITORY}/releases?per_page=100",
        "--paginate", "--slurp",
    )
    if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
        raise ValueError("cannot enumerate source releases")
    return [release for page in pages for release in page if isinstance(release, dict)]


def find_source_release(tag: str, releases: list[dict] | None = None) -> dict:
    if releases is None:
        releases = list_source_releases()
    matches = [release for release in releases if release.get("tag_name") == tag]
    if len(matches) != 1:
        raise ValueError(f"expected exactly one source release for {tag}")
    release_id = matches[0].get("id")
    if not isinstance(release_id, int) or isinstance(release_id, bool) or release_id <= 0:
        raise ValueError("source release ID is missing")
    return matches[0]


def validate_release(release: dict, tag: str, channel: str = STABLE) -> tuple[str, str]:
    tag_key(tag, channel)
    if release.get("tag_name") != tag or release.get("prerelease") is not (channel == BETA):
        raise ValueError(
            "only the exact stable release can be promoted" if channel == STABLE
            else "only the exact beta prerelease can be promoted"
        )
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


def verify_archive(directory: Path, archive: str, tag: str, channel: str = STABLE) -> tuple[str, str]:
    path = directory / archive
    if not 0 < path.stat().st_size <= 512 * 1024 * 1024:
        raise ValueError("release archive exceeds the supported size")
    with zipfile.ZipFile(path) as bundle:
        info_entry = bundle.getinfo("XDial.app/Contents/Info.plist")
        if info_entry.file_size > 128 * 1024:
            raise ValueError("invalid application Info.plist size")
        info = plistlib.loads(bundle.read(info_entry))
        names = bundle.namelist()
    build = info.get("CFBundleVersion", "")
    if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("invalid application build number")
    acceptance_id = info.get("XDialUpdateAcceptanceID", "")
    if not isinstance(acceptance_id, str) or acceptance_id:
        raise ValueError("an acceptance package must never become a stable public update")
    if channel == BETA:
        # Clients recognize an installed beta only by this key; see the release contract.
        if info.get("XDialReleaseTag") != tag:
            raise ValueError(f"a beta package must carry XDialReleaseTag {tag}")
        private = sorted(
            name for name in names
            if PRIVATE_CONFIGURATION_NAMES.intersection(PurePosixPath(name).parts)
        )
        if private:
            raise ValueError(f"a beta package must not embed private configuration: {', '.join(private)}")
    subprocess.run(
        [str(ROOT / "scripts/release-contract.sh"), "verify-archive", str(path), tag, build],
        check=True,
        env={**os.environ, "XDIAL_RELEASE_CHANNEL": channel},
    )
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return build, digest.hexdigest()


class PublishedPackage(NamedTuple):
    channel: str
    tag: str
    version: tuple[int, int, int]
    build: int


class FeedState(NamedTuple):
    """Both feeds as the Pages repository's main records them."""

    # Every package either feed ever published, withdrawn ones included.
    packages: tuple[PublishedPackage, ...] = ()
    # Current feed per channel; beta is None while the Pages repository has none.
    feeds: Mapping[str, dict | None] = MappingProxyType({})
    withdrawn: frozenset[str] = frozenset()


def read_json_file(path: Path, label: str):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise ValueError(f"cannot read {label} from {PAGES_REPOSITORY}") from None


def load_feed_state(source_url: str = PAGES_GIT_URL) -> FeedState:
    """Read both channels' feeds, ledgers and history from the Pages repository.

    Ledgers do not record builds. As in the Pages publisher, each tag's build
    comes from the history revision that first published it, so withdrawn
    packages still count and a missing or altered record fails closed.
    """
    with tempfile.TemporaryDirectory(prefix="xdial-pages-state-") as directory_name:
        root = Path(directory_name) / "pages"
        try:
            subprocess.run(
                [*GIT_WITHOUT_MAINTENANCE, "clone", "--quiet", "--depth", "1", "--branch", "main",
                 source_url, str(root)],
                check=True,
                capture_output=True,
                text=True,
            )
        except subprocess.CalledProcessError:
            raise ValueError(f"cannot read the feed state of {PAGES_REPOSITORY}") from None
        packages: list[PublishedPackage] = []
        feeds: dict = {}
        withdrawn: set[str] = set()
        for channel, (feed_path, ledger_path, history_path) in FEED_STATE_PATHS.items():
            if (channel == BETA and not (root / feed_path).exists()
                    and not (root / "state/beta").exists()):
                feeds[channel] = None
                continue
            feed = read_json_file(root / feed_path, feed_path)
            ledger = read_json_file(root / ledger_path, ledger_path)
            if not isinstance(feed, dict) or feed.get("channel") != channel:
                raise ValueError(f"{PAGES_REPOSITORY} {feed_path} is not the {channel} feed")
            records = ledger.get("releases") if isinstance(ledger, dict) else None
            if not isinstance(records, dict):
                raise ValueError(f"{PAGES_REPOSITORY} {ledger_path} has no release ledger")
            for tag, record in records.items():
                revision = record.get("publishedRevision") if isinstance(record, dict) else None
                message = f"{channel} history revision {revision} cannot prove the build of {tag}"
                if type(revision) is not int:
                    raise ValueError(message)
                history = read_json_file(root / history_path / f"{revision}.json",
                                         f"{history_path}/{revision}.json")
                release = history.get("release") if isinstance(history, dict) else None
                if not (
                    isinstance(release, dict)
                    and history.get("revision") == revision
                    and release.get("tag") == tag
                    and release.get("archiveSHA256") == record.get("archiveSHA256")
                    and isinstance(release.get("build"), str)
                    and BUILD_PATTERN.fullmatch(release["build"])
                ):
                    raise ValueError(message)
                packages.append(PublishedPackage(
                    channel, tag, tag_version(tag, channel), int(release["build"])
                ))
                if record.get("status") == "withdrawn":
                    withdrawn.add(tag)
            feeds[channel] = feed
        return FeedState(tuple(packages), feeds, frozenset(withdrawn))


def read_release_build(tag: str) -> int:
    """Read the build of a public release that no feed history records."""
    archive = f"XDial-{tag}.zip"
    with tempfile.TemporaryDirectory(prefix="xdial-build-gate-") as directory_name:
        try:
            subprocess.run(
                ["gh", "release", "download", tag, "--repo", SOURCE_REPOSITORY,
                 "--pattern", archive, "--dir", directory_name],
                check=True,
            )
        except subprocess.CalledProcessError:
            raise ValueError(f"cannot download {archive} to read the build of {tag}") from None
        path = Path(directory_name) / archive
        if not 0 < path.stat().st_size <= 512 * 1024 * 1024:
            raise ValueError(f"{archive} exceeds the supported size")
        try:
            with zipfile.ZipFile(path) as bundle:
                info = plistlib.loads(bundle.read("XDial.app/Contents/Info.plist"))
        except (KeyError, zipfile.BadZipFile, plistlib.InvalidFileException):
            raise ValueError(f"cannot read the build of {tag} from {archive}") from None
    build = info.get("CFBundleVersion", "") if isinstance(info, dict) else ""
    if not isinstance(build, str) or not BUILD_PATTERN.fullmatch(build):
        raise ValueError(f"public release {tag} has an invalid build number")
    return int(build)


def published_packages(releases: list[dict], feed_state: FeedState,
                       tag: str, channel: str) -> list[PublishedPackage]:
    """Every public package whose X.Y.Z can constrain the new build.

    Feed history covers what either feed ever published, withdrawn packages
    included. A public GitHub release that no feed recorded (for example one
    whose Pages run never succeeded) can still have been installed by hand,
    so its build is read from its archive.
    """
    version = tag_version(tag, channel)
    packages = list(feed_state.packages)
    recorded = {package.tag for package in packages}
    for release in releases:
        other = release.get("tag_name")
        other_channel = tag_channel(other)
        if (release.get("draft") is not False or other_channel is None
                or other == tag or other in recorded
                or tag_version(other, other_channel) > version):
            continue
        packages.append(PublishedPackage(
            other_channel, other, tag_version(other, other_channel), read_release_build(other)
        ))
    return packages


def require_build_gate(tag: str, channel: str, build: str, packages) -> None:
    """Require a build above every published package whose X.Y.Z is not newer.

    Both channels count, withdrawn packages included: a lower build cannot
    replace an installed System Extension. A package with a higher X.Y.Z does
    not constrain the build, so a stable hotfix below an open beta line need
    not outrank that beta. The Pages publisher enforces the same rule; this
    check keeps a package it would refuse from becoming public first.
    """
    version = tag_version(tag, channel)
    for package in packages:
        if package.tag == tag:
            if package.build != int(build):
                raise ValueError(f"{tag} was already published with build {package.build}, not {build}")
            continue
        if package.version <= version and int(build) <= package.build:
            raise ValueError(
                f"build {build} of {tag} must be greater than build {package.build} "
                f"of published {package.channel} {package.tag}"
            )


def require_channel_order(tag: str, channel: str, releases: list[dict],
                          latest_tag: str, feed_state: FeedState) -> None:
    """Refuse, before publication, what the Pages publisher would refuse after it."""
    if tag in feed_state.withdrawn:
        raise ValueError(f"{tag} was withdrawn from the {channel} feed and cannot be published again")
    published = [package.tag for package in feed_state.packages
                 if package.channel == channel and package.tag != tag]
    if published and tag_key(tag, channel) <= max(tag_key(other, channel) for other in published):
        raise ValueError(f"{tag} is not newer than every release the {channel} feed has published")
    if channel != BETA:
        return
    if feed_state.feeds.get(BETA) is None:
        raise ValueError(f"{PAGES_REPOSITORY} has no beta feed yet; deploy beta.json before a beta")
    stable = [latest_tag]
    stable += [package.tag for package in feed_state.packages if package.channel == STABLE]
    stable += [
        release.get("tag_name") for release in releases
        if release.get("draft") is False and TAG_PATTERN.fullmatch(release.get("tag_name") or "")
    ]
    highest = max(stable, key=tag_key)
    if tag_version(tag, BETA) <= tag_key(highest):
        raise ValueError(f"beta {tag} must be newer than every published stable release (highest is {highest})")


def lagging_beta_release(feed_state: FeedState, tag: str, build: str) -> dict | None:
    """The beta.json entry that clients would refuse once this stable is installed.

    A client offers a candidate only when its tag sorts above the installed
    release, then refuses it as build_not_newer unless its build is strictly
    higher. A beta entry with a newer tag but a build that is not above this
    stable's (an equal build included) therefore fails every check for users
    who install this stable with beta enabled, until a beta.N+1 replaces it or
    it is withdrawn. A beta entry that this stable sorts above is merely
    superseded and needs no follow-up.
    """
    feed = feed_state.feeds.get(BETA)
    release = feed.get("release") if isinstance(feed, dict) else None
    if release is None:
        return None
    beta_tag = release.get("tag") if isinstance(release, dict) else None
    beta_build = release.get("build") if isinstance(release, dict) else None
    if (tag_channel(beta_tag) != BETA or not isinstance(beta_build, str)
            or not BUILD_PATTERN.fullmatch(beta_build)):
        raise ValueError(f"{PAGES_REPOSITORY} beta.json has an invalid release entry")
    if release_order(beta_tag) > release_order(tag) and int(beta_build) <= int(build):
        return release
    return None


def beta_followup_notice(beta: dict, tag: str, build: str) -> str:
    rule = "!" * 78
    return "\n".join([
        rule,
        f"beta.json offers {beta['tag']} (build {beta['build']}): a newer tag than {tag},",
        f"but a build not above {build}. Users who install {tag} with beta enabled",
        "will see build_not_newer on every update check until beta.json changes.",
        "In the same batch, once this stable release is verified, either:",
        f"  republish  publish {next_beta_tag(beta['tag'])} from xdial-beta with {tag} merged in",
        f"  withdraw   withdraw {beta['tag']} from beta.json",
        "Confirm which with RELEASE_BETA_FOLLOWUP=republish|withdraw (--beta-followup).",
        rule,
    ])


def beta_followup_steps(beta: dict, tag: str, choice: str) -> str:
    if choice == "republish":
        upcoming = next_beta_tag(beta["tag"])
        return (
            f"Next: merge main (with {tag}) into xdial-beta, update BETA_RELEASE_NOTES.md, "
            f"push {upcoming}, and after its draft prerelease is built run:\n"
            f"  make publish RELEASE_CHANNEL=beta RELEASE_TAG={upcoming}"
        )
    return (
        f"Next: withdraw {beta['tag']} from beta.json; dispatch only after every Pages run finished:\n"
        f"  gh workflow run publish.yml -R {PAGES_REPOSITORY} -f channel=beta "
        f"-f operation=withdraw -f release_tag={beta['tag']} -f request_id=<id>"
    )


def latest_stable_release_tag() -> str:
    latest = gh_json("api", f"repos/{SOURCE_REPOSITORY}/releases/latest")
    latest_tag = latest.get("tag_name", "")
    if not TAG_PATTERN.fullmatch(latest_tag):
        raise ValueError("cannot verify the currently published stable release")
    return latest_tag


def wait_for_idle_publisher(timeout: int) -> None:
    """Every Pages operation shares one concurrency group, and a new dispatch
    cancels a run still queued in it, so dispatch only when none is pending.
    This wait has its own budget, apart from the dispatched run's."""
    deadline = time.monotonic() + timeout
    while True:
        result = gh_json(
            "api", f"repos/{PAGES_REPOSITORY}/actions/workflows/publish.yml/runs?per_page=30",
        )
        active = [run for run in result.get("workflow_runs", [])
                  if run.get("status") != "completed"]
        if not active:
            return
        if time.monotonic() >= deadline:
            raise TimeoutError(f"another Pages run is still queued or running: {active[0].get('html_url')}")
        print(f"Waiting for the current Pages run to finish: {active[0].get('html_url')}", flush=True)
        time.sleep(10)


def dispatch_and_wait(tag: str, timeout: int, channel: str = STABLE) -> str:
    # main() waits before a draft becomes public; this covers a run started
    # since then. The dispatched run still gets the whole timeout, counted
    # from its dispatch as before beta existed.
    wait_for_idle_publisher(timeout)
    request_id = uuid.uuid4().hex
    command = ["gh", "workflow", "run", "publish.yml", "--repo", PAGES_REPOSITORY,
               "--ref", "main", "-f", f"release_tag={tag}", "-f", "operation=publish"]
    if channel != STABLE:
        # The workflow defaults to stable, so a stable dispatch stays exactly as
        # before and works whether or not the workflow knows the channel input.
        command += ["-f", f"channel={channel}"]
    command += ["-f", f"request_id={request_id}"]
    subprocess.run(command, check=True)
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
    finished = gh_json("api", f"repos/{PAGES_REPOSITORY}/actions/runs/{run['id']}")
    if finished.get("conclusion") != "success":
        raise RuntimeError(f"Pages run ended as {finished.get('conclusion')}: {run['html_url']}")
    return run["html_url"]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("the canonical Pages feed must not redirect")


def release_notes(body: str) -> str:
    """The notes the Pages publisher derives from a release body."""
    captures = False
    captured: list[str] = []
    for line in body.splitlines():
        stripped = line.strip()
        if stripped.startswith("## "):
            if captures:
                break
            captures = stripped[3:].strip() in NOTES_HEADINGS
            continue
        if captures:
            captured.append(line)
    section = "\n".join(captured).strip()
    return section if section else body.strip()


def render_feed(feed: dict) -> bytes:
    """The Pages publisher's byte format."""
    return (json.dumps(feed, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def require_feed_format(data: bytes, channel: str) -> dict:
    """Parse a served feed whose bytes, apart from the revision, generatedAt
    and release values, are exactly the format released clients parse."""
    feed = json.loads(data)
    if not isinstance(feed, dict) or tuple(feed) != FEED_KEYS:
        raise ValueError(f"{channel} feed fields changed")
    expected = render_feed({
        "schemaVersion": 1,
        "revision": feed["revision"],
        "channel": channel,
        "generatedAt": feed["generatedAt"],
        "release": feed["release"],
    })
    if data != expected:
        raise ValueError(f"{channel} feed format changed outside revision, generatedAt and release")
    release = feed["release"]
    if release is not None and (not isinstance(release, dict) or tuple(release) != RELEASE_KEYS):
        raise ValueError(f"{channel} feed release fields changed")
    return feed


def verify_feed(tag: str, build: str, digest: str, channel: str = STABLE,
                notes: str | None = None, timeout: float = 180, interval: float = 5) -> None:
    feed_url = FEED_URLS[channel]
    opener = urllib.request.build_opener(NoRedirect())
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            request = urllib.request.Request(feed_url, headers={"Cache-Control": "no-cache"})
            with opener.open(request, timeout=10) as response:
                data = response.read(512 * 1024 + 1)
                if response.status != 200 or len(data) > 512 * 1024:
                    raise ValueError("invalid Pages response")
            feed = require_feed_format(data, channel)
            release = feed.get("release") or {}
            if (release.get("tag") != tag or release.get("build") != build
                    or release.get("archiveSHA256") != digest
                    or not release.get("releaseNotes", "").strip()
                    or (notes is not None and release.get("releaseNotes") != notes)):
                raise ValueError("Pages has not served the verified release and its complete notes")
            return
        except (OSError, ValueError) as error:
            last_error = error
            time.sleep(interval)
    raise RuntimeError(f"release is public but Pages verification is incomplete: {last_error}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="the already built and accepted release tag")
    parser.add_argument(
        "--channel", choices=CHANNELS, default=STABLE,
        help="stable promotes vX.Y.Z from main; beta promotes the prerelease "
             "vX.Y.Z-beta.N from xdial-beta and writes beta.json",
    )
    parser.add_argument(
        "--beta-followup", choices=BETA_FOLLOWUPS,
        help="stable only: confirms how a beta.json entry with a newer tag but a "
             "build not above this release's is handled in the same batch",
    )
    parser.add_argument(
        "--pages", choices=PAGES_MODES, default="dispatch",
        help="dispatch starts the update repository's publish.yml (operator gh login); "
             "follow leaves it to that repository's follow workflow and waits for the feed",
    )
    parser.add_argument(
        "--pages-timeout", type=int,
        help="seconds; dispatch: each wait for a Pages run (default 900); "
             "follow: the wait for the feed (default 3600)",
    )
    args = parser.parse_args()
    if args.pages_timeout is None:
        args.pages_timeout = PAGES_TIMEOUTS[args.pages]
    if sys.platform != "darwin":
        parser.error("run on macOS so the downloaded app can pass signing and notarization gates")
    if not TAG_PATTERNS[args.channel].fullmatch(args.tag) or args.pages_timeout <= 0:
        parser.error(f"provide a canonical {args.channel} tag and a positive timeout")
    if args.beta_followup and args.channel != STABLE:
        parser.error("--beta-followup only applies to stable releases")

    if args.channel == STABLE:
        verify_remote_tag_on_main(args.tag)
    else:
        verify_remote_beta_tag(args.tag)
    releases = list_source_releases()
    release = find_source_release(args.tag, releases)
    archive, checksum = validate_release(release, args.tag, args.channel)
    latest_tag = latest_stable_release_tag()
    if args.channel == STABLE and tag_key(latest_tag) > tag_key(args.tag):
        raise ValueError("refusing to replace a newer published release with an older tag")
    with tempfile.TemporaryDirectory(prefix="xdial-publish-") as directory_name:
        directory = Path(directory_name)
        print("Downloading and verifying the exact release assets before publication…", flush=True)
        subprocess.run(
            ["gh", "release", "download", args.tag, "--repo", SOURCE_REPOSITORY,
             "--pattern", archive, "--pattern", checksum, "--dir", str(directory)],
            check=True,
        )
        build, digest = verify_archive(directory, archive, args.tag, args.channel)
        print("Checking the build and tag against every published release…", flush=True)
        feed_state = load_feed_state()
        require_channel_order(args.tag, args.channel, releases, latest_tag, feed_state)
        require_build_gate(
            args.tag, args.channel, build,
            published_packages(releases, feed_state, args.tag, args.channel),
        )
        lagging_beta = None
        if args.channel == STABLE:
            lagging_beta = lagging_beta_release(feed_state, args.tag, build)
            if lagging_beta is not None:
                notice = beta_followup_notice(lagging_beta, args.tag, build)
                if args.beta_followup is None:
                    raise ValueError(f"\n{notice}\nnothing was published")
                print(notice, file=sys.stderr, flush=True)
            elif args.beta_followup:
                print("beta.json needs no follow-up; --beta-followup is ignored", flush=True)
        if release["draft"]:
            if args.pages == "dispatch":
                # A pending Pages run is waited out while nothing is public yet,
                # instead of eating into the time this release's run gets later.
                wait_for_idle_publisher(args.pages_timeout)
            # A beta must never become Latest: this script refuses a stable
            # release while Latest is not a stable tag.
            listing = ["--latest"] if args.channel == STABLE else ["--prerelease", "--latest=false"]
            subprocess.run(
                ["gh", "release", "edit", args.tag, "--repo", SOURCE_REPOSITORY,
                 "--draft=false", *listing],
                check=True,
            )
            published = gh_json(
                "api", f"repos/{SOURCE_REPOSITORY}/releases/{release['id']}"
            )
            if published.get("id") != release["id"] or published.get("draft") is not False:
                raise ValueError("the exact source release was not published")
            validate_release(published, args.tag, args.channel)
            release = published
        if args.channel == BETA:
            current_latest = gh_json("api", f"repos/{SOURCE_REPOSITORY}/releases/latest").get("tag_name")
            if current_latest != latest_tag:
                raise ValueError(
                    f"the Latest release changed from {latest_tag} to {current_latest}; "
                    f"mark {latest_tag} Latest again before publishing the beta feed"
                )
        print(f"Release is public: https://github.com/{SOURCE_REPOSITORY}/releases/tag/{args.tag}", flush=True)
        notes = release_notes(release["body"])
        if args.pages == "dispatch":
            dispatch_and_wait(args.tag, args.pages_timeout, args.channel)
            verify_feed(args.tag, build, digest, args.channel, notes)
        else:
            print(f"Waiting up to {args.pages_timeout} s for {PAGES_REPOSITORY} to publish it; "
                  f"its follow workflow checks every 10 minutes: {FOLLOW_WORKFLOW_URL}", flush=True)
            try:
                verify_feed(args.tag, build, digest, args.channel, notes,
                            timeout=args.pages_timeout, interval=30)
            except RuntimeError as error:
                rerun = f" RELEASE_CHANNEL={args.channel}" if args.channel != STABLE else ""
                rerun += f" RELEASE_TAG={args.tag}"
                raise RuntimeError(
                    f"{error}\n{PAGES_REPOSITORY} has not published {args.tag}. Check its follow "
                    f"and publish runs ({FOLLOW_WORKFLOW_URL}); GitHub disables a schedule after "
                    f"60 days without activity. The release stays public; after fixing the cause, "
                    f"run make publish{rerun} on a Mac, which dispatches publish.yml itself."
                ) from None
        print(f"Publication verified: {FEED_URLS[args.channel]} ({args.tag}, build {build})", flush=True)
        if lagging_beta is not None:
            print(beta_followup_steps(lagging_beta, args.tag, args.beta_followup), flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
