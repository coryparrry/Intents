"""Dependency selections, package contracts, and complete Git/event routing."""

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "script/ci_routes.py"
spec = importlib.util.spec_from_file_location("ci_routes", SCRIPT)
routes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(routes)


def selections(plan):
    return {
        key: plan[key]
        for key in ("native", "ui", "swift_suites", "python_tests", "macos_tests")
    }


class CoverageTests(unittest.TestCase):
    def test_automation_execution_contract_changes_select_simulator_e2e(self):
        for path in (
            "Sources/IntentsAutomationCore/AutomationApplicationRunner.swift",
            "Integration/AutomationHost/IntentDefinitionsHost.swift",
            "FoundationEvals/FoundationEvals/Stores/AppAutomationStore.swift",
            "FoundationEvals/FoundationEvals/Stores/AppAutomationStore+Run.swift",
            "FoundationEvals/FoundationEvals/Stores/AutomationNativeUIRuntime.swift",
            "Tools/IntentsAutomationApplicationProbe/main.swift",
            "Sources/IntentsAutomationTool/AutomationCLI.swift",
            "examples/AutomationFixture/App/EchoIntents.swift",
            "script/automation_e2e.py", "script/tests/test_automation_e2e.py",
            "Package.swift", ".github/workflows/ci.yml",
        ):
            with self.subTest(path=path):
                self.assertTrue(routes.coverage([path])["automation_e2e"])

    def test_automation_e2e_routes_conservatively_when_history_or_path_is_unknown(self):
        self.assertTrue(routes.coverage(None)["automation_e2e"])
        self.assertTrue(routes.coverage(["unknown-new-tool.swift"])["automation_e2e"])
        self.assertFalse(routes.coverage(["docs/wiki/App-automation.md"])["automation_e2e"])
        self.assertFalse(routes.coverage([routes.APP + "Services/MetricScorer.swift"])["automation_e2e"])

    def test_homebrew_updater_and_workflow_select_their_regressions(self):
        for path in ("script/update_homebrew.py", ".github/workflows/update-homebrew.yml"):
            with self.subTest(path=path):
                self.assert_selection([path], python=("script.tests.test_update_homebrew",))

    def assert_selection(
        self, paths, native=False, ui=False, swift=(), python=(), macos=()
    ):
        self.assertEqual(
            selections(routes.coverage(paths)),
            {
                "native": native,
                "ui": ui,
                "swift_suites": sorted(swift),
                "python_tests": sorted(python),
                "macos_tests": sorted(macos),
            },
        )

    def test_docs_media_and_github_metadata_need_no_unit_tests(self):
        self.assert_selection(
            [
                "README.md",
                ".github/FUNDING.yml",
                ".github/CODEOWNERS",
                ".github/assets/demo.gif",
                "docs/releasing.md",
                ".gitignore",
                "worklog.md",
                "examples/custom_model_fixture_server.py",
            ]
        )

    def test_release_workflow_fix_skips_native_and_unrelated_script_suites(self):
        self.assert_selection(
            [
                ".github/workflows/release-me.yml",
                "script/release_pr.py",
                "script/tests/test_release_pr.py",
                "docs/releasing.md",
            ],
            python=(
                "script.tests.test_release_pr",
                "script.tests.test_release_dispatch",
                "script.tests.test_release_validation",
                "script.tests.test_wait_release_ci",
            ),
        )

    def test_release_validator_includes_its_transitive_consumers(self):
        self.assert_selection(
            ["script/release_validation.py"],
            python=(
                "script.tests.test_release_validation",
                "script.tests.test_update_feed",
                "script.tests.test_release_dispatch",
            ),
        )

    def test_script_test_only_changes_run_that_module(self):
        self.assert_selection(
            ["script/tests/test_release_pr.py"],
            python=("script.tests.test_release_pr",),
        )

    def test_release_packaging_selects_its_validation_and_platform_checks(self):
        self.assert_selection(
            ["script/release.sh"],
            python=routes.RELEASE_VALIDATION,
            macos=routes.MACOS_TESTS,
        )
        self.assert_selection(
            [".github/workflows/package-installer.yml"],
            python=routes.RELEASE_VALIDATION
            | {"script.tests.test_wait_release_ci", "script.tests.test_update_homebrew"},
        )

    def test_signature_code_and_test_run_on_macos_without_xcode_build(self):
        for path in (
            "script/verify_update_signature.swift",
            "script/tests/test_update_signature.py",
        ):
            with self.subTest(path=path):
                self.assert_selection(
                    [path], macos=("script.tests.test_update_signature",)
                )

    def test_shortcut_routing_test_runs_on_macos(self):
        self.assert_selection(
            ["script/tests/test_fixture_shortcut_routing.py"],
            macos=("script.tests.test_fixture_shortcut_routing",),
        )

    def test_shortcut_metadata_validator_selects_its_regressions(self):
        self.assert_selection(
            ["script/check_fixture_shortcut_metadata.py"],
            python=("script.tests.test_fixture_shortcut_metadata",),
        )

    def test_installer_wrapper_includes_native_signature_verification(self):
        self.assert_selection(
            ["script/verify_installer.sh"],
            python=routes.RELEASE_VALIDATION,
            macos=routes.MACOS_TESTS,
        )

    def test_scoring_change_only_runs_its_portable_suite(self):
        self.assert_selection(
            [routes.APP + "Services/MetricScorer.swift"],
            native=True,
            swift=("MetricScorerTests",),
        )

    def test_shared_scoring_types_select_both_dependent_suites(self):
        self.assert_selection(
            [routes.APP + "Models/EvaluationScoringTypes.swift"],
            native=True,
            ui=True,
            swift=("MetricScorerTests", "EvaluationFieldAssertionTests"),
        )

    def test_timeline_geometry_selects_interval_and_rendering_tests(self):
        self.assert_selection(
            [routes.APP + "Models/WorkflowTimelineInterval.swift"],
            native=True,
            ui=True,
            swift=("WorkflowTimelineIntervalTests", "TimelineRenderingTests"),
        )

    def test_scenario_execution_dependencies_select_contract_tests(self):
        for source in (
            "ScenarioExecutionRecovery.swift",
            "XCTestRunInvocationTransport.swift",
            "XcodeConnectionDiscovery.swift",
        ):
            with self.subTest(source=source):
                expected = ["ScenarioContractsTests"]
                if source != "ScenarioExecutionRecovery.swift":
                    expected += ["ScenarioPhysicalLeaseTests", "ScenarioPhysicalFailureTests"]
                if source == "XcodeTestExecutor.swift":
                    expected += ["XcodeBundleLayoutTests"]
                self.assert_selection(
                    [routes.APP + "Services/" + source],
                    native=True,
                    swift=expected,
                )

    def test_new_migration_and_physical_sources_select_their_regressions(self):
        self.assert_selection(
            [routes.APP + "Services/ScenarioPersistence+AutomationEvidence.swift"],
            native=True, swift=("ScenarioAutomationEvidenceTests",),
        )
        for source in ("ScenarioPhysicalRunnerLease.swift", "ScenarioRunnerReceiptImporter.swift"):
            with self.subTest(source=source):
                self.assert_selection(
                    [routes.APP + "Services/" + source], native=True,
                    swift=("ScenarioPhysicalLeaseTests", "ScenarioPhysicalFailureTests"),
                )
        for source in ("IntentLabProjectInstaller.swift", "OpenStepProjectDocument.swift"):
            with self.subTest(source=source):
                self.assert_selection(
                    [routes.APP + "Services/" + source], native=True,
                    swift=("IntentLabProjectInstallerTests",),
                )

    def test_executor_changes_select_contract_and_helper_regressions(self):
        self.assert_selection(
            [routes.APP + "Services/XcodeTestExecutor.swift"],
            native=True,
            swift=("ScenarioContractsTests", "ExecutorSimplificationTests", "XcodeBundleLayoutTests", "XcodeSyntheticReadinessTests",
                   "ScenarioPhysicalLeaseTests", "ScenarioPhysicalFailureTests"),
        )
        for suite in ("ExecutorSimplificationTests", "XcodeBundleLayoutTests", "XcodeSyntheticReadinessTests"):
            with self.subTest(suite=suite):
                self.assert_selection(
                    [routes.TESTS + suite + ".swift"],
                    native=True,
                    swift=(suite,),
                    python=("script.tests.test_ci_routes",),
                )

    def test_project_installer_sources_select_installer_tests(self):
        for source in (
            "IntentLabProjectInstaller.swift",
            "OpenStepProjectDocument.swift",
        ):
            with self.subTest(source=source):
                self.assert_selection(
                    [routes.APP + "Services/" + source],
                    native=True,
                    swift=("IntentLabProjectInstallerTests",),
                )

    def test_sidebar_and_toolbar_do_not_rerun_scoring_or_installer_tests(self):
        for source, suite in (
            ("FullWidthDisclosureStyle.swift", "NavigationInteractionTests"),
            ("RunToolbarProgress.swift", "RunToolbarProgressTests"),
        ):
            with self.subTest(source=source):
                self.assert_selection(
                    [routes.APP + "Views/Components/" + source],
                    native=True,
                    ui=True,
                    swift=(suite,),
                )

    def test_app_code_excluded_from_package_does_not_run_unrelated_portable_tests(self):
        self.assert_selection(
            [routes.APP + "Services/EvaluationRunner.swift"], native=True
        )
        self.assert_selection([routes.APP + "MCP/MCPServer.swift"], native=True)
        self.assert_selection(
            [routes.APP + "Views/WorkflowTraceView.swift"], native=True, ui=True
        )
        self.assert_selection(
            [routes.APP + "Stores/EvaluationStore.swift"], native=True, ui=True
        )

    def test_settings_controllers_still_compile_ui_test_bundle(self):
        for source in (
            "MCP/Installer/MCPSettingsController.swift",
            "Services/TelemetryController.swift",
        ):
            with self.subTest(source=source):
                self.assert_selection([routes.APP + source], native=True, ui=True)

    def test_portable_test_edits_select_the_changed_suite_and_validate_its_name(self):
        self.assert_selection(
            [routes.TESTS + "MetricScorerTests.swift"],
            native=True,
            swift=("MetricScorerTests",),
            python=("script.tests.test_ci_routes",),
        )
        self.assert_selection(
            [routes.TESTS + "TimelineRenderingTests.swift"],
            native=True,
            ui=True,
            swift=("TimelineRenderingTests",),
            python=("script.tests.test_ci_routes",),
        )

    def test_app_only_tests_compile_without_running_unrelated_portable_suites(self):
        self.assert_selection(
            [routes.TESTS + "EvaluationJudgeTests.swift"], native=True, ui=True
        )
        self.assert_selection(
            ["FoundationEvals/FoundationEvalsUITests/WorkflowTraceUITests.swift"],
            native=True,
            ui=True,
        )

    def test_mixed_paths_union_dependencies(self):
        self.assert_selection(
            [
                "README.md",
                "script/release_pr.py",
                routes.APP + "MCP/Installer/CodexMCPInstaller.swift",
                routes.APP + "Views/Components/RunToolbarProgress.swift",
            ],
            native=True,
            ui=True,
            swift=("CodexMCPInstallerTests", "RunToolbarProgressTests"),
            python=("script.tests.test_release_pr",),
        )

    def test_ci_dependencies_releases_and_unknown_paths_require_full_coverage(self):
        for path in (
            ".github/workflows/ci.yml",
            "script/ci_routes.py",
            "script/ci_run_tests.py",
            "script/tests/test_ci_routes.py",
            "script/tests/test_ci_run_tests.py",
            "Package.swift",
            "version.txt",
            ".release-please-manifest.json",
            ".github/workflows/new.yml",
            "FoundationEvals/FoundationEvals.xcodeproj/project.pbxproj",
            "new-runtime/code.swift",
        ):
            with self.subTest(path=path):
                plan = routes.coverage(["README.md", path])
                self.assertEqual(
                    selections(plan), selections(routes.full_coverage("fixture"))
                )

    def test_core_scheme_changes_build_core_without_unrelated_portable_tests(self):
        self.assert_selection(
            ["script/ci_core_scheme.py"],
            native=True,
            python=("script.tests.test_ci_core_scheme",),
        )

    def test_removed_or_unmapped_script_uses_remaining_script_inventory(self):
        for path in ("script/tests/test_removed.py", "script/new_tool.py"):
            with self.subTest(path=path):
                plan = routes.coverage([path])
                self.assertFalse(plan["native"])
                self.assertEqual(
                    plan["python_tests"], sorted(routes.python_test_inventory())
                )
                self.assertEqual(plan["macos_tests"], sorted(routes.MACOS_TESTS))

    def test_removed_script_test_routes_only_modules_in_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tests = root / "script/tests"
            tests.mkdir(parents=True)
            (tests / "test_remaining.py").touch()
            plan = routes.coverage(["script/tests/test_deleted.py"], root=root)
            self.assertEqual(plan["python_tests"], ["script.tests.test_remaining"])
            self.assertEqual(plan["macos_tests"], sorted(routes.MACOS_TESTS))
            self.assertFalse(plan["native"])
            self.assertFalse(plan["ui"])


