"""Check fixture staging and XCTest opt-in without building or launching an app."""

from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock

from script import ci_automation_ui_fixture as helper


class AutomationUIFixtureTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.products = self.root / "Products"
        app = self.products / "Debug/Intents.app/Contents"
        app.mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.coryparry.FoundationEvals"}))
        self.descriptor = self.products / "FoundationEvals_macosx27.0-arm64.xctestrun"
        self.target = {"BlueprintName": "FoundationEvalsUITests", "IsUITestBundle": True,
                       "UITargetAppPath": "__TESTROOT__/Debug/Intents.app", "EnvironmentVariables": {"EXISTING": "kept"}}
        self.document = {"FoundationEvalsUITests": self.target, "FoundationEvalsTests": {"EnvironmentVariables": {"CORE": "unchanged"}}}
        self.descriptor.write_bytes(plistlib.dumps(self.document))
        self.developer = self.root / "Xcode.app/Contents/Developer"
        self.developer.mkdir(parents=True)
        self.repository = self.root / "repo"
        self.source = self.repository / "examples/AutomationFixture"
        (self.source / "App").mkdir(parents=True)
        (self.source / "project.yml").write_text("name: AutomationFixture")
        (self.source / "App/TaskIntents.swift").write_text("// source fixture")
        self.fixture = self.root / "shared/AutomationFixture"

    def generate(self, command, *, cwd, check, timeout):
        self.assertEqual(command, ["xcodegen", "generate", "--spec", str(self.fixture / "project.yml")])
        self.assertEqual(cwd, self.fixture)
        self.assertTrue(check)
        self.assertEqual(timeout, 60)
        project = self.fixture / "AutomationFixture.xcodeproj"
        project.mkdir()
        (project / "project.pbxproj").write_text("// generated project")

    def prepare(self):
        return helper.prepare_mac_fixture(self.products, self.developer, self.fixture, self.repository)

    def test_workflow_prepares_only_the_dedicated_mac_shard_before_strict_execution(self):
        workflow = (helper.ROOT / ".github/workflows/ci.yml").read_text()
        ui_job = workflow.split("  ui-tests:\n", 1)[1].split("\n  picker-stability:", 1)[0]
        setup = ui_job.split("      - name: Prepare selected live Mac UI fixture\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("if: ${{ matrix.mac_fixture == true }}", setup)
        self.assertIn("command -v xcodegen || brew install xcodegen", setup)
        self.assertIn('script/ci_automation_ui_fixture.py --products "$RUNNER_TEMP/Products" --developer-directory "$(xcode-select -p)"', setup)
        self.assertLess(ui_job.index("Prepare selected live Mac UI fixture"), ui_job.index("Run affected UI tests once"))
        self.assertIn("--timeout-seconds 900", ui_job)
        self.assertNotIn("continue-on-error", setup)

    def test_stages_committed_source_and_opts_in_only_the_ui_runner(self):
        with mock.patch.object(helper.subprocess, "run", side_effect=self.generate):
            self.assertEqual(self.prepare(), self.descriptor.resolve())
        self.assertEqual((self.fixture / "App/TaskIntents.swift").read_text(), "// source fixture")
        document = plistlib.loads(self.descriptor.read_bytes())
        self.assertEqual(document["FoundationEvalsUITests"]["EnvironmentVariables"], {
            "EXISTING": "kept", "INTENTS_AUTOMATION_LIVE_UI": "1", "INTENTS_AUTOMATION_DEVELOPER_DIR": str(self.developer.resolve())})
        self.assertEqual(document["FoundationEvalsTests"], self.document["FoundationEvalsTests"])
        self.assertNotIn("INTENTS_AUTOMATION_SIMULATOR_UUID", document["FoundationEvalsUITests"]["EnvironmentVariables"])
        self.assertFalse((self.source / "AutomationFixture.xcodeproj").exists())

    def test_generation_failure_cannot_leave_an_opted_in_descriptor(self):
        original = self.descriptor.read_bytes()
        with mock.patch.object(helper.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "xcodegen")):
            with self.assertRaises(subprocess.CalledProcessError):
                self.prepare()
        self.assertEqual(self.descriptor.read_bytes(), original)

    def test_missing_generated_project_is_rejected_before_opt_in(self):
        original = self.descriptor.read_bytes()
        with mock.patch.object(helper.subprocess, "run"):
            with self.assertRaisesRegex(ValueError, "project.pbxproj"):
                self.prepare()
        self.assertEqual(self.descriptor.read_bytes(), original)

    def test_replaces_previous_owned_fixture_and_rejects_symlink(self):
        self.fixture.mkdir(parents=True)
        (self.fixture / "stale.swift").touch()
        with mock.patch.object(helper.subprocess, "run", side_effect=self.generate):
            self.prepare()
        self.assertFalse((self.fixture / "stale.swift").exists())
        foreign = self.root / "foreign"
        foreign.mkdir()
        link = self.fixture.parent / "link"
        link.symlink_to(foreign)
        with self.assertRaisesRegex(ValueError, "symlink"):
            helper.prepare_mac_fixture(self.products, self.developer, link, self.repository)
        self.assertTrue(foreign.is_dir())

    def test_version_two_configuration_receives_the_same_opt_in(self):
        self.descriptor.write_bytes(plistlib.dumps({"__xctestrun_metadata__": {"FormatVersion": 2},
            "TestConfigurations": [{"Name": "Default", "TestTargets": [self.target]}]}))
        with mock.patch.object(helper.subprocess, "run", side_effect=self.generate):
            self.prepare()
        document = plistlib.loads(self.descriptor.read_bytes())
        self.assertEqual(document["TestConfigurations"][0]["TestTargets"][0]["EnvironmentVariables"]["INTENTS_AUTOMATION_LIVE_UI"], "1")


if __name__ == "__main__":
    unittest.main()
