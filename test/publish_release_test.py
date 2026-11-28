import copy
import contextlib
import hashlib
import importlib.util
import io
import itertools
import json
import os
import plistlib
import subprocess
import tempfile
import types
import unittest
import zipfile
from pathlib import Path
from unittest.mock import MagicMock, patch

# Fixture repositories are removed right after use; keep git from starting a
# detached auto maintenance that could still be writing into them.
os.environ.update(GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="maintenance.auto",
                  GIT_CONFIG_VALUE_0="false")


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("publish_release", ROOT / "scripts/publish-release.py")
PUBLISH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PUBLISH)


class PublishReleaseTests(unittest.TestCase):
    @staticmethod
    def git(directory: Path, *arguments: str) -> str:
        return subprocess.run(
            ["git", "-C", str(directory), *arguments],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def release(self, draft=True):
        download_name = "untagged-0123456789abcdefabcd" if draft else "v1.2.3"
        return {
            "id": 123, "tag_name": "v1.2.3", "draft": draft, "prerelease": False,
            "html_url": f"https://github.com/kafeifei/XDial/releases/tag/{download_name}",
            "body": "## 更新了什么\n\n- 修复更新检查。",
            "assets": [
                {"name": name, "state": "uploaded", "size": 123,
                 "browser_download_url":
                 f"https://github.com/kafeifei/XDial/releases/download/{download_name}/{name}"}
                for name in ["XDial-v1.2.3.zip", "XDial-v1.2.3.zip.sha256"]
            ],
        }

    def test_accepts_built_draft_and_idempotent_public_release(self):
        for draft in [True, False]:
            release = self.release(draft=draft)
            self.assertEqual(PUBLISH.validate_release(release, "v1.2.3"),
                             ("XDial-v1.2.3.zip", "XDial-v1.2.3.zip.sha256"))

    def test_finds_draft_by_exact_tag_from_all_release_pages(self):
        draft = self.release()
        other = self.release(False)
        other["tag_name"] = "v1.2.2"
        with patch.object(PUBLISH, "gh_json", return_value=[[other], [draft]]) as gh_json:
            self.assertIs(PUBLISH.find_source_release("v1.2.3"), draft)
        gh_json.assert_called_once_with(
            "api", "repos/kafeifei/XDial/releases?per_page=100", "--paginate", "--slurp"
        )

    def test_missing_or_ambiguous_release_fails_before_mutation(self):
        for pages in [[], [[]], [[self.release(), self.release()]]]:
            with self.subTest(pages=pages):
                with (
                    patch.object(PUBLISH.sys, "argv", ["publish-release.py", "v1.2.3"]),
                    patch.object(PUBLISH.sys, "platform", "darwin"),
                    patch.object(PUBLISH, "verify_remote_tag_on_main", return_value="commit"),
                    patch.object(PUBLISH, "gh_json", return_value=pages),
                    patch.object(PUBLISH.subprocess, "run") as run,
                ):
                    with self.assertRaisesRegex(ValueError, "exactly one source release"):
                        PUBLISH.main()
                    run.assert_not_called()

    def test_rejects_incomplete_or_mismatched_release_before_publication(self):
        mutations = [
            lambda release: release.update(prerelease=True),
            lambda release: release.update(tag_name="v1.2.4"),
            lambda release: release.update(draft=None),
            lambda release: release.update(body=" \n "),
            lambda release: release.update(html_url="https://example.com/untagged-0123456789abcdefabcd"),
            lambda release: release.update(
                html_url="https://github.com/kafeifei/XDial/releases/tag/untagged-bad"),
            lambda release: release["assets"].pop(),
            lambda release: release["assets"].append(copy.deepcopy(release["assets"][0])),
            lambda release: release["assets"][0].update(state="new"),
            lambda release: release["assets"][0].update(size=0),
            lambda release: release["assets"][0].update(
                browser_download_url="https://example.com/XDial-v1.2.3.zip"),
        ]
        for mutate in mutations:
            release = self.release()
            mutate(release)
            with self.subTest(release=release), self.assertRaises(ValueError):
                PUBLISH.validate_release(release, "v1.2.3")

    def test_rejects_noncanonical_tag(self):
        for tag in ["v1.2", "v01.2.3", "1.2.3", "v1.2.3-beta", "v1.2.3\n"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                PUBLISH.validate_release(self.release(), tag)

    def test_acceptance_package_is_rejected_before_release_contract_or_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "XDial-v1.2.3.zip"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("XDial.app/Contents/Info.plist", plistlib.dumps({
                    "CFBundleVersion": "123", "XDialUpdateAcceptanceID": "pages-acceptance",
                }))
            with patch.object(PUBLISH.subprocess, "run") as run:
                with self.assertRaisesRegex(ValueError, "acceptance package"):
                    PUBLISH.verify_archive(Path(directory), path.name, "v1.2.3")
                run.assert_not_called()

    def test_remote_tag_must_be_on_source_main_first_parent(self):
        with tempfile.TemporaryDirectory() as directory_name:
            directory = Path(directory_name)
            source = directory / "source.git"
            work = directory / "work"
            self.git(directory, "init", "--bare", "--quiet", str(source))
            self.git(directory, "init", "--quiet", "--initial-branch=main", str(work))
            self.git(work, "config", "user.name", "XDial Test")
            self.git(work, "config", "user.email", "xdial-test@example.invalid")
            (work / "tracked.txt").write_text("main\n", encoding="utf-8")
            self.git(work, "add", "tracked.txt")
            self.git(work, "commit", "--quiet", "-m", "main")
            main_commit = self.git(work, "rev-parse", "HEAD")
            self.git(work, "tag", "-a", "v1.2.3", "-m", "v1.2.3")
            self.git(work, "remote", "add", "source", str(source))
            self.git(work, "push", "--quiet", "source", "main", "refs/tags/v1.2.3")

            self.assertEqual(
                PUBLISH.verify_remote_tag_on_main("v1.2.3", str(source)),
                main_commit,
            )

            self.git(work, "switch", "--quiet", "-c", "feature")
            (work / "feature.txt").write_text("feature\n", encoding="utf-8")
            self.git(work, "add", "feature.txt")
            self.git(work, "commit", "--quiet", "-m", "feature")
            self.git(work, "tag", "v1.2.4")
            self.git(work, "push", "--quiet", "source", "refs/tags/v1.2.4")
            self.git(work, "switch", "--quiet", "main")
            self.git(work, "merge", "--no-ff", "--quiet", "-m", "merge feature", "feature")
            self.git(work, "push", "--quiet", "source", "main")

            with self.assertRaisesRegex(ValueError, "first-parent"):
                PUBLISH.verify_remote_tag_on_main("v1.2.4", str(source))

            merged_commit = self.git(work, "rev-parse", "HEAD")
            self.git(work, "tag", "-a", "v1.2.5", "-m", "v1.2.5")
            self.git(work, "push", "--quiet", "source", "refs/tags/v1.2.5")
            self.assertEqual(
                PUBLISH.verify_remote_tag_on_main("v1.2.5", str(source)),
                merged_commit,
            )

    def test_remote_gate_fails_before_release_or_pages_operations(self):
        with (
            patch.object(PUBLISH.sys, "argv", ["publish-release.py", "v1.2.3"]),
            patch.object(PUBLISH.sys, "platform", "darwin"),
            patch.object(
                PUBLISH,
                "verify_remote_tag_on_main",
                side_effect=ValueError("remote source gate failed"),
            ),
            patch.object(PUBLISH, "gh_json") as gh_json,
            patch.object(PUBLISH.subprocess, "run") as run,
        ):
            with self.assertRaisesRegex(ValueError, "remote source gate failed"):
                PUBLISH.main()
            gh_json.assert_not_called()
            run.assert_not_called()

    def test_draft_is_revalidated_as_the_same_canonical_release_before_pages(self):
        draft = self.release(True)
        published = self.release(False)
        events = []
        responses = iter([[[draft]], {"tag_name": "v1.2.2"}, published])

        def run(arguments, **kwargs):
            events.append(tuple(arguments))
            return subprocess.CompletedProcess(arguments, 0)

        def gh_json(*arguments):
            events.append(("api", *arguments))
            return next(responses)

        with (
            patch.object(PUBLISH.sys, "argv", ["publish-release.py", "v1.2.3"]),
            patch.object(PUBLISH.sys, "platform", "darwin"),
            patch.object(PUBLISH, "verify_remote_tag_on_main", return_value="commit"),
            patch.object(PUBLISH, "gh_json", side_effect=gh_json) as gh_json_mock,
            patch.object(PUBLISH.subprocess, "run", side_effect=run),
            patch.object(PUBLISH, "verify_archive", return_value=("123", "digest")),
            patch.object(PUBLISH, "load_feed_state", return_value=PUBLISH.FeedState()),
            patch.object(PUBLISH, "wait_for_idle_publisher"),
            patch.object(PUBLISH, "dispatch_and_wait", side_effect=lambda *_: events.append(("pages",))),
            patch.object(PUBLISH, "verify_feed"),
        ):
            PUBLISH.main()

        self.assertEqual(
            gh_json_mock.call_args_list[-1].args,
            ("api", "repos/kafeifei/XDial/releases/123"),
        )
        edit_index = next(index for index, event in enumerate(events) if event[:3] == ("gh", "release", "edit"))
        published_fetch_index = events.index(
            ("api", "api", "repos/kafeifei/XDial/releases/123")
        )
        pages_index = events.index(("pages",))
        self.assertLess(edit_index, published_fetch_index)
        self.assertLess(published_fetch_index, pages_index)
        download = next(event for event in events if event[:3] == ("gh", "release", "download"))
        self.assertEqual(
            download[:11],
            ("gh", "release", "download", "v1.2.3", "--repo", "kafeifei/XDial",
             "--pattern", "XDial-v1.2.3.zip", "--pattern", "XDial-v1.2.3.zip.sha256", "--dir"),
        )

    def test_rejects_untagged_asset_urls_after_publication(self):
        release = self.release(True)
        release["draft"] = False
        release["html_url"] = "https://github.com/kafeifei/XDial/releases/tag/v1.2.3"
        with self.assertRaisesRegex(ValueError, "missing or unexpected release asset"):
            PUBLISH.validate_release(release, "v1.2.3")

    def test_invalid_post_publication_state_never_dispatches_pages(self):
        still_draft = self.release(True)
        changed_id = self.release(False)
        changed_id["id"] = 456
        untagged_assets = self.release(True)
        untagged_assets["draft"] = False
        untagged_assets["html_url"] = (
            "https://github.com/kafeifei/XDial/releases/tag/v1.2.3"
        )
        cases = [
            (still_draft, "exact source release was not published"),
            (changed_id, "exact source release was not published"),
            (untagged_assets, "missing or unexpected release asset"),
        ]
        for published, error in cases:
            with self.subTest(error=error):
                draft = self.release(True)
                with (
                    patch.object(PUBLISH.sys, "argv", ["publish-release.py", "v1.2.3"]),
                    patch.object(PUBLISH.sys, "platform", "darwin"),
                    patch.object(PUBLISH, "verify_remote_tag_on_main", return_value="commit"),
                    patch.object(
                        PUBLISH, "gh_json",
                        side_effect=[[[draft]], {"tag_name": "v1.2.2"}, published],
                    ),
                    patch.object(PUBLISH.subprocess, "run"),
                    patch.object(PUBLISH, "verify_archive", return_value=("123", "digest")),
                    patch.object(PUBLISH, "load_feed_state", return_value=PUBLISH.FeedState()),
                    patch.object(PUBLISH, "wait_for_idle_publisher"),
                    patch.object(PUBLISH, "dispatch_and_wait") as dispatch,
                    patch.object(PUBLISH, "verify_feed"),
                ):
                    with self.assertRaisesRegex(ValueError, error):
                        PUBLISH.main()
                    dispatch.assert_not_called()

    def test_public_release_is_idempotent(self):
        published = self.release(False)
        with (
            patch.object(PUBLISH.sys, "argv", ["publish-release.py", "v1.2.3"]),
            patch.object(PUBLISH.sys, "platform", "darwin"),
            patch.object(PUBLISH, "verify_remote_tag_on_main", return_value="commit"),
            patch.object(
                PUBLISH, "gh_json",
                side_effect=[[[published]], {"tag_name": "v1.2.3"}],
            ),
            patch.object(PUBLISH.subprocess, "run") as run,
            patch.object(PUBLISH, "verify_archive", return_value=("123", "digest")),
            patch.object(PUBLISH, "load_feed_state", return_value=PUBLISH.FeedState()),
            patch.object(PUBLISH, "dispatch_and_wait"),
            patch.object(PUBLISH, "verify_feed"),
        ):
            PUBLISH.main()

        commands = [call.args[0] for call in run.call_args_list]
        self.assertFalse(any(command[:3] == ["gh", "release", "edit"] for command in commands))


def release_fixture(tag, draft=True, prerelease=False):
    download_name = "untagged-0123456789abcdefabcd" if draft else tag
    return {
        "id": 123, "tag_name": tag, "draft": draft, "prerelease": prerelease,
        "html_url": f"https://github.com/kafeifei/XDial/releases/tag/{download_name}",
        "body": f"# XDial {tag}\n\n## 更新了什么\n\n- 修复更新检查。",
        "assets": [
            {"name": name, "state": "uploaded", "size": 123,
             "browser_download_url":
             f"https://github.com/kafeifei/XDial/releases/download/{download_name}/{name}"}
            for name in [f"XDial-{tag}.zip", f"XDial-{tag}.zip.sha256"]
        ],
    }


def package(tag, build):
    channel = PUBLISH.tag_channel(tag)
    return PUBLISH.PublishedPackage(channel, tag, PUBLISH.tag_version(tag, channel), build)


def feed_release(tag, build):
    version = PUBLISH.tag_version(tag, PUBLISH.tag_channel(tag))
    return {
        "tag": tag,
        "version": ".".join(str(part) for part in version),
        "build": str(build),
        "minimumSystemVersion": "15.0",
        "publishedAt": "2026-10-18T00:00:00Z",
        "releaseNotes": "- 修复更新检查。",
        "archiveURL": f"https://github.com/kafeifei/XDial/releases/download/{tag}/XDial-{tag}.zip",
        "archiveSize": 123,
        "archiveSHA256": hashlib.sha256(tag.encode()).hexdigest(),
    }


def feed(channel, release, revision=2):
    return {"schemaVersion": 1, "revision": revision, "channel": channel,
            "generatedAt": "2026-10-18T00:00:00Z", "release": release}


def write_pages_state(root, channels):
    """Write the Pages publisher's state. channels maps a channel to
    [(tag, build, withdrawn)] in publication order; a channel left out never existed."""
    for channel, releases in channels.items():
        feed_path, ledger_path, history_path = PUBLISH.FEED_STATE_PATHS[channel]
        (root / history_path).mkdir(parents=True, exist_ok=True)
        (root / feed_path).parent.mkdir(parents=True, exist_ok=True)
        records, current, revision = {}, None, 1
        for tag, build, withdrawn in releases:
            revision += 1
            current = feed_release(tag, build)
            (root / history_path / f"{revision}.json").write_text(
                json.dumps(feed(channel, current, revision)), encoding="utf-8")
            records[tag] = {"version": current["version"],
                            "archiveSHA256": current["archiveSHA256"],
                            "publishedRevision": revision, "status": "published"}
            if withdrawn:
                revision += 1
                records[tag].update(status="withdrawn", withdrawnRevision=revision)
                current = None
        (root / feed_path).write_text(json.dumps(feed(channel, current, revision)), encoding="utf-8")
        (root / ledger_path).write_text(json.dumps({
            "schemaVersion": 1, "lastRevision": revision, "releases": records,
        }), encoding="utf-8")


def commit_pages_state(root):
    for arguments in (
        ["init", "--quiet", "--initial-branch=main"],
        ["config", "user.name", "XDial Test"],
        ["config", "user.email", "xdial-test@example.invalid"],
        ["add", "."],
        ["commit", "--quiet", "-m", "state"],
    ):
        subprocess.run(["git", "-C", str(root), *arguments], check=True)


class BetaChannelTests(unittest.TestCase):
    git = staticmethod(PublishReleaseTests.git)

    @contextlib.contextmanager
    def publication(self, argv, responses, feed_state, build="123"):
        run = types.SimpleNamespace(events=[], stdout=io.StringIO(), stderr=io.StringIO())

        def record(arguments, **kwargs):
            run.events.append(tuple(arguments))
            return subprocess.CompletedProcess(arguments, 0)

        with contextlib.ExitStack() as stack:
            enter = stack.enter_context
            enter(patch.object(PUBLISH.sys, "argv", ["publish-release.py", *argv]))
            enter(patch.object(PUBLISH.sys, "platform", "darwin"))
            run.remote = enter(patch.object(PUBLISH, "verify_remote_tag", return_value="commit"))
            enter(patch.object(PUBLISH, "gh_json", side_effect=responses))
            enter(patch.object(PUBLISH.subprocess, "run", side_effect=record))
            run.verify_archive = enter(
                patch.object(PUBLISH, "verify_archive", return_value=(build, "digest")))
            enter(patch.object(PUBLISH, "load_feed_state", return_value=feed_state))
            run.idle = enter(patch.object(PUBLISH, "wait_for_idle_publisher",
                                          side_effect=lambda *_: run.events.append(("idle",))))
            run.dispatch = enter(patch.object(PUBLISH, "dispatch_and_wait"))
            run.verify_feed = enter(patch.object(PUBLISH, "verify_feed"))
            enter(contextlib.redirect_stdout(run.stdout))
            enter(contextlib.redirect_stderr(run.stderr))
            yield run

    @staticmethod
    def edits(run):
        return [event for event in run.events if event[:3] == ("gh", "release", "edit")]

    def test_beta_tags_are_strict_and_each_channel_refuses_the_other(self):
        for draft in [True, False]:
            release = release_fixture("v1.4.0-beta.1", draft=draft, prerelease=True)
            self.assertEqual(
                PUBLISH.validate_release(release, "v1.4.0-beta.1", "beta"),
                ("XDial-v1.4.0-beta.1.zip", "XDial-v1.4.0-beta.1.zip.sha256"),
            )
        for tag in ["v1.4.0", "v1.4.0-beta.0", "v1.4.0-beta.01", "v1.4.0-rc.1",
                    "v1.4.0-beta", "v01.4.0-beta.1", "v1.4.0-beta.1\n"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                PUBLISH.validate_release(release_fixture(tag, prerelease=True), tag, "beta")
        with self.assertRaisesRegex(ValueError, "canonical vMAJOR.MINOR.PATCH"):
            PUBLISH.validate_release(
                release_fixture("v1.4.0-beta.1", prerelease=True), "v1.4.0-beta.1")
        with self.assertRaisesRegex(ValueError, "exact beta prerelease"):
            PUBLISH.validate_release(release_fixture("v1.4.0-beta.1"), "v1.4.0-beta.1", "beta")
        with self.assertRaisesRegex(ValueError, "exact stable release"):
            PUBLISH.validate_release(release_fixture("v1.4.0", prerelease=True), "v1.4.0")
        for argv in (["v1.4.0-beta.1"], ["--channel", "beta", "v1.4.0"],
                     ["--channel", "beta", "--beta-followup", "withdraw", "v1.4.0-beta.1"]):
            with (
                self.subTest(argv=argv),
                patch.object(PUBLISH.sys, "argv", ["publish-release.py", *argv]),
                patch.object(PUBLISH.sys, "platform", "darwin"),
                patch.object(PUBLISH, "verify_remote_tag") as remote,
                contextlib.redirect_stderr(io.StringIO()),
            ):
                with self.assertRaises(SystemExit):
                    PUBLISH.main()
                remote.assert_not_called()

    def test_remote_beta_tag_must_be_on_xdial_beta_and_contain_the_latest_stable(self):
        with tempfile.TemporaryDirectory() as directory_name:
            directory = Path(directory_name)
            source = directory / "source.git"
            work = directory / "work"
            self.git(directory, "init", "--bare", "--quiet", str(source))
            self.git(directory, "init", "--quiet", "--initial-branch=main", str(work))
            self.git(work, "config", "user.name", "XDial Test")
            self.git(work, "config", "user.email", "xdial-test@example.invalid")
            self.git(work, "remote", "add", "source", str(source))

            def commit(name):
                (work / f"{name}.txt").write_text(f"{name}\n", encoding="utf-8")
                self.git(work, "add", f"{name}.txt")
                self.git(work, "commit", "--quiet", "-m", name)
                return self.git(work, "rev-parse", "HEAD")

            def push(*refs):
                self.git(work, "push", "--quiet", "source", *refs)

            commit("main")
            self.git(work, "tag", "-a", "v1.2.3", "-m", "v1.2.3")
            push("main", "refs/tags/v1.2.3")
            self.git(work, "switch", "--quiet", "-c", "xdial-beta")
            beta_commit = commit("experiment")
            self.git(work, "tag", "v1.3.0-beta.1")
            self.git(work, "tag", "v1.2.3-beta.9")
            push("xdial-beta", "refs/tags/v1.3.0-beta.1", "refs/tags/v1.2.3-beta.9")
            self.assertEqual(PUBLISH.verify_remote_beta_tag("v1.3.0-beta.1", str(source)), beta_commit)
            with self.assertRaisesRegex(ValueError, "newer than the latest stable tag v1.2.3"):
                PUBLISH.verify_remote_beta_tag("v1.2.3-beta.9", str(source))
            with self.assertRaisesRegex(ValueError, "canonical"):
                PUBLISH.verify_remote_tag_on_main("v1.3.0-beta.1", str(source))

            # A stable hotfix that xdial-beta has not merged yet.
            self.git(work, "switch", "--quiet", "main")
            commit("hotfix")
            self.git(work, "tag", "-a", "v1.2.4", "-m", "v1.2.4")
            push("main", "refs/tags/v1.2.4")
            self.git(work, "switch", "--quiet", "xdial-beta")
            commit("unmerged")
            self.git(work, "tag", "v1.3.0-beta.2")
            push("xdial-beta", "refs/tags/v1.3.0-beta.2")
            with self.assertRaisesRegex(ValueError, "must contain the latest stable tag v1.2.4"):
                PUBLISH.verify_remote_beta_tag("v1.3.0-beta.2", str(source))

            self.git(work, "merge", "--no-ff", "--quiet", "-m", "merge main", "main")
            merged_commit = self.git(work, "rev-parse", "HEAD")
            self.git(work, "tag", "v1.3.0-beta.3")
            push("xdial-beta", "refs/tags/v1.3.0-beta.3")
            self.assertEqual(
                PUBLISH.verify_remote_beta_tag("v1.3.0-beta.3", str(source)), merged_commit)

            # A tag on a feature branch merged into xdial-beta is off its first parent.
            self.git(work, "switch", "--quiet", "-c", "feature/experiment")
            commit("feature")
            self.git(work, "tag", "v1.3.0-beta.4")
            self.git(work, "switch", "--quiet", "xdial-beta")
            self.git(work, "merge", "--no-ff", "--quiet", "-m", "merge feature", "feature/experiment")
            push("xdial-beta", "refs/tags/v1.3.0-beta.4")
            with self.assertRaisesRegex(ValueError, "xdial-beta's first-parent history"):
                PUBLISH.verify_remote_beta_tag("v1.3.0-beta.4", str(source))

    def test_remote_beta_tag_must_keep_the_formats_shared_with_main(self):
        with tempfile.TemporaryDirectory() as directory_name:
            directory = Path(directory_name)
            source = directory / "source.git"
            work = directory / "work"
            self.git(directory, "init", "--bare", "--quiet", str(source))
            self.git(directory, "init", "--quiet", "--initial-branch=main", str(work))
            self.git(work, "config", "user.name", "XDial Test")
            self.git(work, "config", "user.email", "xdial-test@example.invalid")
            self.git(work, "remote", "add", "source", str(source))

            def commit(path, text):
                (work / path).parent.mkdir(parents=True, exist_ok=True)
                (work / path).write_text(text, encoding="utf-8")
                self.git(work, "add", path)
                self.git(work, "commit", "--quiet", "-m", path)
                return self.git(work, "rev-parse", "HEAD")

            def push(*refs):
                self.git(work, "push", "--quiet", "source", *refs)

            commit("go.mod", "module fixture\n")
            commit("patches/tailscale/0001-fixture.patch", "main\n")
            self.git(work, "tag", "-a", "v1.2.3", "-m", "v1.2.3")
            push("main", "refs/tags/v1.2.3")
            self.git(work, "switch", "--quiet", "-c", "xdial-beta")
            commit("experiment.txt", "experiment\n")
            # Main may move its own dependencies; only the beta side counts.
            self.git(work, "switch", "--quiet", "main")
            commit("go.mod", "module fixture\n\ngo 1.25\n")
            push("main")
            self.git(work, "switch", "--quiet", "xdial-beta")
            beta_commit = commit("experiment.txt", "more\n")
            self.git(work, "tag", "v1.3.0-beta.1")
            push("xdial-beta", "refs/tags/v1.3.0-beta.1")
            self.assertEqual(PUBLISH.verify_remote_beta_tag("v1.3.0-beta.1", str(source)), beta_commit)

            # A dependency patch changed on xdial-beta alone.
            commit("patches/tailscale/0001-fixture.patch", "beta\n")
            self.git(work, "tag", "v1.3.0-beta.2")
            push("xdial-beta", "refs/tags/v1.3.0-beta.2")
            with self.assertRaisesRegex(
                ValueError, r"(?s)must keep the formats it shares.*patches/tailscale/0001-fixture\.patch"
            ):
                PUBLISH.verify_remote_beta_tag("v1.3.0-beta.2", str(source))

    def test_build_gate_skips_only_packages_with_a_newer_version(self):
        packages = [package("v1.3.0", 100), package("v1.4.0-beta.1", 200)]
        # A stable hotfix below the open beta line need not outrank the beta.
        PUBLISH.require_build_gate("v1.3.1", "stable", "150", packages)
        PUBLISH.require_build_gate("v1.4.0-beta.2", "beta", "201", packages)
        PUBLISH.require_build_gate("v1.4.0", "stable", "201", packages)
        # Publishing the same package again is not a new build.
        PUBLISH.require_build_gate("v1.3.0", "stable", "100", packages)
        for tag, channel, build in [
            ("v1.3.1", "stable", "100"),
            ("v1.4.0-beta.2", "beta", "199"),
            ("v1.4.0", "stable", "150"),
            ("v1.3.0", "stable", "101"),
        ]:
            with self.subTest(tag=tag, build=build), self.assertRaises(ValueError):
                PUBLISH.require_build_gate(tag, channel, build, packages)

    def test_withdrawn_beta_still_refuses_a_lower_build_of_the_same_version(self):
        with tempfile.TemporaryDirectory() as directory_name:
            root = Path(directory_name) / "pages"
            write_pages_state(root, {
                "stable": [("v1.3.0", 100, False)],
                "beta": [("v1.4.0-beta.1", 200, True)],
            })
            commit_pages_state(root)
            state = PUBLISH.load_feed_state(str(root))
        self.assertEqual(set(state.packages), {package("v1.3.0", 100), package("v1.4.0-beta.1", 200)})
        self.assertEqual(state.withdrawn, {"v1.4.0-beta.1"})
        self.assertIsNone(state.feeds["beta"]["release"])
        self.assertEqual(state.feeds["stable"]["release"]["tag"], "v1.3.0")
        packages = PUBLISH.published_packages([], state, "v1.4.0", "stable")
        with self.assertRaisesRegex(ValueError, "build 200 of published beta v1.4.0-beta.1"):
            PUBLISH.require_build_gate("v1.4.0", "stable", "150", packages)
        PUBLISH.require_build_gate("v1.4.0", "stable", "250", packages)
        with self.assertRaisesRegex(ValueError, "withdrawn"):
            PUBLISH.require_channel_order(
                "v1.4.0-beta.1", "beta", [], "v1.3.0", state)

    def test_feed_state_without_beta_and_with_altered_history(self):
        with tempfile.TemporaryDirectory() as directory_name:
            root = Path(directory_name) / "pages"
            write_pages_state(root, {"stable": [("v1.3.0", 100, False)]})
            commit_pages_state(root)
            state = PUBLISH.load_feed_state(str(root))
            self.assertIsNone(state.feeds["beta"])
            self.assertEqual(state.packages, (package("v1.3.0", 100),))

            history = root / "state/history/2.json"
            altered = json.loads(history.read_text(encoding="utf-8"))
            altered["release"]["archiveSHA256"] = "0" * 64
            history.write_text(json.dumps(altered), encoding="utf-8")
            self.git(root, "commit", "--quiet", "-am", "alter history")
            with self.assertRaisesRegex(ValueError, "cannot prove the build of v1.3.0"):
                PUBLISH.load_feed_state(str(root))

    def test_unrecorded_public_releases_are_read_from_their_archives(self):
        state = PUBLISH.FeedState((package("v1.3.0", 100),))
        releases = [
            release_fixture("v1.3.0", draft=False),
            release_fixture("v1.3.1", draft=False),
            release_fixture("v1.3.2", draft=True),
            release_fixture("v1.5.0", draft=False),
            release_fixture("v1.4.0", draft=True),
            {"tag_name": "nightly", "draft": False},
        ]
        with patch.object(PUBLISH, "read_release_build", return_value=180) as read:
            packages = PUBLISH.published_packages(releases, state, "v1.4.0", "stable")
        read.assert_called_once_with("v1.3.1")
        self.assertEqual(packages, [package("v1.3.0", 100), package("v1.3.1", 180)])

        def download(arguments, **kwargs):
            directory = Path(arguments[arguments.index("--dir") + 1])
            with zipfile.ZipFile(directory / "XDial-v1.3.1.zip", "w") as archive:
                archive.writestr("XDial.app/Contents/Info.plist",
                                 plistlib.dumps({"CFBundleVersion": "180"}))
            return subprocess.CompletedProcess(arguments, 0)

        with patch.object(PUBLISH.subprocess, "run", side_effect=download) as run:
            self.assertEqual(PUBLISH.read_release_build("v1.3.1"), 180)
        self.assertEqual(
            run.call_args.args[0][:9],
            ["gh", "release", "download", "v1.3.1", "--repo", "kafeifei/XDial",
             "--pattern", "XDial-v1.3.1.zip", "--dir"],
        )

    def archive(self, directory, tag, info, extra=()):
        path = Path(directory) / f"XDial-{tag}.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("XDial.app/Contents/Info.plist", plistlib.dumps(info))
            for name in extra:
                archive.writestr(name, "{}")
        return path

    def test_beta_archive_names_its_tag_and_carries_no_private_configuration(self):
        tag = "v1.4.0-beta.1"
        tagged = {"CFBundleVersion": "200", "XDialReleaseTag": tag}
        cases = [
            ({"CFBundleVersion": "200"}, (), "XDialReleaseTag"),
            ({"CFBundleVersion": "200", "XDialReleaseTag": ""}, (), "XDialReleaseTag"),
            ({"CFBundleVersion": "200", "XDialReleaseTag": "v1.4.0"}, (), "XDialReleaseTag"),
            (tagged, ("XDial.app/Contents/Resources/SeedProfile/Preset.json",), "private configuration"),
            (tagged, ("XDial.app/Contents/Resources/RuleSetPresets.json",), "private configuration"),
        ]
        for info, extra, error in cases:
            with self.subTest(info=info, extra=extra), tempfile.TemporaryDirectory() as directory:
                path = self.archive(directory, tag, info, extra)
                with patch.object(PUBLISH.subprocess, "run") as run:
                    with self.assertRaisesRegex(ValueError, error):
                        PUBLISH.verify_archive(Path(directory), path.name, tag, "beta")
                    run.assert_not_called()

        with tempfile.TemporaryDirectory() as directory:
            path = self.archive(directory, tag, tagged)
            with patch.object(PUBLISH.subprocess, "run") as run:
                build, _ = PUBLISH.verify_archive(Path(directory), path.name, tag, "beta")
        self.assertEqual(build, "200")
        self.assertEqual(run.call_args.args[0][1:], ["verify-archive", str(path), tag, "200"])
        self.assertEqual(run.call_args.kwargs["env"]["XDIAL_RELEASE_CHANNEL"], "beta")

    def test_stable_archive_leaves_private_configuration_to_the_shared_contract(self):
        # Preset configuration packages share the stable contract and embed it.
        with tempfile.TemporaryDirectory() as directory:
            path = self.archive(directory, "v1.4.0", {"CFBundleVersion": "200"},
                                ("XDial.app/Contents/Resources/SeedProfile/Preset.json",))
            with patch.object(PUBLISH.subprocess, "run") as run:
                PUBLISH.verify_archive(Path(directory), path.name, "v1.4.0")
        self.assertEqual(run.call_args.kwargs["env"]["XDIAL_RELEASE_CHANNEL"], "stable")

    def dispatch(self, channel, tag, responses):
        order = []
        replies = iter(responses)

        def gh_json(*arguments):
            order.append(("api", arguments[-1]))
            return next(replies)

        def run(arguments, **kwargs):
            order.append(tuple(arguments))
            return subprocess.CompletedProcess(arguments, 0)

        with (
            patch.object(PUBLISH, "gh_json", side_effect=gh_json),
            patch.object(PUBLISH.subprocess, "run", side_effect=run),
            patch.object(PUBLISH.uuid, "uuid4", return_value=types.SimpleNamespace(hex="req")),
            patch.object(PUBLISH.time, "sleep"),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            PUBLISH.dispatch_and_wait(tag, 60, channel)
        return order

    def test_dispatch_waits_for_the_publisher_and_names_only_the_beta_channel(self):
        runs = "repos/saymiao/xdial-updates/actions/workflows/publish.yml/runs?per_page=30"
        found = {"workflow_runs": [{"id": 7, "display_title": "publish beta v1.4.0-beta.1 [req]",
                                    "html_url": "https://example.invalid/7"}]}
        order = self.dispatch("beta", "v1.4.0-beta.1", [
            {"workflow_runs": [{"status": "queued", "html_url": "https://example.invalid/6"}]},
            {"workflow_runs": [{"status": "completed"}]},
            found,
            {"conclusion": "success"},
        ])
        self.assertEqual(order[:2], [("api", runs), ("api", runs)])
        self.assertEqual(order[2], (
            "gh", "workflow", "run", "publish.yml", "--repo", "saymiao/xdial-updates",
            "--ref", "main", "-f", "release_tag=v1.4.0-beta.1", "-f", "operation=publish",
            "-f", "channel=beta", "-f", "request_id=req",
        ))
        self.assertEqual(order[4][:4], ("gh", "run", "watch", "7"))
        self.assertEqual(order[5], ("api", "repos/saymiao/xdial-updates/actions/runs/7"))

        # Stable dispatches exactly as before the channel existed.
        found["workflow_runs"][0]["display_title"] = "Publish v1.2.3 [req]"
        order = self.dispatch("stable", "v1.2.3", [
            {"workflow_runs": []}, found, {"conclusion": "success"},
        ])
        self.assertEqual(order[1], (
            "gh", "workflow", "run", "publish.yml", "--repo", "saymiao/xdial-updates",
            "--ref", "main", "-f", "release_tag=v1.2.3", "-f", "operation=publish",
            "-f", "request_id=req",
        ))

        with self.assertRaisesRegex(RuntimeError, "cancelled"):
            self.dispatch("beta", "v1.4.0-beta.1", [
                {"workflow_runs": []}, found, {"conclusion": "cancelled"},
            ])

    def test_waiting_for_another_run_leaves_the_dispatched_run_its_whole_timeout(self):
        clock = types.SimpleNamespace(now=0)
        queued = {"workflow_runs": [{"status": "queued", "html_url": "https://example.invalid/6"}]}
        found = {"workflow_runs": [{"id": 7, "display_title": "publish stable v1.2.3 [req]",
                                    "html_url": "https://example.invalid/7"}]}
        commands = []

        def run(arguments, **kwargs):
            commands.append((tuple(arguments), kwargs))
            return subprocess.CompletedProcess(arguments, 0)

        def dispatch(replies):
            commands.clear()
            with (
                patch.object(PUBLISH, "gh_json", side_effect=replies),
                patch.object(PUBLISH.subprocess, "run", side_effect=run),
                patch.object(PUBLISH.uuid, "uuid4", return_value=types.SimpleNamespace(hex="req")),
                patch.object(PUBLISH.time, "monotonic", side_effect=lambda: clock.now),
                patch.object(PUBLISH.time, "sleep",
                             side_effect=lambda seconds: setattr(clock, "now", clock.now + seconds)),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                PUBLISH.dispatch_and_wait("v1.2.3", 60)

        # The earlier run takes 50 of the 60 seconds; the dispatched run still gets 60.
        dispatch([queued] * 5 + [{"workflow_runs": []}, found, {"conclusion": "success"}])
        watch = next(kwargs for command, kwargs in commands if command[:3] == ("gh", "run", "watch"))
        self.assertEqual(clock.now, 50)
        self.assertEqual(watch["timeout"], 60)

        # A run that outlasts the wait's own budget stops before anything is dispatched.
        clock.now = 0
        with self.assertRaisesRegex(TimeoutError, "still queued or running"):
            dispatch([queued] * 7)
        self.assertEqual(commands, [])

    def served(self, payload, *arguments):
        response = MagicMock()
        response.status = 200
        response.read.side_effect = lambda size: payload[:size]
        response.__enter__.return_value = response
        opener = MagicMock()
        opener.open.return_value = response
        with (
            patch.object(PUBLISH.urllib.request, "build_opener", return_value=opener),
            patch.object(PUBLISH.time, "sleep"),
            patch.object(PUBLISH.time, "monotonic", side_effect=itertools.count(0, 100)),
        ):
            PUBLISH.verify_feed(*arguments)
        return opener.open.call_args.args[0].full_url

    def test_feed_is_read_back_by_channel_in_the_unchanged_format(self):
        beta = feed_release("v1.4.0-beta.1", 200)
        arguments = ("v1.4.0-beta.1", "200", beta["archiveSHA256"], "beta", "- 修复更新检查。")
        payload = PUBLISH.render_feed(feed("beta", beta))
        self.assertEqual(self.served(payload, *arguments), PUBLISH.FEED_URLS["beta"])

        stable = feed_release("v1.2.3", 123)
        self.assertEqual(
            self.served(PUBLISH.render_feed(feed("stable", stable)),
                        "v1.2.3", "123", stable["archiveSHA256"]),
            "https://saymiao.github.io/xdial-updates/stable.json",
        )

        reordered = dict(reversed(list(beta.items())))
        bad = [
            PUBLISH.render_feed(feed("stable", beta)),
            PUBLISH.render_feed({**feed("beta", beta), "extra": True}),
            PUBLISH.render_feed(dict(reversed(list(feed("beta", beta).items())))),
            PUBLISH.render_feed(feed("beta", reordered)),
            json.dumps(feed("beta", beta), ensure_ascii=False, indent=4).encode() + b"\n",
            json.dumps(feed("beta", beta), indent=2).encode() + b"\n",
            json.dumps(feed("beta", beta), ensure_ascii=False, indent=2).encode(),
            PUBLISH.render_feed(feed("beta", {**beta, "releaseNotes": "- 别的说明。"})),
            PUBLISH.render_feed(feed("beta", {**beta, "build": "199"})),
            PUBLISH.render_feed(feed("beta", None)),
        ]
        for payload in bad:
            with self.subTest(payload=payload), self.assertRaises(RuntimeError):
                self.served(payload, *arguments)

    def test_beta_publication_stays_a_prerelease_and_writes_the_beta_feed(self):
        state = PUBLISH.FeedState(
            (package("v1.3.0", 100),),
            {"stable": feed("stable", feed_release("v1.3.0", 100)), "beta": feed("beta", None)},
        )
        draft = release_fixture("v1.4.0-beta.1", draft=True, prerelease=True)
        published = release_fixture("v1.4.0-beta.1", draft=False, prerelease=True)
        latest = {"tag_name": "v1.3.0"}
        with self.publication(["--channel", "beta", "v1.4.0-beta.1"],
                              [[[draft]], latest, published, latest], state, "200") as run:
            PUBLISH.main()
        run.remote.assert_called_once_with("v1.4.0-beta.1", "beta", PUBLISH.SOURCE_GIT_URL)
        self.assertEqual(run.verify_archive.call_args.args[2:], ("v1.4.0-beta.1", "beta"))
        self.assertEqual(self.edits(run), [(
            "gh", "release", "edit", "v1.4.0-beta.1", "--repo", "kafeifei/XDial",
            "--draft=false", "--prerelease", "--latest=false",
        )])
        # A pending Pages run is waited out while the release is still a draft.
        run.idle.assert_called_once_with(900)
        self.assertLess(run.events.index(("idle",)), run.events.index(self.edits(run)[0]))
        run.dispatch.assert_called_once_with("v1.4.0-beta.1", 900, "beta")
        run.verify_feed.assert_called_once_with(
            "v1.4.0-beta.1", "200", "digest", "beta", "- 修复更新检查。")

    def test_beta_publication_stops_before_pages_when_latest_moves(self):
        state = PUBLISH.FeedState((), {"stable": feed("stable", None), "beta": feed("beta", None)})
        draft = release_fixture("v1.4.0-beta.1", draft=True, prerelease=True)
        published = release_fixture("v1.4.0-beta.1", draft=False, prerelease=True)
        with self.publication(["--channel", "beta", "v1.4.0-beta.1"],
                              [[[draft]], {"tag_name": "v1.3.0"}, published,
                               {"tag_name": "v1.4.0-beta.1"}], state, "200") as run:
            with self.assertRaisesRegex(ValueError, "Latest release changed"):
                PUBLISH.main()
        run.dispatch.assert_not_called()

    def test_beta_is_refused_before_publication_by_the_feed_rules(self):
        beta_feed = {"stable": feed("stable", None), "beta": feed("beta", None)}
        # A public stable release that neither feed recorded and that is not Latest.
        unrecorded_stable = [release_fixture("v1.4.0", draft=False)]
        cases = [
            (PUBLISH.FeedState(), [], "no beta feed"),
            # Every published stable counts, withdrawn ones included.
            (PUBLISH.FeedState((package("v1.4.0", 150),), beta_feed, frozenset({"v1.4.0"})), [],
             "newer than every published stable release"),
            (PUBLISH.FeedState((), beta_feed), unrecorded_stable,
             "newer than every published stable release"),
            (PUBLISH.FeedState((package("v1.4.0-beta.2", 150),), beta_feed), [],
             "not newer than every release the beta feed has published"),
            (PUBLISH.FeedState((package("v1.4.0-beta.1", 150),), beta_feed,
                               frozenset({"v1.4.0-beta.1"})), [], "withdrawn"),
            (PUBLISH.FeedState((package("v1.3.0", 300),), beta_feed), [],
             "must be greater than build 300"),
        ]
        for state, others, error in cases:
            with self.subTest(error=error, others=others):
                draft = release_fixture("v1.4.0-beta.1", draft=True, prerelease=True)
                with self.publication(["--channel", "beta", "v1.4.0-beta.1"],
                                      [[[draft, *others]], {"tag_name": "v1.3.0"}],
                                      state, "200") as run:
                    with self.assertRaisesRegex(ValueError, error):
                        PUBLISH.main()
                self.assertEqual(self.edits(run), [])
                run.idle.assert_not_called()
                run.dispatch.assert_not_called()

    def lagging_state(self, beta_tag, beta_build):
        return PUBLISH.FeedState(
            (package("v1.2.2", 100), package(beta_tag, beta_build)),
            {"stable": feed("stable", feed_release("v1.2.2", 100)),
             "beta": feed("beta", feed_release(beta_tag, beta_build))},
        )

    def test_stable_requires_a_follow_up_for_a_beta_entry_left_with_a_build_not_higher(self):
        responses = lambda: [[[release_fixture("v1.2.3")]], {"tag_name": "v1.2.2"},
                             release_fixture("v1.2.3", draft=False)]
        state = self.lagging_state("v1.3.0-beta.1", 110)
        # Clients need a strictly higher build, so a beta entry with the same
        # build as this stable (123) fails the same way.
        for lagging in (state, self.lagging_state("v1.3.0-beta.1", 123)):
            with self.subTest(beta=lagging.feeds["beta"]["release"]["build"]):
                with self.publication(["v1.2.3"], responses(), lagging) as run:
                    with self.assertRaisesRegex(ValueError, "build_not_newer") as raised:
                        PUBLISH.main()
                self.assertIn("nothing was published", str(raised.exception))
                self.assertEqual(self.edits(run), [])
                run.idle.assert_not_called()
                run.dispatch.assert_not_called()

        for choice, step in [("withdraw", "-f operation=withdraw -f release_tag=v1.3.0-beta.1"),
                             ("republish", "RELEASE_TAG=v1.3.0-beta.2")]:
            with self.subTest(choice=choice):
                with self.publication(["--beta-followup", choice, "v1.2.3"],
                                      responses(), state) as run:
                    PUBLISH.main()
                self.assertIn("build_not_newer", run.stderr.getvalue())
                self.assertIn(step, run.stdout.getvalue())
                run.dispatch.assert_called_once_with("v1.2.3", 900, "stable")

        # A beta entry this stable supersedes, or one with a higher build, needs no follow-up.
        for beta_tag, beta_build in [("v1.2.3-beta.2", 110), ("v1.3.0-beta.1", 200)]:
            with self.subTest(beta=beta_tag):
                with self.publication(["v1.2.3"], responses(),
                                      self.lagging_state(beta_tag, beta_build)) as run:
                    PUBLISH.main()
                self.assertNotIn("build_not_newer", run.stderr.getvalue())
                run.dispatch.assert_called_once()

    def test_follow_mode_publishes_and_waits_for_the_feed_without_dispatching(self):
        state = self.lagging_state("v1.2.2-beta.1", 90)
        cases = [
            (["v1.2.3"], [[[release_fixture("v1.2.3")]], {"tag_name": "v1.2.2"},
                          release_fixture("v1.2.3", draft=False)],
             "v1.2.3", "stable", ("--latest",), 3600),
            (["--channel", "beta", "--pages-timeout", "120", "v1.3.0-beta.1"],
             [[[release_fixture("v1.3.0-beta.1", prerelease=True)]], {"tag_name": "v1.2.2"},
              release_fixture("v1.3.0-beta.1", draft=False, prerelease=True),
              {"tag_name": "v1.2.2"}],
             "v1.3.0-beta.1", "beta", ("--prerelease", "--latest=false"), 120),
        ]
        for argv, responses, tag, channel, listing, timeout in cases:
            with self.subTest(channel=channel):
                with self.publication(["--pages", "follow", *argv], responses, state, "200") as run:
                    PUBLISH.main()
                self.assertEqual(self.edits(run), [(
                    "gh", "release", "edit", tag, "--repo", "kafeifei/XDial", "--draft=false", *listing,
                )])
                # Nothing touches the update repository's Actions: no wait, no dispatch.
                run.idle.assert_not_called()
                run.dispatch.assert_not_called()
                run.verify_feed.assert_called_once_with(
                    tag, "200", "digest", channel, "- 修复更新检查。", timeout=timeout, interval=30)
                self.assertIn(PUBLISH.FOLLOW_WORKFLOW_URL, run.stdout.getvalue())

    def test_follow_mode_explains_a_feed_that_never_arrives(self):
        responses = [[[release_fixture("v1.3.0-beta.1", prerelease=True)]], {"tag_name": "v1.2.2"},
                     release_fixture("v1.3.0-beta.1", draft=False, prerelease=True),
                     {"tag_name": "v1.2.2"}]
        with self.publication(["--pages", "follow", "--channel", "beta", "v1.3.0-beta.1"],
                              responses, self.lagging_state("v1.2.2-beta.1", 90), "200") as run:
            run.verify_feed.side_effect = RuntimeError("Pages verification is incomplete")
            with self.assertRaisesRegex(RuntimeError, "Pages verification is incomplete") as raised:
                PUBLISH.main()
        message = str(raised.exception)
        self.assertIn(PUBLISH.FOLLOW_WORKFLOW_URL, message)
        self.assertIn("make publish RELEASE_CHANNEL=beta RELEASE_TAG=v1.3.0-beta.1", message)

    def test_feed_wait_uses_the_given_timeout_and_interval(self):
        clock = types.SimpleNamespace(now=0)
        opener = MagicMock()
        opener.open.side_effect = OSError("not served yet")
        sleeps = []

        def sleep(seconds):
            sleeps.append(seconds)
            clock.now += seconds

        with (
            patch.object(PUBLISH.urllib.request, "build_opener", return_value=opener),
            patch.object(PUBLISH.time, "monotonic", side_effect=lambda: clock.now),
            patch.object(PUBLISH.time, "sleep", side_effect=sleep),
        ):
            with self.assertRaisesRegex(RuntimeError, "not served yet"):
                PUBLISH.verify_feed("v1.2.3", "123", "digest", timeout=90, interval=30)
        self.assertEqual(sleeps, [30, 30, 30])


if __name__ == "__main__":
    unittest.main()