class MatrixTests(unittest.TestCase):
    def selected_ui(self, paths):
        return {
            test for group in routes.coverage(paths)["ui_matrix"] for test in group["tests"]
        }

    def test_full_matrix_preserves_every_previous_selector_and_picker_once(self):
        expected = {
            "FoundationEvalsUITests/FoundationEvalsUITests",
            "FoundationEvalsUITests/IntentLabGuidanceUITests",
            "FoundationEvalsUITests/SimplificationUITests",
            "FoundationEvalsUITests/FoundationEvalsRunLifecycleUITests/testRunProgressCompletionAndHistoryRestoration",
            "FoundationEvalsUITests/WorkflowTraceUITests/testWorkspaceResetConfirmationAndPersistence",
            "FoundationEvalsUITests/AutomationDependencyControlsUITests",
        } | {"FoundationEvalsUITests/AppAutomationUITests/" + method for method in (
            "testUnpreparedPhysicalSiriFormKeepsSubmissionDisabled",
            "testXcodeDefaultsFollowDestinationAndRestoreWithoutRunOverride",
            "testEmptyAutomationAndPickerCancellationRemainReadOnly",
            "testOwnershipResetConfirmationCanBeCancelledWithoutChangingTheReservation",
            "testPreparationPickersUseStableIdentifiers",
        )}
        matrix = routes.full_coverage("fixture")["ui_matrix"]
        selections = [test for group in matrix for test in group["tests"]]
        self.assertEqual(set(selections), expected)
        self.assertEqual(len(selections), len(expected))
        self.assertEqual(len(matrix), 5)

    def test_feature_view_runs_its_full_regression_class_without_other_features(self):
        for view, expected, unrelated in (
            ("WorkflowTraceView", "WorkflowTraceUITests", "IntentLabGuidanceUITests"),
            ("AppAutomationView", "AppAutomationUITests", "WorkflowTraceUITests"),
            ("IntentLabView", "IntentLabArrayEntryUITests", "AppAutomationUITests"),
        ):
            with self.subTest(view=view):
                selected = self.selected_ui([routes.APP + "Views/" + view + ".swift"])
                self.assertIn(routes.UI_TARGET + expected, selected)
                self.assertFalse(any(test.startswith(routes.UI_TARGET + unrelated) for test in selected))
                self.assertFalse(any(test.startswith(routes.UI_TARGET + expected + "/") for test in selected))

    def test_shared_and_unknown_ui_sources_keep_the_full_baseline(self):
        baseline = self.selected_ui(None)
        for path in (
            "Views/Components/SidebarNavigationList.swift", "Views/UnmappedView.swift",
            "Stores/EvaluationStore.swift", "Models/EvaluationScoringTypes.swift",
            "Views/Components/WorkflowTraceView.swift",
        ):
            with self.subTest(path=path):
                self.assertEqual(self.selected_ui([routes.APP + path]), baseline)

    def test_changed_ui_class_runs_whole_class_including_previously_unselected_tests(self):
        for suite in ("WorkflowTraceUITests", "AppAutomationUITests", "EvaluationReviewUITests"):
            with self.subTest(suite=suite):
                self.assertEqual(
                    self.selected_ui([routes.UI_TESTS + suite + ".swift"]),
                    {routes.UI_TARGET + suite},
                )

    def test_mixed_changes_deduplicate_whole_classes_and_preserve_affected_new_class(self):
        paths = [
            ".github/workflows/ci.yml", routes.UI_TESTS + "EvaluationReviewUITests.swift",
            routes.UI_TESTS + "AppAutomationUITests.swift",
            routes.APP + "Views/WorkflowTraceView.swift",
        ]
        selected = self.selected_ui(paths)
        self.assertIn(routes.UI_TARGET + "EvaluationReviewUITests", selected)
        self.assertIn(routes.UI_TARGET + "AppAutomationUITests", selected)
        self.assertIn(routes.UI_TARGET + "WorkflowTraceUITests", selected)
        self.assertFalse(any(test.startswith(routes.UI_TARGET + "AppAutomationUITests/") for test in selected))
        self.assertEqual(selected, self.selected_ui(list(reversed(paths))))

    def test_new_class_name_is_discovered_without_a_manual_catalog_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = routes.UI_TESTS + "NewFeature.swift"
            source = root / path
            source.parent.mkdir(parents=True)
            source.write_text("final class NewFeatureUITests: XCTestCase { func testNewCase() {} }")
            plan = routes.coverage([path], root=root)
            self.assertEqual(plan["ui_matrix"], [{
                "name": "suite-editor", "tests": [routes.UI_TARGET + "NewFeatureUITests"],
            }])

    def test_changed_ui_support_or_removed_ui_test_uses_baseline(self):
        baseline = self.selected_ui(None)
        for path in ("Support/UITestStorage.swift", "RemovedUITests.swift"):
            with self.subTest(path=path):
                self.assertEqual(self.selected_ui([routes.UI_TESTS + path]), baseline)

    def test_native_ui_helpers_and_tests_route_real_native_execution(self):
        for path, module in routes.NATIVE_UI_HELPERS.items():
            for changed in (path, module.replace(".", "/") + ".py"):
                with self.subTest(path=changed):
                    plan = routes.coverage([changed])
                    self.assertTrue(plan["native"])
                    self.assertTrue(plan["ui"])
                    self.assertEqual(plan["ui_matrix"], routes.full_coverage("fixture")["ui_matrix"])
                    self.assertIn(module, plan["python_tests"])
        self.assertEqual(
            routes.coverage([".github/workflows/ui-stability.yml"])["ui_matrix"],
            routes.full_coverage("fixture")["ui_matrix"],
        )

    def test_script_matrix_runs_selected_modules_exactly_once_in_up_to_four_jobs(self):
        for count in range(10):
            with self.subTest(count=count):
                modules = [f"script.tests.test_{index}" for index in range(count)]
                matrix = routes.python_matrix(modules + modules)
                self.assertEqual(matrix, routes.python_matrix(list(reversed(modules))))
                self.assertEqual(sorted(test for group in matrix for test in group["tests"]), sorted(modules))
                self.assertEqual(len(matrix), min(4, count))
                if matrix:
                    lengths = [len(group["tests"]) for group in matrix]
                    self.assertLessEqual(max(lengths) - min(lengths), 1)
        self.assertEqual(routes.coverage(["README.md"])["python_matrix"], [])
        self.assertEqual(routes.coverage(["README.md"])["ui_matrix"], [])

    def test_leaf_routes_only_name_existing_top_level_views(self):
        for path in routes.UI_VIEW_GROUPS:
            self.assertEqual(len(Path(path).parts), 2)
            self.assertTrue((ROOT / routes.APP / path).is_file(), path)

    def test_every_ui_selector_names_a_current_test_class_and_method(self):
        for group in routes.full_coverage("fixture")["ui_matrix"]:
            for selection in group["tests"]:
                with self.subTest(selection=selection):
                    _, suite, *method = selection.split("/")
                    source = (ROOT / routes.UI_TESTS / (suite + ".swift")).read_text()
                    self.assertRegex(source, r"\bclass " + re.escape(suite) + r"\s*:\s*XCTestCase")
                    if method:
                        self.assertRegex(source, r"\bfunc " + re.escape(method[0]) + r"\(")


