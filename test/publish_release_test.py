import copy
import importlib.util
import plistlib
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
    def release(self):
        return {
            "tag_name": "v1.2.3", "draft": True, "prerelease": False,
            "body": "## 更新了什么\n\n- 修复更新检查。",
            "assets": [
                {"name": name, "state": "uploaded", "size": 123,
                 "browser_download_url":
                 f"https://github.com/kafeifei/XDial/releases/download/v1.2.3/{name}"}
                for name in ["XDial-v1.2.3.zip", "XDial-v1.2.3.zip.sha256"]
            ],
        }

    def test_accepts_built_draft_and_idempotent_public_release(self):
        for draft in [True, False]:
            release = self.release()
            release["draft"] = draft
            self.assertEqual(PUBLISH.validate_release(release, "v1.2.3"),
                             ("XDial-v1.2.3.zip", "XDial-v1.2.3.zip.sha256"))

    def test_rejects_incomplete_or_mismatched_release_before_publication(self):
        mutations = [
            lambda release: release.update(prerelease=True),
            lambda release: release.update(tag_name="v1.2.4"),
            lambda release: release.update(draft=None),
            lambda release: release.update(body=" \n "),
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


if __name__ == "__main__":
    unittest.main()
