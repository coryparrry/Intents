"""Release validation and the GitHub-to-Homebrew publishing interaction."""

import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "script/update_homebrew.py"
spec = importlib.util.spec_from_file_location("update_homebrew", SCRIPT)
homebrew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(homebrew)


class UpdateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.tap = self.root / "tap"
        self.cask = self.tap / "Casks/intents.rb"
        self.payload = b"verified installer fixture"
        self.checksum = hashlib.sha256(self.payload).hexdigest()
        self.filename = "Intents-1.4.0-macOS-arm64.dmg"
        self.sums = f"{self.checksum}  {self.filename}\n"
        self.release = {
            "tagName": "v1.4.0", "isDraft": False, "isPrerelease": False,
            "assets": [
                {"name": self.filename, "size": len(self.payload),
                 "digest": f"sha256:{self.checksum}"},
                {"name": "SHA256SUMS.txt", "size": len(self.sums)},
            ],
        }
        self.downloads = 0

    def gh(self, *args):
        if args[:2] == ("release", "view"):
            return json.dumps(self.release)
        self.assertEqual(args[:2], ("release", "download"))
        self.downloads += 1
        destination = Path(args[args.index("--dir") + 1])
        (destination / self.filename).write_bytes(self.payload)
        (destination / "SHA256SUMS.txt").write_text(self.sums)
        return ""

    def update(self):
        with patch.object(homebrew, "gh", side_effect=self.gh):
            homebrew.update("v1.4.0", self.tap, "coryparrry/Intents")

    def seed(self, version="1.4.0", checksum=None):
        self.cask.parent.mkdir(parents=True)
        self.cask.write_text(homebrew.render_cask(
            version, checksum or self.checksum, "coryparrry/Intents",
        ))

    def test_published_installer_creates_installable_cask(self):
        self.update()
        content = self.cask.read_text()
        for expected in (f'sha256 "{self.checksum}"', 'version "1.4.0"',
                         'depends_on arch: :arm64', 'depends_on macos: :golden_gate',
                         'app "Intents.app"'):
            self.assertIn(expected, content)

    def test_retry_does_not_rewrite_cask(self):
        self.seed()
        before = self.cask.stat().st_mtime_ns
        self.update()
        self.assertEqual(self.cask.stat().st_mtime_ns, before)

    def test_older_release_cannot_roll_back_cask(self):
        self.seed("1.10.0")
        before = self.cask.read_bytes()
        self.update()
        self.assertEqual(self.downloads, 0)
        self.assertEqual(self.cask.read_bytes(), before)

    def test_newer_release_replaces_older_cask(self):
        self.seed("1.3.0")
        self.update()
        self.assertIn('version "1.4.0"', self.cask.read_text())

    def test_unpublished_prerelease_and_mismatched_tag_are_rejected(self):
        for field, value in (("isDraft", True), ("isPrerelease", True),
                             ("tagName", "v1.3.0")):
            with self.subTest(field=field):
                original = self.release[field]
                self.release[field] = value
                with self.assertRaises(ValueError):
                    self.update()
                self.release[field] = original
                self.assertFalse(self.cask.exists())
        self.assertEqual(self.downloads, 0)

    def test_invalid_tags_never_call_github(self):
        for tag in ("1.4.0", "v1.4.0-rc1", "v1.04.0", "v1.4", "v1.4.0\n", "--help"):
            with self.subTest(tag=tag), patch.object(homebrew, "gh") as gh:
                with self.assertRaises(ValueError):
                    homebrew.update(tag, self.tap, "coryparrry/Intents")
                gh.assert_not_called()

    def test_missing_empty_or_duplicate_assets_are_rejected(self):
        original = self.release["assets"]
        for assets in (original[:1], original[1:], original + [original[0]],
                       [dict(original[0], size=0), original[1]]):
            with self.subTest(assets=assets):
                self.release["assets"] = assets
                with self.assertRaises(ValueError):
                    self.update()
                self.assertFalse(self.cask.exists())

    def test_bad_missing_duplicate_or_wrong_file_checksum_preserves_cask(self):
        self.seed("1.3.0")
        before = self.cask.read_bytes()
        valid = self.sums
        for sums in ("0" * 64 + f"  {self.filename}\n", "", valid * 2,
                     valid.replace(self.filename, "different.dmg")):
            with self.subTest(sums=sums):
                self.sums = sums
                with self.assertRaises(ValueError):
                    self.update()
                self.assertEqual(self.cask.read_bytes(), before)

    def test_github_digest_and_size_must_match_download(self):
        asset = self.release["assets"][0]
        for field, value in (("digest", "sha256:" + "0" * 64), ("size", 1)):
            with self.subTest(field=field):
                original = asset[field]
                asset[field] = value
                with self.assertRaises(ValueError):
                    self.update()
                asset[field] = original
                self.assertFalse(self.cask.exists())

    def test_older_github_assets_without_digest_still_verify_checksum(self):
        del self.release["assets"][0]["digest"]
        self.update()
        self.assertTrue(self.cask.exists())

    def test_same_version_cannot_change_checksum(self):
        self.seed(checksum="0" * 64)
        before = self.cask.read_bytes()
        with self.assertRaisesRegex(ValueError, "existing cask version"):
            self.update()
        self.assertEqual(self.cask.read_bytes(), before)

    def test_failed_download_preserves_cask(self):
        self.seed("1.3.0")
        before = self.cask.read_bytes()
        with patch.object(homebrew, "gh", side_effect=[
            json.dumps(self.release), subprocess.CalledProcessError(1, ["gh"]),
        ]), self.assertRaises(subprocess.CalledProcessError):
            homebrew.update("v1.4.0", self.tap, "coryparrry/Intents")
        self.assertEqual(self.cask.read_bytes(), before)

    def test_invalid_existing_cask_is_preserved(self):
        self.seed()
        self.cask.write_text('cask "intents" do\nend\n')
        with self.assertRaisesRegex(ValueError, "Existing cask"):
            self.update()

    def test_cli_and_workflow_publish_then_retry_without_new_commit(self):
        fixture = self.root / "fixture"
        fixture.mkdir()
        (fixture / "release.json").write_text(json.dumps(self.release))
        (fixture / self.filename).write_bytes(self.payload)
        (fixture / "SHA256SUMS.txt").write_text(self.sums)
        binary = self.root / "bin"
        binary.mkdir()
        stub = binary / "gh"
        stub.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''
            import os, shutil, sys
            from pathlib import Path
            args = sys.argv[1:]
            fixture = Path(os.environ["FIXTURE_DIR"])
            if args[:2] == ["release", "view"]:
                print((fixture / "release.json").read_text())
            elif args[:2] == ["release", "download"]:
                destination = Path(args[args.index("--dir") + 1])
                for index, arg in enumerate(args):
                    if arg == "--pattern":
                        shutil.copy(fixture / args[index + 1], destination)
            else:
                sys.exit("Unexpected GitHub command")
        '''))
        stub.chmod(0o755)
        remote = self.root / "remote.git"
        subprocess.run(["git", "init", "--quiet", "--bare", str(remote)], check=True)
        self.seed("1.3.0")
        def git(*args):
            return subprocess.check_output(["git", *args], cwd=self.tap, text=True).strip()
        git("init", "--quiet", "-b", "main")
        git("config", "user.name", "Fixture")
        git("config", "user.email", "fixture@example.invalid")
        git("add", "Casks/intents.rb")
        git("commit", "--quiet", "-m", "chore(cask): seed previous release")
        git("remote", "add", "origin", str(remote))
        workflow = (ROOT / ".github/workflows/update-homebrew.yml").read_text()
        publish = textwrap.dedent(workflow.split("working-directory: tap\n        run: |\n")[1])
        environment = dict(os.environ, FIXTURE_DIR=str(fixture),
                           PATH=f"{binary}:{os.environ['PATH']}", RELEASE_TAG="v1.4.0")
        heads = []
        for _ in range(2):
            subprocess.run([sys.executable, str(SCRIPT), "v1.4.0", "--tap-dir", str(self.tap),
                            "--repo", "coryparrry/Intents"], env=environment, check=True,
                           capture_output=True, text=True)
            subprocess.run(["bash", "-euo", "pipefail", "-c", publish], cwd=self.tap,
                           env=environment, check=True, capture_output=True, text=True)
            heads.append(git("rev-parse", "HEAD"))
        self.assertEqual(heads[0], heads[1])
        published = subprocess.check_output([
            "git", "--git-dir", str(remote), "show", "main:Casks/intents.rb",
        ], text=True)
        self.assertEqual(published, self.cask.read_text())
        self.assertEqual(git("status", "--porcelain"), "")

    def test_packaging_chains_update_after_successful_publication(self):
        packaging = (ROOT / ".github/workflows/package-installer.yml").read_text()
        job = packaging.split("\n  homebrew:\n")[1]
        for contract in ("needs: release", "uses: ./.github/workflows/update-homebrew.yml",
                         "tag: ${{ inputs.tag }}", "secrets: inherit"):
            self.assertIn(contract, job)
        self.assertNotIn("always()", job)


if __name__ == "__main__":
    unittest.main()
