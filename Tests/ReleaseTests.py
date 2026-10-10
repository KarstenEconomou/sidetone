import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "version", Path(__file__).resolve().parent.parent / "Scripts/version.py"
)
version = importlib.util.module_from_spec(spec)
spec.loader.exec_module(version)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.root_patch = patch.object(version, "ROOT", self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Release Tests")
        self.git("config", "user.email", "tests@example.invalid")
        (self.root / "VERSION").write_text("1.0.0\n")
        self.commit("feat(app): add monitoring")

    def git(self, *arguments):
        return subprocess.check_output(
            ["git", *arguments], cwd=self.root, text=True, stderr=subprocess.PIPE
        ).strip()

    def commit(self, message):
        self.git("add", "VERSION")
        self.git("commit", "-q", "--allow-empty", "-m", message)

    def test_first_release_is_one_zero_zero(self):
        self.assertEqual(version.check_release("1.0.0"), "1.0.0")
        (self.root / "VERSION").write_text("0.1.0\n")
        with self.assertRaises(ValueError):
            version.check_version()

    def test_stable_version_format(self):
        self.assertEqual(version.parse_version("1.10.0"), (1, 10, 0))
        for value in ["01.0.0", "1.01.0", "1.0", "v1.0.0", "1.0.0-rc.1", "1.0.0+1"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                version.parse_version(value)

    def test_patch_for_fixes(self):
        self.git("tag", "v1.0.0")
        self.commit("fix(audio): recover the output route")
        self.assertEqual(version.next_version(), "1.0.1")
        self.assertEqual(version.check_version(), "1.0.0")

    def test_features_take_priority_over_fixes(self):
        self.git("tag", "v1.0.0")
        self.commit("feat(app): add a setting")
        self.commit("fix(audio): recover the output route")
        self.assertEqual(version.next_version(), "1.1.0")

    def test_breaking_change_in_title_or_body(self):
        self.git("tag", "v1.0.0")
        for message in [
            "feat(app)!: change saved settings",
            "refactor(app): change saved settings\n\nBREAKING CHANGE: The settings format changes.",
        ]:
            with self.subTest(message=message):
                self.commit(message)
                self.assertEqual(version.next_version(), "2.0.0")

    def test_numeric_version_order(self):
        self.git("tag", "v1.9.0")
        self.commit("feat(app): add a setting")
        self.git("tag", "v1.10.0")
        self.commit("fix(app): correct the setting")
        self.assertEqual(version.next_version(), "1.10.1")

    def test_release_version_must_match_changes_and_file(self):
        self.git("tag", "v1.0.0")
        self.commit("feat(app): add a setting")
        with self.assertRaises(ValueError):
            version.check_release("1.0.0")
        (self.root / "VERSION").write_text("1.0.1\n")
        with self.assertRaises(ValueError):
            version.check_release("1.0.1")
        (self.root / "VERSION").write_text("1.1.0\n")
        self.commit("chore(release): prepare v1.1.0")
        self.assertEqual(version.check_release("1.1.0"), "1.1.0")

    def test_existing_release_tag_must_match_commit(self):
        self.git("tag", "v1.0.0")
        self.assertEqual(version.check_release("1.0.0"), "1.0.0")
        self.commit("fix(app): correct a setting")
        with self.assertRaises(ValueError):
            version.check_release("1.0.0")

    def test_branch_must_include_latest_release(self):
        base = self.git("rev-parse", "HEAD")
        self.commit("feat(app): add a setting")
        self.git("tag", "v1.1.0")
        self.git("switch", "-q", "--detach", base)
        with self.assertRaises(ValueError):
            version.check_version()

    def test_pull_request_titles_require_type_and_scope(self):
        for title in ["fix(audio): recover the route", "feat(app)!: change the settings"]:
            version.check_title(title)
        for title in ["Fix audio", "feat: add a setting", "feat(app):", "unknown(app): change"]:
            with self.subTest(title=title), self.assertRaises(ValueError):
                version.check_title(title)


if __name__ == "__main__":
    unittest.main()
