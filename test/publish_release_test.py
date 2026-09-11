import copy
import importlib.util
import plistlib
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch


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
            patch.object(PUBLISH, "dispatch_and_wait"),
            patch.object(PUBLISH, "verify_feed"),
        ):
            PUBLISH.main()

        commands = [call.args[0] for call in run.call_args_list]
        self.assertFalse(any(command[:3] == ["gh", "release", "edit"] for command in commands))


if __name__ == "__main__":
    unittest.main()