class CatalogTests(unittest.TestCase):
    def test_every_portable_source_and_suite_has_a_route(self):
        manifest = (ROOT / "Package.swift").read_text()

        def strings(pattern):
            match = re.search(pattern, manifest, re.DOTALL)
            self.assertIsNotNone(
                match, "Update the route catalog check when the package layout changes"
            )
            return set(re.findall(r'"([^"\n]+)"', match.group(1)))

        core = strings(r"let portableProductionSources = \[(.*?)\]")
        ui = strings(r'name: "FoundationEvalsUIComponents".*?sources: \[(.*?)\]')
        tests = strings(r"let portableTestSources = \[(.*?)\]")
        self.assertEqual(
            set(routes.SWIFT_DEPENDENCIES),
            core | {"Views/Components/" + name for name in ui},
        )
        self.assertEqual({suite + ".swift" for suite in routes.SWIFT_SUITES}, tests)
        for suite in routes.SWIFT_SUITES:
            source = (ROOT / routes.TESTS / (suite + ".swift")).read_text()
            self.assertRegex(source, r"\b(?:struct|class) " + re.escape(suite) + r"\b")

    def test_script_mappings_reference_existing_modules(self):
        mapped = set().union(*routes.PYTHON_DEPENDENCIES.values()) | routes.MACOS_TESTS
        self.assertLessEqual(
            mapped, routes.python_test_inventory() | routes.MACOS_TESTS
        )
        for module in mapped:
            self.assertTrue(
                (ROOT / (module.replace(".", "/") + ".py")).is_file(), module
            )
        self.assertFalse(routes.python_test_inventory() & routes.MACOS_TESTS)


class GitEventTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.git("init", "-b", "main")
        self.git("config", "user.email", "ci@example.invalid")
        self.git("config", "user.name", "CI fixture")
        self.base = self.commit("README.md", "start")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True).strip()

    def commit(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        self.git("add", "--all")
        self.git("commit", "-qm", "fixture")
        return self.git("rev-parse", "HEAD")

    def run_event(self, name, event):
        event_path = self.root / "event.json"
        event_path.write_text(json.dumps(event))
        output = self.root / "outputs"
        output.write_text("")
        subprocess.run(
            [sys.executable, str(SCRIPT)],
            cwd=self.root,
            check=True,
            capture_output=True,
            env=dict(
                os.environ,
                GITHUB_EVENT_NAME=name,
                GITHUB_EVENT_PATH=str(event_path),
                GITHUB_OUTPUT=str(output),
                GITHUB_STEP_SUMMARY=str(self.root / "summary"),
            ),
        )
        return {
            key: json.loads(value)
            for key, value in (
                line.split("=", 1) for line in output.read_text().splitlines()
            )
        }

    def test_pull_request_routes_entire_branch_despite_latest_docs_commit(self):
        self.git("checkout", "-qb", "feature")
        self.commit(routes.APP + "Services/MetricScorer.swift", "native")
        head = self.commit("README.md", "docs")
        self.git("checkout", "main")
        base = self.commit("CHANGELOG.md", "unrelated base change")
        result = self.run_event(
            "pull_request",
            {"pull_request": {"base": {"sha": base}, "head": {"sha": head}}},
        )
        self.assertTrue(result["native"])
        self.assertFalse(result["ui"])
        self.assertTrue(result["regression"])
        self.assertEqual(result["swift_suites"], ["MetricScorerTests"])
        self.assertEqual(result["python_tests"], [])
        self.assertEqual(result["ui_matrix"], [])
        self.assertEqual(result["python_matrix"], [])

    def test_push_uses_previous_tip_not_parent(self):
        self.commit(routes.APP + "Views/Components/RunToolbarProgress.swift", "UI")
        head = self.commit("README.md", "docs")
        result = self.run_event("push", {"before": self.base, "after": head})
        self.assertTrue(result["native"])
        self.assertTrue(result["ui"])
        self.assertEqual(result["swift_suites"], ["RunToolbarProgressTests"])

    def test_deletion_and_rename_out_of_native_tree_still_select_dependents(self):
        native = routes.APP + "Services/MetricScorer.swift"
        base = self.commit(native, "scorer")
        self.git("mv", native, "README.md", "--force")
        self.git("commit", "-qm", "move source to docs")
        result = self.run_event(
            "push", {"before": base, "after": self.git("rev-parse", "HEAD")}
        )
        self.assertTrue(result["native"])
        self.assertEqual(result["swift_suites"], ["MetricScorerTests"])

    def test_docs_only_push_skips_all_test_jobs_and_reports_why(self):
        head = self.commit("README.md", "new docs")
        result = self.run_event("push", {"before": self.base, "after": head})
        self.assertFalse(result["native"])
        self.assertFalse(result["regression"])
        self.assertEqual(result["python_tests"], [])
        self.assertIn("need no unit tests", (self.root / "summary").read_text())

    def test_signature_change_uses_regression_job_but_not_native_build(self):
        head = self.commit("script/verify_update_signature.swift", "verifier")
        result = self.run_event("push", {"before": self.base, "after": head})
        self.assertFalse(result["native"])
        self.assertTrue(result["regression"])
        self.assertEqual(result["swift_suites"], [])
        self.assertEqual(result["macos_tests"], ["script.tests.test_update_signature"])

    def test_missing_history_malformed_and_manual_events_use_full_coverage(self):
        for name, event in [
            ("workflow_dispatch", {}),
            ("push", {"before": "0" * 40, "after": self.base}),
            ("push", {"before": "f" * 40, "after": self.base}),
            ("push", {}),
            ("push", {"before": None, "after": self.base}),
            ("pull_request", {"pull_request": []}),
            ("push", None),
        ]:
            with self.subTest(name=name, event=event):
                result = self.run_event(name, event)
                self.assertTrue(result["native"])
                self.assertTrue(result["ui"])
                self.assertTrue(result["automation_e2e"])
                self.assertEqual(result["swift_suites"], ["*"])
                self.assertEqual(
                    result["python_tests"], sorted(routes.python_test_inventory())
                )


if __name__ == "__main__":
    unittest.main()
