"""Verify test dispatch never expands an empty or invalid selection into a full run."""

import importlib.util
from contextlib import redirect_stdout
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "ci_run_tests.py"
spec = importlib.util.spec_from_file_location("ci_run_tests", SCRIPT)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class SelectionTests(unittest.TestCase):
    def test_empty_selection_never_starts_python_or_swift(self):
        for kind in ("python", "swift"):
            with self.subTest(kind=kind), patch.object(runner.subprocess, "run") as run:
                runner.run_tests(kind, [])
                run.assert_not_called()

    def test_python_runs_only_selected_modules_once(self):
        module = "script.tests.test_release_pr"
        with patch.object(runner.subprocess, "run") as run:
            runner.run_tests("python", [module, module])
        run.assert_called_once_with(
            [sys.executable, "-m", "unittest", "-v", module], check=True
        )

    def test_swift_validates_discovery_and_filters_complete_suite_names(self):
        catalog = "FoundationEvalsPortableTests.MetricScorerTests/exactMatch()\n"
        with patch.object(
            runner.subprocess,
            "run",
            return_value=subprocess.CompletedProcess([], 0, catalog),
        ) as run:
            runner.run_tests("swift", ["MetricScorerTests"])
        self.assertEqual(run.call_count, 2)
        command = run.call_args.args[0]
        self.assertNotIn("--skip-build", command)
        self.assertNotIn("--enable-code-coverage", command)
        expression = command[command.index("--filter") + 1]
        self.assertRegex(catalog, expression)
        self.assertNotRegex(
            "FoundationEvalsPortableTests.OtherMetricScorerTests/test()", expression
        )
        self.assertNotRegex(
            "FoundationEvalsPortableTests.MetricScorerTestsExtra/test()", expression
        )

    def test_unknown_swift_suite_fails_before_running_tests(self):
        with (
            patch.object(
                runner.subprocess,
                "run",
                return_value=subprocess.CompletedProcess([], 0, ""),
            ) as run,
            self.assertRaisesRegex(ValueError, "not discovered"),
        ):
            runner.run_tests("swift", ["RemovedTests"])
        self.assertEqual(run.call_count, 1)

    def test_swift_discovery_and_execution_bound_case_concurrency_and_preserve_environment(self):
        catalog = "Module.MetricScorerTests/exactMatch()\n"
        for selection in (["MetricScorerTests"], ["*"]):
            with (
                self.subTest(selection=selection),
                patch.dict(os.environ, {
                    "CI_FIXTURE_VALUE": "preserved",
                    "SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH": "128",
                }),
                patch.object(runner.subprocess, "run",
                    return_value=subprocess.CompletedProcess([], 0, catalog)) as run,
            ):
                runner.run_tests("swift", selection)
                for call in run.call_args_list:
                    environment = call.kwargs["env"]
                    self.assertEqual(environment["CI_FIXTURE_VALUE"], "preserved")
                    self.assertEqual(environment["SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"], "4")
                self.assertEqual(os.environ["SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"], "128")

    def test_full_swift_selection_runs_all_including_new_suites(self):
        with patch.object(runner.subprocess, "run") as run:
            runner.run_tests("swift", ["*"])
        self.assertEqual(run.call_count, 1)
        command = run.call_args.args[0]
        self.assertEqual(command[:2], ["swift", "test"])
        self.assertNotIn("--filter", command)
        self.assertNotIn("--skip", command)

    def test_malformed_or_option_like_selections_never_start_processes(self):
        for kind, names in (
            ("python", None),
            ("python", {}),
            ("python", [None]),
            ("python", ["--help"]),
            ("python", ["os"]),
            ("swift", [""]),
            ("swift", ["*"] * 2 + ["MetricScorerTests"]),
            ("swift", ["--filter"]),
        ):
            with (
                self.subTest(kind=kind, names=names),
                patch.object(runner.subprocess, "run") as run,
            ):
                with self.assertRaises(ValueError):
                    runner.run_tests(kind, names)
                run.assert_not_called()

    def test_test_and_discovery_failures_propagate(self):
        for kind, names in (
            ("python", ["script.tests.test_release_pr"]),
            ("swift", ["MetricScorerTests"]),
            ("swift", ["*"]),
        ):
            with (
                self.subTest(kind=kind),
                patch.object(
                    runner.subprocess,
                    "run",
                    side_effect=subprocess.CalledProcessError(1, "fixture"),
                ),
                self.assertRaises(subprocess.CalledProcessError),
            ):
                runner.run_tests(kind, names)


    def test_real_python_dispatch_loads_just_the_requested_fixture_module(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tests = root / "script/tests"
            tests.mkdir(parents=True)
            (tests / "test_selected.py").write_text(
                "import unittest\nclass Selected(unittest.TestCase):\n    def test_passes(self): pass\n"
            )
            (tests / "test_unrelated.py").write_text(
                'raise RuntimeError("Unrelated test was imported")\n'
            )
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "python"],
                cwd=root,
                env=dict(
                    os.environ,
                    CI_TEST_SELECTION=json.dumps(["script.tests.test_selected"]),
                ),
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Ran 1 test", result.stderr)
            self.assertNotIn("Unrelated test was imported", result.stderr)


if __name__ == "__main__":
    unittest.main()
