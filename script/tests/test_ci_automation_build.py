"""Executable reuse validates complete inputs and cached artifacts without Apple tools."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "ci_automation_build.py"
spec = importlib.util.spec_from_file_location("ci_automation_build", SCRIPT)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class Tools:
    def __init__(self, compiler):
        self.compiler = compiler
        self.env = {"DEVELOPER_DIR": "/Applications/Selected.app/Contents/Developer", "PATH": "/usr/bin"}
        self.responses = {}

    def run(self, command):
        key = " ".join(command)
        default = str(self.compiler) if command == ["xcrun", "--find", "swift"] else "identity:" + key
        return 0, self.responses.get(key, default)


class AutomationExecutableTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        base = Path(self.temporary.name)
        self.root, self.scratch = base / "repo", base / "cache"
        for name in cache.SOURCE_ROOTS:
            (self.root / name).mkdir(parents=True)
        (self.root / "Package.swift").write_text("supported root manifest")
        nested = self.root / "Packages/Local/Package.swift"
        nested.parent.mkdir()
        nested.write_text("supported local manifest")
        manifests = {name: cache.sha256(self.root / name) for name in ("Package.swift", "Packages/Local/Package.swift")}
        supported = patch.object(cache, "MANIFESTS", manifests)
        supported.start()
        self.addCleanup(supported.stop)
        self.source = self.root / "Sources/Core.swift"
        self.source.write_text("let value = 1")
        self.compiler = base / "swift"
        self.compiler.write_bytes(b"compiler")
        self.tools = Tools(self.compiler)
        self.arguments = ["xcrun", "swift", "build", "--product", "intents-automation", "--scratch-path", str(self.scratch)]
        self.cli = self.scratch / "out/Products/Debug/intents-automation"
        self.cli.parent.mkdir(parents=True)
        self.cli.write_bytes(b"compiled executable")
        self.cli.chmod(0o755)
        self.bundle = self.cli.parent / "Package_IntentsAutomationCLIResources.bundle"
        self.host = self.bundle / "AutomationHost/HostPlan.swift"
        self.host.parent.mkdir(parents=True)
        self.host.write_text("host template")

    def current(self):
        return cache.build_fingerprint(self.tools, self.root, self.scratch, self.arguments)

    def checkpoint(self):
        expected = self.current()
        self.assertIsInstance(expected, str)
        cache.record_cli(self.scratch, expected, self.cli)
        return expected

    def test_valid_checkpoint_reuses_executable_after_unrelated_workflow_or_ui_test_edit(self):
        expected = self.checkpoint()
        for relative in (".github/workflows/ci.yml", "FoundationEvals/FoundationEvalsUITests/ReviewTests.swift"):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("unrelated change")
        self.assertEqual(self.current(), expected)
        self.assertEqual(cache.cached_cli(self.scratch, expected)[0], self.cli)

    def test_source_same_size_change_addition_deletion_and_mode_invalidate(self):
        expected = self.checkpoint()
        original, mode = self.source.read_text(), self.source.stat().st_mode & 0o777
        self.source.write_text("let value = 2")
        self.assertNotEqual(self.current(), expected)
        self.source.write_text(original)
        extra = self.root / "Integration/new resource.bin"
        extra.write_bytes(b"new")
        self.assertNotEqual(self.current(), expected)
        extra.unlink()
        self.source.unlink()
        self.assertNotEqual(self.current(), expected)
        self.source.write_text(original)
        self.source.chmod(mode ^ 0o100)
        self.assertNotEqual(self.current(), expected)

    def test_root_and_nested_manifest_changes_addition_and_deletion_disable_reuse(self):
        for relative in cache.MANIFESTS:
            path = self.root / relative
            original = path.read_text()
            path.write_text(original + " new external dependency")
            self.assertIsNone(self.current())
            path.unlink()
            self.assertIsNone(self.current())
            path.write_text(original)
        extra = self.root / "Packages/New/Package.swift"
        extra.parent.mkdir()
        extra.write_text("new package")
        self.assertIsNone(self.current())

    def test_resolved_dependencies_and_swiftpm_configuration_invalidate(self):
        expected = self.checkpoint()
        resolved = self.root / "Package.resolved"
        resolved.write_text("resolved dependency")
        self.assertNotEqual(self.current(), expected)
        expected = self.current()
        resolved.write_text("different dependency")
        self.assertNotEqual(self.current(), expected)
        configuration = self.root / ".swiftpm/configuration/settings.json"
        configuration.parent.mkdir(parents=True)
        configuration.write_text("configuration")
        self.assertNotEqual(self.current(), expected)

    def test_compiler_binary_version_sdk_xcode_architecture_flags_and_environment_invalidate(self):
        expected = self.checkpoint()
        for query in ("xcrun swift --version", "xcodebuild -version", "xcrun --sdk macosx --show-sdk-path",
                      "xcrun --sdk macosx --show-sdk-build-version", "uname -m", "sw_vers -buildVersion"):
            with self.subTest(query=query):
                self.tools.responses[query] = "different identity"
                self.assertNotEqual(self.current(), expected)
                self.tools.responses.clear()
        self.compiler.write_bytes(b"different compiler")
        self.assertNotEqual(self.current(), expected)
        self.compiler.write_bytes(b"compiler")
        self.arguments.extend(["-Xswiftc", "-DCHANGED"])
        self.assertNotEqual(self.current(), expected)
        del self.arguments[-2:]
        self.tools.env["OTHER_SWIFT_FLAGS"] = "-DCHANGED"
        self.assertNotEqual(self.current(), expected)

    def test_missing_or_empty_toolchain_identity_disables_reuse(self):
        self.tools.responses["xcrun swift --version"] = ""
        self.assertIsNone(self.current())

    def test_header_pkg_config_and_dynamic_loader_environment_changes_invalidate(self):
        expected = self.checkpoint()
        for key in ("OBJC_INCLUDE_PATH", "PKG_CONFIG_PATH", "PKG_CONFIG_LIBDIR", "PKG_CONFIG_SYSROOT_DIR",
                    "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "DYLD_INSERT_LIBRARIES", "LD_LIBRARY_PATH"):
            with self.subTest(variable=key):
                self.tools.env[key] = "/changed/build/environment"
                self.assertNotEqual(self.current(), expected)
                del self.tools.env[key]

    def test_hidden_directories_inside_copied_host_resources_invalidate(self):
        (self.root / "Integration/AutomationHost").mkdir()
        expected = self.checkpoint()
        for name in (".build", ".git", ".swiftpm"):
            with self.subTest(directory=name):
                resource = self.root / "Integration/AutomationHost" / name / "copied-resource"
                resource.parent.mkdir(parents=True, exist_ok=True)
                resource.write_text("resource copied into the generated host")
                self.assertNotEqual(self.current(), expected)
                resource.unlink()
                resource.parent.rmdir()
                self.assertEqual(self.current(), expected)

    def test_legacy_and_malformed_receipts_never_reuse(self):
        expected = self.current()
        self.assertIsNone(cache.cached_cli(self.scratch, expected)[0])
        self.checkpoint()
        receipt = self.scratch / cache.RECEIPT
        valid = json.loads(receipt.read_text())
        for invalid in ("not JSON", "[]", json.dumps({**valid, "schema": True}),
                        json.dumps({**valid, "fingerprint": "different"}), json.dumps({**valid, "extra": True})):
            with self.subTest(invalid=invalid[:70]):
                receipt.write_text(invalid)
                self.assertIsNone(cache.cached_cli(self.scratch, expected)[0])

    def test_unsafe_receipt_paths_are_rejected_without_outside_access(self):
        expected = self.checkpoint()
        receipt = self.scratch / cache.RECEIPT
        valid = json.loads(receipt.read_text())
        for path in ("../outside", "/outside", "out/../outside", "out//outside", ".", ""):
            receipt.write_text(json.dumps({**valid, "cli": path}))
            with self.subTest(path=path):
                self.assertIsNone(cache.cached_cli(self.scratch, expected)[0])
        receipt.unlink()
        outside = self.root / "outside"
        outside.write_text("not a receipt")
        receipt.symlink_to(outside)
        with patch.object(cache.json, "loads") as parse:
            self.assertIsNone(cache.cached_cli(self.scratch, expected)[0])
        parse.assert_not_called()

    def test_modified_missing_and_nonexecutable_binary_invalidate(self):
        expected = self.checkpoint()
        self.cli.write_bytes(b"changed executable")
        self.assertEqual(cache.cached_cli(self.scratch, expected), (None, True))
        self.cli.write_bytes(b"compiled executable")
        self.cli.chmod(0o644)
        self.assertIsNone(cache.cached_cli(self.scratch, expected)[0])
        self.cli.unlink()
        self.assertIsNone(cache.cached_cli(self.scratch, expected)[0])

    def test_changed_inputs_request_incremental_rebuild_and_not_product_cleanup(self):
        self.checkpoint()
        self.source.write_text("different source")
        self.assertEqual(cache.cached_cli(self.scratch, self.current()), (None, False))

    def test_changed_added_deleted_and_modified_mode_resource_inventory_invalidate(self):
        expected = self.checkpoint()
        original, mode = self.host.read_text(), self.host.stat().st_mode & 0o777
        self.host.write_text("changed host template")
        self.assertIsNone(cache.cached_cli(self.scratch, expected)[0])
        self.host.write_text(original)
        extra = self.host.parent / "New.swift"
        extra.write_text("new template")
        self.assertIsNone(cache.cached_cli(self.scratch, expected)[0])
        extra.unlink()
        self.host.chmod(mode ^ 0o100)
        self.assertIsNone(cache.cached_cli(self.scratch, expected)[0])
        self.host.chmod(mode)
        self.host.unlink()
        self.assertIsNone(cache.cached_cli(self.scratch, expected)[0])

    def test_source_binary_and_resource_symlinks_disable_reuse(self):
        expected = self.checkpoint()
        linked = self.root / "Sources/Linked.swift"
        linked.symlink_to(self.source)
        self.assertIsNone(self.current())
        linked.unlink()
        self.host.unlink()
        self.host.symlink_to(self.source)
        self.assertIsNone(cache.cached_cli(self.scratch, expected)[0])
        self.cli.unlink()
        self.cli.symlink_to(self.compiler)
        self.assertIsNone(cache.cached_cli(self.scratch, expected)[0])

    def test_unsupported_layout_cannot_create_or_keep_a_checkpoint(self):
        self.checkpoint()
        cache.record_cli(self.scratch, None, self.cli)
        self.assertFalse((self.scratch / cache.RECEIPT).exists())
        self.assertIsNone(cache.cached_cli(self.scratch, None)[0])

    def test_normal_build_replaces_receipt_symlink_without_touching_target(self):
        outside = self.root / "outside"
        outside.write_text("untouched")
        receipt = self.scratch / cache.RECEIPT
        receipt.symlink_to(outside)
        expected = self.current()
        cache.record_cli(self.scratch, expected, self.cli)
        self.assertFalse(receipt.is_symlink())
        self.assertEqual(outside.read_text(), "untouched")
        self.assertEqual(cache.cached_cli(self.scratch, expected), (self.cli, False))


if __name__ == "__main__":
    unittest.main()
