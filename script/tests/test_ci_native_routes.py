"""Verify native feature dependencies and conservative unit-test routing."""

from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "script"))
from ci_native_routes import APP, TESTS, UI_TESTS, DEPENDENCIES, TARGET, select_native_tests


class NativeRoutingTests(unittest.TestCase):
    def test_automation_view_selects_its_hosted_native_contract_only(self):
        self.assertEqual(select_native_tests([APP + "Views/AppAutomationView.swift"], True, ROOT),
                         [TARGET + "/AppAutomationSelectionViewTests"])

    def test_settings_exclude_automation_and_run_units(self):
        tests = select_native_tests([APP + "Views/AppSettingsView.swift"], True, ROOT)
        self.assertIn(TARGET + "/MCPDebugLaunchConfigurationTests", tests)
        self.assertIn(TARGET + "/TelemetryTransportTests", tests)
        self.assertNotIn(TARGET + "/AppAutomationSelectionViewTests", tests)
        self.assertNotIn(TARGET + "/RunBaselineSelectionTests", tests)

    def test_disjoint_features_union_their_native_suites(self):
        self.assertEqual(select_native_tests([
            APP + "Views/AppAutomationView.swift", APP + "Views/ScenarioEditorView.swift",
        ], True, ROOT), [TARGET + "/AppAutomationSelectionViewTests", TARGET + "/IntentLabArrayInputTests", TARGET + "/WorkspacePresentationTests"])

    def test_shared_unknown_or_build_changes_keep_full_units(self):
        for path in (APP + "ContentView.swift", APP + "Models/Unknown.swift", "Package.swift", "script/ci_native_cache.py"):
            self.assertEqual(select_native_tests([path], True, ROOT), [TARGET])
        self.assertEqual(select_native_tests(None, True, ROOT), [TARGET])

    def test_ui_test_only_changes_do_not_run_unrelated_native_units(self):
        self.assertEqual(select_native_tests([UI_TESTS + "AppAutomationUITests.swift"], True, ROOT), [])
        self.assertEqual(select_native_tests([UI_TESTS + "AppAutomationUITests.swift", "docs/usage.md"], True, ROOT), [])
        self.assertEqual(select_native_tests([APP + "ContentView.swift"], False, ROOT), [])
        self.assertEqual(select_native_tests(["unknown.config"], True, ROOT, full=True), [TARGET])

    def test_all_suites_in_changed_unit_file_are_selected(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / (TESTS + "TelemetryTests.swift")
            source.parent.mkdir(parents=True)
            source.write_text("struct ControllerTests {}\nclass TransportTests: XCTestCase {}\n")
            self.assertEqual(select_native_tests([str(source.relative_to(temporary))], True, temporary),
                             [TARGET + "/ControllerTests", TARGET + "/TransportTests"])
            source.write_text("struct ControllerTests {}\nstruct SharedHelper {}\n")
            self.assertEqual(select_native_tests([str(source.relative_to(temporary))], True, temporary), [TARGET])
            source.write_text("struct OtherTests {}\nextension FirstTests { @Test func addedCase() {} }\n")
            self.assertEqual(select_native_tests([str(source.relative_to(temporary))], True, temporary), [TARGET])

    def test_removed_unit_file_falls_back_to_remaining_units(self):
        self.assertEqual(select_native_tests([TESTS + "RemovedTests.swift"], True, ROOT), [TARGET])

    def test_mapped_native_suite_symbols_exist_in_the_current_target(self):
        sources = "\n".join(path.read_text() for path in (ROOT / TESTS).glob("*.swift"))
        for suites in DEPENDENCIES.values():
            for suite in suites:
                self.assertRegex(sources, r"\b(?:struct|class|actor)\s+" + suite + r"\b")


if __name__ == "__main__":
    unittest.main()
