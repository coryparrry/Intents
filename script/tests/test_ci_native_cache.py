"""Real Git checkouts exercise content-aware, confined Xcode cache metadata."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "ci_native_cache.py"
spec = importlib.util.spec_from_file_location("ci_native_cache", SCRIPT)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class NativeCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "repo"
        self.root.mkdir()
        self.derived = Path(self.temporary.name) / "DerivedData"
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True)

    def tracked(self, name="Sources/Example.swift", contents="let value = 1"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
        subprocess.run(["git", "add", "--", name], cwd=self.root, check=True)
        return path

    def write_manifest(self, files):
        self.derived.mkdir(exist_ok=True)
        (self.derived / cache.MANIFEST).write_text(json.dumps({"version": 1, "files": files}))

    def test_unchanged_contents_restore_captured_nanosecond_mtime(self):
        path = self.tracked("Sources/file with spaces.swift")
        previous = 1_700_000_000 * cache.SECOND + 12345
        os.utime(path, ns=(previous, previous))
        self.assertEqual(cache.capture(self.root, self.derived), 1)
        os.utime(path, ns=(previous, previous + 50 * cache.SECOND))
        self.assertEqual(cache.restore(self.root, self.derived), (1, 0))
        self.assertEqual(path.stat().st_mtime_ns, previous)

    def test_same_size_changed_content_gets_distinct_second_despite_mtime_collision(self):
        path = self.tracked()
        previous = 1_700_000_000 * cache.SECOND
        os.utime(path, ns=(previous, previous))
        cache.capture(self.root, self.derived)
        path.write_text("let value = 2")
        os.utime(path, ns=(previous, previous + 5))
        self.assertEqual(cache.restore(self.root, self.derived), (0, 1))
        self.assertGreater(path.stat().st_mtime_ns // cache.SECOND, previous // cache.SECOND)
        self.assertEqual(path.read_text(), "let value = 2")

    def test_changed_content_with_fresh_time_keeps_checkout_time(self):
        path = self.tracked()
        cache.capture(self.root, self.derived)
        previous = path.stat().st_mtime_ns
        path.write_text("let value = 2")
        fresh = previous + 50 * cache.SECOND
        os.utime(path, ns=(fresh, fresh))
        self.assertEqual(cache.restore(self.root, self.derived), (0, 1))
        self.assertEqual(path.stat().st_mtime_ns, fresh)

    def test_missing_cache_is_noop_and_does_not_create_derived_data(self):
        path = self.tracked()
        before = path.stat().st_mtime_ns
        self.assertEqual(cache.restore(self.root, self.derived), (0, 0))
        self.assertEqual(path.stat().st_mtime_ns, before)
        self.assertFalse(self.derived.exists())

    def test_untracked_files_and_symlinks_are_never_captured_or_modified(self):
        outside = Path(self.temporary.name) / "outside"
        outside.write_text("private")
        before = outside.stat().st_mtime_ns
        (self.root / "untracked.swift").write_text("untracked")
        (self.root / "linked.swift").symlink_to(outside)
        subprocess.run(["git", "add", "linked.swift"], cwd=self.root, check=True)
        self.assertEqual(cache.capture(self.root, self.derived), 0)
        self.write_manifest({"linked.swift": {"sha256": hashlib.sha256(b"private").hexdigest(), "mtime_ns": 1}})
        self.assertEqual(cache.restore(self.root, self.derived), (0, 0))
        self.assertEqual(outside.stat().st_mtime_ns, before)

    def test_symlink_parent_cannot_escape_checkout(self):
        path = self.tracked()
        cache.capture(self.root, self.derived)
        outside = Path(self.temporary.name) / "outside"
        outside.mkdir()
        (outside / "Example.swift").write_text(path.read_text())
        before = (outside / "Example.swift").stat().st_mtime_ns
        path.unlink()
        path.parent.rmdir()
        path.parent.symlink_to(outside, target_is_directory=True)
        self.assertEqual(cache.restore(self.root, self.derived), (0, 0))
        self.assertEqual((outside / "Example.swift").stat().st_mtime_ns, before)

    def test_malformed_metadata_is_rejected_before_any_source_change(self):
        path = self.tracked()
        before = path.stat().st_mtime_ns
        entry = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "mtime_ns": 1}
        for bad in ("../outside", "/outside", "Sources/../outside", "Sources//file", "./outside", ".", ""):
            with self.subTest(path=bad):
                self.write_manifest({"Sources/Example.swift": entry, bad: entry})
                with self.assertRaises(ValueError):
                    cache.restore(self.root, self.derived)
                self.assertEqual(path.stat().st_mtime_ns, before)
        for bad in ({"sha256": "bad", "mtime_ns": 1}, {"sha256": entry["sha256"], "mtime_ns": True},
                    {"sha256": entry["sha256"], "mtime_ns": -1}, {"sha256": entry["sha256"], "mtime_ns": cache.MAX_TIME}):
            with self.subTest(entry=bad):
                self.write_manifest({"Sources/Example.swift": bad})
                with self.assertRaises(ValueError):
                    cache.restore(self.root, self.derived)
                self.assertEqual(path.stat().st_mtime_ns, before)

    def test_symlink_manifest_is_rejected_without_reading_target(self):
        outside = Path(self.temporary.name) / "outside"
        outside.write_text("sensitive")
        self.derived.mkdir()
        (self.derived / cache.MANIFEST).symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symlink"):
            cache.restore(self.root, self.derived)

    def test_manifest_schema_and_json_must_be_valid(self):
        self.derived.mkdir()
        for invalid in ("not json", "[]", '{"version": true, "files": {}}',
                        '{"version": 2, "files": {}}', '{"version": 1, "files": []}'):
            with self.subTest(manifest=invalid):
                (self.derived / cache.MANIFEST).write_text(invalid)
                with self.assertRaises(ValueError):
                    cache.restore(self.root, self.derived)

    def test_cli_rejects_symlink_derived_data_directory(self):
        outside = Path(self.temporary.name) / "outside"
        outside.mkdir()
        self.derived.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            cache.main(["capture", "--root", str(self.root), "--derived-data", str(self.derived)])
        self.assertEqual(list(outside.iterdir()), [])

    def test_cli_capture_and_restore(self):
        self.tracked()
        for operation in ("capture", "restore"):
            self.assertIsNone(cache.main([operation, "--root", str(self.root), "--derived-data", str(self.derived)]))


if __name__ == "__main__":
    unittest.main()
