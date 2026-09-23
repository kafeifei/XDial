import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "publish_next", Path(__file__).resolve().parents[1] / "scripts/publish-next-release.py"
)
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class NextPublishTests(unittest.TestCase):
    def test_exact_branch_and_tag(self):
        publisher.validate_remote_source("next-v0.9.0", "abc", {
            "refs/heads/xdial-next": "abc", "refs/tags/next-v0.9.0": "abc",
        })

    def test_annotated_tag_uses_peeled_commit(self):
        publisher.validate_remote_source("next-v0.9.0", "abc", {
            "refs/heads/xdial-next": "abc", "refs/tags/next-v0.9.0": "tag-object",
            "refs/tags/next-v0.9.0^{}": "abc",
        })

    def test_rejects_stable_tag_and_wrong_branch_or_commit(self):
        for tag, refs in [
            ("v0.9.0", {"refs/heads/xdial-next": "abc", "refs/tags/v0.9.0": "abc"}),
            ("next-v0.9.0", {"refs/heads/main": "abc", "refs/tags/next-v0.9.0": "abc"}),
            ("next-v0.9.0", {"refs/heads/xdial-next": "later", "refs/tags/next-v0.9.0": "abc"}),
            ("next-v0.9.0", {"refs/heads/xdial-next": "abc", "refs/tags/next-v0.9.0": "other"}),
        ]:
            with self.subTest(tag=tag, refs=refs), self.assertRaises(ValueError):
                publisher.validate_remote_source(tag, "abc", refs)

    def release(self, **changes):
        return {"tag_name": "next-v0.9.0", "prerelease": True,
                "assets": [{"name": "archive.zip", "state": "uploaded", "digest": "sha256:abc"}],
                **changes}

    def test_verified_asset(self):
        publisher.validate_assets(self.release(), "next-v0.9.0", {"archive.zip": "abc"})

    def test_rejects_stable_or_different_release(self):
        for changes in [{"prerelease": False}, {"tag_name": "next-v0.9.1"}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                publisher.validate_assets(self.release(**changes), "next-v0.9.0", {"archive.zip": "abc"})

    def test_rejects_missing_extra_or_incomplete_assets_and_hash_mismatch(self):
        for assets in [[], self.release()["assets"] * 2,
                       [{"name": "archive.zip", "state": "new", "digest": "sha256:abc"}],
                       [{"name": "other.zip", "state": "uploaded", "digest": "sha256:abc"}],
                       [{"name": "archive.zip", "state": "uploaded", "digest": "sha256:wrong"}]]:
            with self.subTest(assets=assets), self.assertRaises(ValueError):
                publisher.validate_assets(self.release(assets=assets), "next-v0.9.0", {"archive.zip": "abc"})


if __name__ == "__main__":
    unittest.main()
