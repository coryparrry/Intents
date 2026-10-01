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
                "demo-video/src/index.tsx",
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
                self.assertEqual(result["swift_suites"], ["*"])
                self.assertEqual(
                    result["python_tests"], sorted(routes.python_test_inventory())
                )


if __name__ == "__main__":
    unittest.main()
