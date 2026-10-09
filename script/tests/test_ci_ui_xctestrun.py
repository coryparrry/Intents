"""Exercise descriptor selection and the exact observed Xcode path correction."""

import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("ci_ui_xctestrun", ROOT / "script/ci_ui_xctestrun.py")
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class UIXctestrunTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.products = Path(self.temporary.name)
        self.descriptor = self.products / "FoundationEvals_macosx27.0-arm64.xctestrun"
        self.document = {
            "FoundationEvalsTests": {"TestHostPath": "__TESTROOT__/Debug/Intents.app", "EnvironmentVariables": {"CONTROL": "preserve"}},
            "FoundationEvalsUITests": {"BlueprintName": "FoundationEvalsUITests", "IsUITestBundle": True,
                                      "UITargetAppPath": "__TESTROOT__/Debug/Intents.app", "TestHostPath": "__TESTROOT__/Debug/FoundationEvalsUITests-Runner.app"},
            "__xctestrun_metadata__": {"FormatVersion": 1},
        }
        self.app = self.products / "Debug/Intents.app"
        (self.app / "Contents").mkdir(parents=True)
        self.info = self.app / "Contents/Info.plist"
        self.info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.coryparry.FoundationEvals"}))
        self.write_descriptor()

    def write_descriptor(self, format=plistlib.FMT_XML):
        self.descriptor.write_bytes(plistlib.dumps(self.document, fmt=format))

    def test_existing_correct_descriptor_is_selected_without_rewriting(self):
        original = self.descriptor.read_bytes()
        self.assertEqual(helper.prepare_ui_xctestrun(self.products), self.descriptor.resolve())
        self.assertEqual(self.descriptor.read_bytes(), original)

    def test_known_missing_executable_alias_is_corrected_and_other_fields_preserved(self):
        for format in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            with self.subTest(format=format):
                self.document["FoundationEvalsUITests"]["UITargetAppPath"] = "__TESTROOT__/Debug/FoundationEvals"
                self.write_descriptor(format)
                helper.prepare_ui_xctestrun(self.products)
                expected = dict(self.document)
                expected["FoundationEvalsUITests"] = dict(self.document["FoundationEvalsUITests"], UITargetAppPath="__TESTROOT__/Debug/Intents.app")
                self.assertEqual(plistlib.loads(self.descriptor.read_bytes()), expected)
                self.assertEqual(self.descriptor.read_bytes().startswith(b"bplist00"), format == plistlib.FMT_BINARY)

    def test_missing_or_multiple_full_descriptors_fail_without_skipping_ui(self):
        self.descriptor.unlink()
        with self.assertRaisesRegex(ValueError, "found 0"):
            helper.prepare_ui_xctestrun(self.products)
        self.write_descriptor()
        other = self.products / "FoundationEvals_macosx27.0-x86_64.xctestrun"
        other.write_bytes(self.descriptor.read_bytes())
        with self.assertRaisesRegex(ValueError, "found 2"):
            helper.prepare_ui_xctestrun(self.products)

    def test_core_only_descriptor_does_not_count_as_a_full_descriptor(self):
        core = self.products / "FoundationEvalsCoreCI_macosx27.0-arm64.xctestrun"
        self.descriptor.rename(core)
        with self.assertRaisesRegex(ValueError, "found 0"):
            helper.prepare_ui_xctestrun(self.products)

    def test_missing_or_non_ui_target_is_rejected(self):
        original = self.document["FoundationEvalsUITests"]
        for target in (None, {}, dict(original, BlueprintName="ForeignTests"), dict(original, IsUITestBundle=False)):
            with self.subTest(target=target):
                if target is None:
                    self.document.pop("FoundationEvalsUITests", None)
                else:
                    self.document["FoundationEvalsUITests"] = target
                self.write_descriptor()
                with self.assertRaisesRegex(ValueError, "UI target"):
                    helper.prepare_ui_xctestrun(self.products)

    def test_arbitrary_or_escaping_app_path_is_rejected_without_rewriting(self):
        for path in ("/Applications/Foreign.app", "__TESTROOT__/../Intents.app", "__TESTROOT__/Debug/Foreign.app"):
            with self.subTest(path=path):
                self.document["FoundationEvalsUITests"]["UITargetAppPath"] = path
                self.write_descriptor()
                original = self.descriptor.read_bytes()
                with self.assertRaisesRegex(ValueError, "app path"):
                    helper.prepare_ui_xctestrun(self.products)
                self.assertEqual(self.descriptor.read_bytes(), original)

    def test_wrong_app_identity_is_rejected_before_known_path_correction(self):
        self.document["FoundationEvalsUITests"]["UITargetAppPath"] = "__TESTROOT__/Debug/FoundationEvals"
        self.write_descriptor()
        original = self.descriptor.read_bytes()
        self.info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "example.Foreign"}))
        with self.assertRaisesRegex(ValueError, "bundle identifier"):
            helper.prepare_ui_xctestrun(self.products)
        self.assertEqual(self.descriptor.read_bytes(), original)

    def test_missing_app_is_rejected(self):
        self.info.unlink()
        (self.app / "Contents").rmdir()
        self.app.rmdir()
        with self.assertRaisesRegex(ValueError, "missing"):
            helper.prepare_ui_xctestrun(self.products)

    def test_malformed_descriptor_is_rejected(self):
        self.descriptor.write_bytes(b"not a plist")
        with self.assertRaises(plistlib.InvalidFileException):
            helper.prepare_ui_xctestrun(self.products)

    def test_workflow_executes_the_verified_descriptor_without_scheme_reconstruction(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        step = workflow.split("      - name: Run selected UI tests\n", 1)[1].split("      - name: Export UI test attachments\n", 1)[0]
        self.assertIn('python3 script/ci_ui_xctestrun.py "$RUNNER_TEMP/DerivedData/Build/Products"', step)
        self.assertIn('-xctestrun "$ui_xctestrun"', step)
        for option in ("-project ", "-scheme ", "-configuration ", "-derivedDataPath "):
            self.assertNotIn(option, step)
        self.assertIn("-only-testing:FoundationEvalsUITests/FoundationEvalsUITests", step)



if __name__ == "__main__":
    unittest.main()
