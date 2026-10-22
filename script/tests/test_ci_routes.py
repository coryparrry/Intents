"""Dependency selections, package contracts, and complete Git/event routing."""

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
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


    def test_mac_intent_support_selects_surviving_package_tests(self):
        plan = routes.coverage(["Sources/MacIntentTesting/Catalog.swift"])
        self.assertEqual(plan["swift_suites"], ["*"])
        self.assertTrue(plan["sdk_consumer"])
        self.assertFalse(plan["input_conversion"])
        self.assertFalse(plan["ui"])
        self.assertTrue(plan["native"])
        self.assertEqual(plan["native_tests"], ["FoundationEvalsTests"])
        self.assertEqual(plan["ui_matrix"], [])

    def test_native_intent_cli_changes_select_parser_and_manifest_contracts(self):
        self.assert_selection(["Sources/MacIntentTestingCLI/NativeTestsOptions.swift"],
                              swift=("NativeTestsCLITests",))
        plan = routes.coverage(["Sources/MacIntentTestingCLI/NativeTestsMain.swift"])
        self.assertEqual(plan["native_tests"], [])
        self.assertEqual(plan["ui_matrix"], [])

    def test_mac_intent_unit_changes_select_the_declared_suite(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "Tests/MacIntentTestingTests/CatalogTests.swift"
            source.parent.mkdir(parents=True)
            source.write_text("struct MacIntentTestingTests {}")
            plan = routes.coverage([str(source.relative_to(directory))], Path(directory))
        self.assertEqual(plan["swift_suites"], ["MacIntentTestingTests"])
        self.assertFalse(plan["native"])

    def test_evaluation_cli_changes_select_macos_integration_checks(self):
        self.assert_selection(["script/foundation-evals"], macos=("script.tests.test_foundation_evals_cli",))

    def test_mac_signing_changes_select_focused_regressions(self):
        for path in ("script/ci_macos_signing.py", "script/tests/test_ci_macos_signing.py"):
            with self.subTest(path=path):
                self.assert_selection([path], python=("script.tests.test_ci_macos_signing",))
                self.assertFalse(routes.coverage([path])["input_conversion"])

    def test_homebrew_updater_and_workflow_select_their_regressions(self):
        for path in ("script/update_homebrew.py", ".github/workflows/update-homebrew.yml"):
            with self.subTest(path=path):
                self.assert_selection([path], python=("script.tests.test_update_homebrew",))

    def test_symbol_uploader_tests_are_discovered_and_routed(self):
        module = "script.tests.test_upload_posthog_symbols"
        self.assertIn(module, routes.python_test_inventory())
        for path in ("script/upload_posthog_symbols.sh", "script/tests/test_upload_posthog_symbols.py"):
            with self.subTest(path=path):
                self.assert_selection([path], python=(module,))


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

    def test_website_changes_skip_native_tests(self):
        paths = ["website/dist/app.js", "website/tests/demo.test.mjs"]
        self.assert_selection(paths)
        plan = routes.coverage(paths)
        self.assertEqual(plan["native_tests"], [])
        self.assertFalse(plan["input_conversion"])

    def test_metadata_workflow_changes_select_its_checks_without_native_tests(self):
        self.assert_selection([".github/workflows/pr-metadata.yml"],
                              python=("script.tests.test_release_notes", "script.tests.test_ci_workflow"))

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
            | {"script.tests.test_wait_release_ci", "script.tests.test_update_homebrew", "script.tests.test_package_installer_workflow"},
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


    def test_installer_wrapper_includes_native_signature_verification(self):
        self.assert_selection(
            ["script/verify_installer.sh"],
            python=routes.RELEASE_VALIDATION,
            macos=routes.MACOS_TESTS,
        )

    def test_scoring_change_runs_its_portable_suite_and_run_ui(self):
        self.assert_selection(
            [routes.APP + "Services/MetricScorer.swift"],
            native=True,
            ui=True,
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
            [routes.APP + "Services/EvaluationRunner.swift"], native=True, ui=True
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
            swift=("TimelineRenderingTests",),
            python=("script.tests.test_ci_routes",),
        )

    def test_app_only_tests_compile_without_running_unrelated_portable_suites(self):
        self.assert_selection(
            [routes.TESTS + "EvaluationJudgeTests.swift"], native=True
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

    def test_native_cache_changes_require_all_compilation_and_execution_coverage(self):
        for path in ("script/ci_native_cache.py", "script/tests/test_ci_native_cache.py"):
            with self.subTest(path=path):
                plan = routes.coverage([path])
                self.assertTrue(plan["native"])
                self.assertTrue(plan["ui"])
                self.assertEqual(plan["swift_suites"], ["*"])
                self.assertEqual(plan["ui_matrix"], routes.full_coverage("fixture")["ui_matrix"])
                self.assertEqual(plan["python_tests"], sorted(routes.python_test_inventory()))

    def test_workflow_contract_test_change_runs_its_own_module(self):
        self.assert_selection(
            ["script/tests/test_ci_workflow.py"],
            python=("script.tests.test_ci_workflow",),
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


    def test_full_ui_selection_resolves_only_classes_present_in_the_checkout(self):
        catalog = routes.ordinary_ui_classes()
        selected = self.selected_ui(None)
        self.assertTrue(selected)
        for selector in selected:
            self.assertIn(selector.split("/")[1], catalog, selector)

    def test_literal_ui_json_resources_exist_in_the_synchronized_bundle_root(self):
        resources = []
        for source in (ROOT / routes.UI_TESTS).rglob("*.swift"):
            resources.extend(re.findall(
                r'forResource:\s*"([A-Za-z0-9_-]+)"\s*,\s*withExtension:\s*"json"',
                source.read_text(),
            ))
        self.assertTrue(resources, "The review UI requires its bundled saved-evidence fixture")
        for name in resources:
            resource = ROOT / routes.UI_TESTS / (name + ".json")
            self.assertTrue(resource.is_file(), resource)
            json.loads(resource.read_text())

    def test_recorded_durations_keep_the_slowest_groups_on_separate_desktops(self):
        groups = {"runs": 100, "traces": 80, "settings": 40, "imports": 30}
        timings = {"seconds": {
            ({**routes.UI_BASELINE, **routes.UI_FEATURE_TESTS})[group][0]: seconds
            for group, seconds in groups.items()
        }, "fallback_seconds": {"method": 10, "suite": 50}}
        with patch.object(routes, "UI_TIMINGS", timings):
            matrix = routes.ui_matrix(groups)
            self.assertEqual({job["name"] for job in matrix}, {"runs", "traces", "imports+settings"})
            self.assertEqual(sorted(sum(routes.ui_duration(test) for test in job["tests"]) for job in matrix),
                             [70, 80, 100])
            self.assertEqual(matrix, routes.ui_matrix(reversed(groups)))

    def test_whole_suites_supersede_methods_globally_and_have_one_owner(self):
        matrix = routes.ui_matrix(routes.ALL_UI_GROUPS, {"FoundationEvalsUITests", "WorkspacePolishUITests"}, targeted=True)
        selected = [test for job in matrix for test in job["tests"]]
        self.assertEqual(len(selected), len(set(selected)))
        for suite in ("FoundationEvalsUITests", "WorkspacePolishUITests"):
            selector = routes.UI_TARGET + suite
            self.assertEqual(selected.count(selector), 1)
            self.assertFalse(any(test.startswith(selector + "/") for test in selected))


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
        for suite in ("WorkflowTraceUITests", "EvaluationReviewUITests"):
            with self.subTest(suite=suite):
                self.assertEqual(
                    self.selected_ui([routes.UI_TESTS + suite + ".swift"]),
                    {routes.UI_TARGET + suite},
                )


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

    def test_ui_jobs_are_bounded_and_deterministic(self):
        groups = sorted(routes.ALL_UI_GROUPS)
        for count in range(len(groups) + 1):
            selected = groups[:count]
            matrix = routes.ui_matrix(selected)
            self.assertEqual(matrix, routes.ui_matrix(reversed(selected)))
            self.assertLessEqual(len(matrix), 3)
            tests = [test for job in matrix for test in job["tests"]]
            expected = {test for group in selected for job in routes.ui_matrix([group]) for test in job["tests"]}
            self.assertEqual(set(tests), expected)
            self.assertEqual(len(tests), len(expected))
        self.assertEqual(routes.coverage(["README.md"])["ui_matrix"], [])


class FeatureOwnershipTests(unittest.TestCase):
    def groups(self, paths):
        return {name for group in routes.coverage(paths)["ui_matrix"] for name in group["name"].split("+")}


    def test_combined_feature_changes_union_only_relevant_groups(self):
        paths = [routes.APP + "Views/MCPSettingsView.swift", routes.APP + "Views/WorkflowTraceView.swift"]
        self.assertEqual(self.groups(paths), {"settings", "traces"})
        self.assertEqual(self.groups(paths), self.groups(list(reversed(paths))))
        shared = routes.coverage(paths + [routes.APP + "ContentView.swift"])
        self.assertEqual(shared["ui_matrix"], routes.full_coverage("fixture")["ui_matrix"])


    def test_shared_lifecycle_navigation_and_storage_keep_full_baseline(self):
        for path in (
            "ContentView.swift", "FoundationEvalsApp.swift", "Stores/EvaluationStore.swift",
            "Stores/EvaluationWorkspaceStatePersistence.swift", "Services/EvaluationWorkspacePersistence.swift",
            "Views/WorkspaceSidebar.swift", "Views/Components/WorkspaceStyle.swift",
        ):
            with self.subTest(path=path):
                self.assertEqual(routes.coverage([routes.APP + path])["ui_matrix"],
                                 routes.full_coverage("fixture")["ui_matrix"])

    def test_isolated_production_and_service_changes_have_no_ui(self):
        for path in (
            "Views/ProductionWorkspaceView.swift", "Views/ProductionReportPane.swift", "Stores/ProductionWorkspaceStore.swift",
            "Services/NativeProductionExecutor.swift",
        ):
            with self.subTest(path=path):
                plan = routes.coverage([routes.APP + path])
                self.assertTrue(plan["native"])
                self.assertFalse(plan["ui"])
                self.assertEqual(plan["ui_matrix"], [])


    def test_all_native_unit_test_only_edits_skip_ui_but_keep_portable_suites(self):
        for suite in ("EvaluationJudgeTests", "MetricScorerTests", "TimelineRenderingTests", "NavigationInteractionTests"):
            with self.subTest(suite=suite):
                plan = routes.coverage([routes.TESTS + suite + ".swift"])
                self.assertTrue(plan["native"])
                self.assertFalse(plan["ui"])
                self.assertEqual(plan["swift_suites"], [suite] if suite in routes.SWIFT_SUITES else [])


    def test_package_shared_helpers_and_top_level_tests_are_not_narrowed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = "Tests/ExampleTests/ExampleTests.swift"
            source = root / path
            source.parent.mkdir(parents=True)
            for helper in ("struct SharedFixture {}", "@Test func topLevelTest() {}", "extension SharedFixture {}"):
                with self.subTest(helper=helper):
                    source.write_text("struct ExampleTests {}\n" + helper)
                    self.assertEqual(routes.coverage([path], root=root)["swift_suites"], ["*"])


    def test_native_selection_is_attached_to_specific_and_full_plans(self):
        self.assertEqual(routes.coverage(["README.md"])["native_tests"], [])
        self.assertEqual(routes.coverage([routes.UI_TESTS + "WorkflowTraceUITests.swift"])["native_tests"], [])
        self.assertEqual(routes.coverage([routes.APP + "Models/WorkflowTracePresentation.swift"])["native_tests"],
                         ["FoundationEvalsTests/WorkflowTracePresentationTests"])
        self.assertEqual(routes.coverage(None)["native_tests"], ["FoundationEvalsTests"])
        self.assertEqual(routes.coverage(["script/ci_native_routes.py"])["native_tests"], ["FoundationEvalsTests"])

    def test_production_package_code_runs_native_consumers_without_unrelated_ui(self):
        for path in (
            "Sources/ProductionEvals/Services/ProductionJobs.swift",
            "Package.swift", "Package.resolved", "new-runtime.swift",
        ):
            with self.subTest(path=path):
                plan = routes.coverage([routes.PRODUCTION_PACKAGE + path])
                self.assertTrue(plan["native"])
                self.assertEqual(plan["native_tests"], ["FoundationEvalsTests"])
                self.assertEqual(plan["swift_suites"], sorted(routes.PRODUCTION_DEVELOPER_SUITES))
                self.assertFalse(plan["ui"])
                self.assertEqual(plan["ui_matrix"], [])
                self.assertFalse(plan["input_conversion"])

    def test_production_package_tests_and_docs_use_the_dedicated_workflow(self):
        for path in (
            "Tests/ProductionEvalsTests/ProductionWorkflowTests.swift",
            "Tests/ProductionEvalsTests/Fixtures/input.json", "README.md",
            "docs/architecture.md", "Documentation/usage.rst", "LICENSE",
        ):
            with self.subTest(path=path):
                plan = routes.coverage([routes.PRODUCTION_PACKAGE + path])
                self.assertFalse(plan["native"])
                self.assertEqual(plan["native_tests"], [])
                self.assertEqual(plan["swift_suites"], [])
                self.assertFalse(plan["ui"])
                self.assertFalse(plan["input_conversion"])

    def test_production_package_unions_features_and_keeps_shared_fallback(self):
        production = routes.PRODUCTION_PACKAGE + "Sources/ProductionEvals/Models/ProductionModels.swift"
        settings = routes.APP + "Views/MCPSettingsView.swift"
        for paths in ([production, settings], [settings, production]):
            with self.subTest(paths=paths):
                plan = routes.coverage(paths)
                self.assertEqual({group["name"] for group in plan["ui_matrix"]}, {"settings"})
                self.assertEqual(plan["native_tests"], ["FoundationEvalsTests"])
                self.assertFalse(plan["input_conversion"])
        shared = routes.coverage([production, ".github/workflows/ci.yml"])
        self.assertEqual(shared["swift_suites"], ["*"])
        self.assertLessEqual(set(routes.UI_BASELINE), {name for group in shared["ui_matrix"] for name in group["name"].split("+")})
        self.assertFalse(shared["input_conversion"])


    def test_standalone_plugin_changes_use_only_the_plugin_workflow(self):
        for path in (
            "plugins/apple-foundation-evals/server/main.mjs",
            "plugins/apple-foundation-evals/native/AppEngine/EvaluationRunner.swift",
            "plugins/apple-foundation-evals/README.md", ".github/workflows/plugin.yml",
            ".agents/plugins/marketplace.json",
        ):
            with self.subTest(path=path):
                plan = routes.coverage([path])
                for flag in ("native", "ui", "input_conversion"):
                    self.assertFalse(plan[flag], flag)
                for selection in ("native_tests", "swift_suites", "python_tests", "macos_tests", "ui_matrix"):
                    self.assertEqual(plan[selection], [], selection)

    def test_plugin_changes_do_not_add_or_remove_mixed_app_coverage(self):
        plugin = "plugins/apple-foundation-evals/native/RunnerCore.swift"
        for app in (
            routes.APP + "Views/MCPSettingsView.swift",
            routes.UI_TESTS + "EvaluationReviewUITests.swift",
            routes.PRODUCTION_PACKAGE + "Sources/ProductionEvals/Models/ProductionModels.swift",
        ):
            expected = routes.coverage([app])
            for paths in ([plugin, app], [app, plugin]):
                with self.subTest(paths=paths):
                    actual = routes.coverage(paths)
                    self.assertEqual({key: value for key, value in actual.items() if key != "reasons"},
                                     {key: value for key, value in expected.items() if key != "reasons"})

    def test_plugin_exemption_is_exact_and_keeps_shared_ci_fallback(self):
        for path in ("plugins/another-plugin/native.swift", "script/native-benchmark.sh"):
            with self.subTest(path=path):
                self.assertFalse(routes.standalone_plugin_path(path))
        plan = routes.coverage([".github/workflows/plugin.yml", ".github/workflows/ci.yml"])
        self.assertTrue(plan["native"])
        self.assertTrue(plan["ui"])
        self.assertFalse(plan["input_conversion"])
        self.assertEqual(plan["native_tests"], ["FoundationEvalsTests"])
        self.assertEqual(plan["swift_suites"], ["*"])


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
        outputs = {
            key: json.loads(value)
            for key, value in (
                line.split("=", 1) for line in output.read_text().splitlines()
            )
        }
        self.assertNotIn("automation_e2e", outputs)
        return outputs

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
        self.assertTrue(result["ui"])
        self.assertTrue(result["regression"])
        self.assertEqual(result["swift_suites"], ["MetricScorerTests"])
        self.assertEqual(result["python_tests"], [])
        self.assertEqual(result["native_tests"], ["FoundationEvalsTests"])
        self.assertEqual({group["name"] for group in result["ui_matrix"]}, {"runs"})
        self.assertEqual(result["python_tests"], [])

    def test_push_uses_previous_tip_not_parent(self):
        self.commit(routes.APP + "Views/Components/RunToolbarProgress.swift", "UI")
        head = self.commit("README.md", "docs")
        event = {"before": self.base, "after": head}
        self.assertEqual(set(routes.changed_paths("push", event, self.root)),
                         {routes.APP + "Views/Components/RunToolbarProgress.swift", "README.md"})
        result = self.run_event("push", event)
        self.assertTrue(result["native"])
        self.assertTrue(result["ui"])
        self.assertTrue(result["sdk_consumer"])
        self.assertEqual(result["swift_suites"], ["*"])
        self.assertIn("main push verifies", (self.root / "summary").read_text())

    def test_deletion_and_rename_out_of_native_tree_still_select_dependents(self):
        native = routes.APP + "Services/MetricScorer.swift"
        base = self.commit(native, "scorer")
        self.git("mv", native, "README.md", "--force")
        self.git("commit", "-qm", "move source to docs")
        result = self.run_event(
            "pull_request", {"pull_request": {"base": {"sha": base}, "head": {"sha": self.git("rev-parse", "HEAD")}}}
        )
        self.assertTrue(result["native"])
        self.assertEqual(result["swift_suites"], ["MetricScorerTests"])

    def test_docs_only_pull_request_skips_test_jobs_and_reports_why(self):
        head = self.commit("README.md", "new docs")
        result = self.run_event("pull_request", {"pull_request": {"base": {"sha": self.base}, "head": {"sha": head}}})
        self.assertFalse(result["native"])
        self.assertFalse(result["regression"])
        self.assertEqual(result["python_tests"], [])
        self.assertIn("need no unit tests", (self.root / "summary").read_text())

    def test_docs_only_main_push_still_runs_the_full_safety_net(self):
        head = self.commit("README.md", "new docs")
        result = self.run_event("push", {"before": self.base, "after": head})
        self.assertTrue(result["native"])
        self.assertTrue(result["regression"])
        self.assertTrue(result["sdk_consumer"])
        self.assertEqual(result["swift_suites"], ["*"])
        self.assertEqual(result["ui_matrix"], routes.coverage(None)["ui_matrix"])

    def test_signature_change_uses_regression_job_but_not_native_build(self):
        head = self.commit("script/verify_update_signature.swift", "verifier")
        result = self.run_event("pull_request", {"pull_request": {"base": {"sha": self.base}, "head": {"sha": head}}})
        self.assertFalse(result["native"])
        self.assertTrue(result["regression"])
        self.assertEqual(result["swift_suites"], [])
        self.assertEqual(result["macos_tests"], ["script.tests.test_update_signature"])

    def test_missing_history_malformed_and_manual_events_use_full_coverage(self):
        for name, event in [
            ("workflow_dispatch", {}),
            ("workflow_call", {}),
            ("schedule", {}),
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
                self.assertEqual(result["swift_suites"], ["*"])
                self.assertEqual(
                    result["python_tests"], sorted(routes.python_test_inventory())
                )


if __name__ == "__main__":
    unittest.main()
