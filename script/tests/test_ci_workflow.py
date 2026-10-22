"""Verify consolidated workflow wiring and execute its evidence checks."""

import os
import json
import plistlib
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

WORKFLOW = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()


def job(name):
    return re.search(r"(?ms)^  " + re.escape(name) + r":\n(.*?)(?=^  [\w-]+:|\Z)", WORKFLOW)[1]


class WorkflowContractTests(unittest.TestCase):
    def test_required_checks_are_real_workers_and_one_terminal_gate(self):
        jobs = re.findall(r"(?m)^  ([\w-]+):$", WORKFLOW.split("jobs:\n", 1)[1])
        self.assertEqual(set(jobs), {
            "changes", "swift-tests", "native-build", "ui-tests", "picker-stability",
            "build",
        })
        self.assertEqual(len(jobs), 6)
        for identifier, name in (("changes", "Workflow and script checks"),
                                 ("swift-tests", "Portable regression tests"),
                                 ("build", "Compile app and tests")):
            self.assertIn("    name: " + name + "\n", job(identifier))
        # The matrix is produced by the route referenced by the workflow, rather
        # than duplicating its shard names in this job-count assertion.
        from script import ci_routes
        plan = ci_routes.coverage(None)
        for selection in ("native", "ui", "sdk_consumer"):
            self.assertTrue(plan[selection], selection)
        self.assertIn("matrix:\n        include: ${{ fromJSON(needs.changes.outputs.ui_matrix) }}", job("ui-tests"))
        self.assertEqual(len(plan["ui_matrix"]), 3)
        expanded = len(jobs) - 1 + len(plan["ui_matrix"])
        self.assertEqual(expanded, 8)
        opt_in = [name for name in jobs if "inputs.stability == true" in job(name).split("    steps:", 1)[0]]
        self.assertEqual(opt_in, ["picker-stability"])
        self.assertEqual(expanded - len(opt_in), 7)

    def test_terminal_gate_receives_complete_workflow_state(self):
        workflow = job("build")
        header = workflow.split("    steps:", 1)[0]
        self.assertIn("if: ${{ always() }}", header)
        dependencies = re.search(r"needs: \[([^]]+)\]", header)[1].split(", ")
        self.assertEqual(set(dependencies), {
            "changes", "swift-tests", "native-build", "ui-tests", "picker-stability",
        })
        self.assertIn("contents: read", header)
        self.assertIn("actions: read", header)
        self.assertNotIn("write", header)
        self.assertIn("uses: actions/checkout@", workflow)
        gate_step = workflow.split("        id: gate\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("CI_NEEDS_JSON: ${{ toJSON(needs) }}", gate_step)
        self.assertIn("CI_SELECTION_JSON: ${{ toJSON(needs.changes.outputs) }}", gate_step)
        self.assertIn("CI_STABILITY_REQUESTED: ${{ inputs.stability == true }}", gate_step)
        self.assertIn("run: python3 script/ci_gate.py", gate_step)

    def test_summary_runs_after_the_gate_with_read_only_log_access(self):
        workflow = job("build")
        gate_position = workflow.index("run: python3 script/ci_gate.py")
        summary_position = workflow.index("run: python3 script/ci_failure_summary.py")
        self.assertLess(gate_position, summary_position)
        summary = workflow[gate_position:summary_position].split("      - name:", 1)[1]
        self.assertIn("if: ${{ always() && steps.source.outcome == 'success' }}", summary)
        self.assertIn("CI_GATE_RESULT: ${{ steps.gate.outcome }}", summary)
        self.assertIn("CI_NEEDS_JSON: ${{ toJSON(needs) }}", summary)
        self.assertIn("GITHUB_TOKEN: ${{ github.token }}", summary)

    def test_fast_checks_and_route_share_one_linux_checkout(self):
        workflow = job("changes")
        self.assertIn("runs-on: ubuntu-24.04", workflow)
        self.assertEqual(workflow.count("uses: actions/checkout@"), 1)
        self.assertIn("id: route", workflow)
        self.assertIn("run: python3 script/ci_routes.py", workflow)
        for check in ("script/release_notes.py validate-event", "actionlint@", "shellcheck script/*.sh",
                      "python3 -m compileall -q examples", "node --test tests/*.test.mjs"):
            self.assertIn(check, workflow)
        self.assertIn("CI_TEST_SELECTION: ${{ steps.route.outputs.python_tests }}", workflow)
        self.assertIn("python3 script/ci_run_tests.py python", workflow)
        for output in ("native", "ui", "input_conversion", "sdk_consumer",
                       "native_tests", "regression", "swift_suites", "python_tests", "macos_tests", "ui_matrix"):
            self.assertIn(output + ": ${{ steps.route.outputs." + output + " }}", workflow)

    def test_expensive_independent_jobs_wait_for_fast_checks(self):
        for name in ("native-build",):
            header = job(name).split("    steps:", 1)[0]
            self.assertIn("needs: changes", header)
            self.assertNotIn("always()", header)
        self.assertNotIn("\n  macos-script-tests:", WORKFLOW)
        self.assertIn("CI_TEST_SELECTION: ${{ needs.changes.outputs.macos_tests }}", job("swift-tests"))

    def test_reusable_callers_need_no_signing_secrets_and_allow_failure_log_reads(self):
        workflow_call = WORKFLOW.split("  workflow_call:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertNotIn("secrets:", workflow_call)
        workflows = Path(__file__).resolve().parents[2] / ".github/workflows"
        for filename, identifier in (("ui-stability.yml", "qualification"), ("pr-metadata.yml", "retarget")):
            source = (workflows / filename).read_text()
            caller = re.search(r"(?ms)^  " + identifier + r":\n(.*?)(?=^  [\w-]+:|\Z)", source)[1]
            with self.subTest(workflow=filename):
                self.assertIn("uses: ./.github/workflows/ci.yml", caller)
                # Job permissions override the workflow's inherited permission map.
                permissions = caller if "    permissions:\n" in caller else source.split("jobs:\n", 1)[0]
                self.assertIn("actions: read", permissions)
                self.assertIn("contents: read", permissions)
                self.assertNotIn("secrets:", caller)


    def test_regression_worker_survives_skipped_native_build_and_avoids_empty_mac_allocation(self):
        worker = job("swift-tests")
        header = worker.split("    steps:", 1)[0]
        self.assertIn("needs: [changes, native-build]", header)
        self.assertIn("always() && !cancelled()", header)
        self.assertIn("needs.changes.result == 'success'", header)
        self.assertIn("needs.changes.outputs.native_tests == '[]' || needs.native-build.result == 'success'", header)
        self.assertIn("runs-on: ${{ needs.changes.outputs.regression == 'true' && 'xcode-27' || 'ubuntu-24.04' }}", header)
        self.assertNotIn("&& needs.changes.outputs.regression", header.split("    runs-on:", 1)[0])
        self.assertIn("needs.changes.outputs.native_tests != '[]'", worker.split("      - name: Run core tests without rebuilding", 1)[1].split("      - name:", 1)[0])


    def test_case_concurrency_uses_the_built_scheme_without_runtime_override(self):
        worker = job("swift-tests")
        step = worker.split("      - name: Run core tests without rebuilding\n", 1)[1].split("      - name:", 1)[0]
        variable = "TEST_RUNNER_SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"
        self.assertNotIn(variable, WORKFLOW)
        self.assertIn("CI_TEST_SELECTION: ${{ needs.changes.outputs.native_tests }}", step)

    def test_independent_regression_groups_continue_after_failures_but_not_cancellation(self):
        worker = job("swift-tests")
        self.assertNotIn("continue-on-error:", worker)
        for name in (
            "Run selected macOS script tests", "Identify Swift toolchain",
            "Restore reusable Swift build", "Run selected Swift suites",
        ):
            with self.subTest(step=name):
                condition = re.search(re.escape(name) + r"\n        if: (.+)", worker)[1]
                # An explicit status function overrides GitHub's implicit
                # success() after an unrelated earlier group has failed.
                self.assertIn("${{ !cancelled() &&", condition)
                self.assertIn("steps.source.outcome == 'success'", condition)
                self.assertNotIn("success()", condition)
                self.assertNotIn("always()", condition)
                self.assertTrue("needs.changes.outputs.swift_suites" in condition
                                or "needs.changes.outputs.sdk_consumer" in condition
                                or "needs.changes.outputs.macos_tests" in condition
                                or "needs.changes.outputs.input_conversion" in condition)


    def test_swift_cache_identity_tracks_toolchain_and_package_inputs(self):
        worker = job("swift-tests")
        toolchain = worker.split("      - name: Identify Swift toolchain\n", 1)[1].split("      - name:", 1)[0]
        cache = worker.split("      - name: Restore reusable Swift build\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("xcrun swift --version | shasum -a 256", toolchain)
        self.assertIn("path: ${{ runner.temp }}/portable-build", cache)
        self.assertIn("-swift-tests-", cache)
        for line in cache.splitlines():
            if "-swift-tests-" in line:
                self.assertIn("${{ runner.os }}-${{ runner.arch }}", line)
                self.assertIn("${{ steps.toolchain.outputs.version }}", line)
                self.assertIn("hashFiles('Package.swift', 'Package.resolved', '**/Package.resolved')", line)
        self.assertIn("${{ github.sha }}", cache)


    def test_ui_consumers_only_depend_on_the_shared_build(self):
        for name in ("ui-tests", "picker-stability"):
            self.assertIn("needs: [changes, native-build]", job(name))
            self.assertIn("name: native-test-products", job(name))
            self.assertIn("tar -xf", job(name))
            self.assertNotIn("xcodebuild build", job(name))
        self.assertIn("fail-fast: false", job("ui-tests"))
        self.assertNotIn("max-parallel:", job("ui-tests"))
        self.assertNotIn("--iterations", job("ui-tests"))
        self.assertIn("if: ${{ inputs.stability == true && needs.changes.outputs.ui == 'true' }}", job("picker-stability"))


    def test_scripts_run_all_selected_modules_in_one_job(self):
        workflow = job("changes")
        self.assertNotIn("\n      matrix:", workflow.split("    steps:", 1)[0])
        self.assertNotIn("    if:", workflow.split("    steps:", 1)[0])
        self.assertIn("CI_TEST_SELECTION: ${{ steps.route.outputs.python_tests }}", workflow)
        self.assertIn("python3 script/ci_run_tests.py python", workflow)

    def test_evidence_is_retained_after_failure_without_blocking_cancellation(self):
        # A status function overrides implicit success(), preserving failed-run evidence.
        # Unlike always(), !cancelled() lets superseding PR runs release their runners.
        for name in ("Upload core results", "Export UI test attachments", "Upload UI results",
                     "Upload stability results"):
            with self.subTest(step=name):
                condition = re.search(re.escape(name) + r"\n        if: (.+)", WORKFLOW)[1]
                self.assertIn("!cancelled()", condition)
                self.assertNotIn("always()", condition)
        # The terminal gate evaluates cancellation even when its ancestors skip.
        self.assertIn("always()", job("build").split("    steps:", 1)[0])

    def test_ui_runner_identity_uses_the_sdk_bundle_expression(self):
        path = Path(__file__).resolve().parents[2] / "FoundationEvals/FoundationEvalsUITests/FoundationEvalsUITests.entitlements"
        entitlements = plistlib.loads(path.read_bytes())
        self.assertEqual(entitlements["com.apple.application-identifier"],
                         "$(AppIdentifierPrefix)$(CFBundleIdentifier)")
        self.assertIs(entitlements["com.apple.security.app-sandbox"], True)
        self.assertEqual(entitlements["com.apple.security.temporary-exception.files.absolute-path.read-write"],
                         ["/private/tmp/foundation-evals-ui-tests/"])

    def test_native_build_signs_local_test_products_without_development_secrets(self):
        build = job("native-build")
        command = build.split("          xcodebuild build-for-testing", 1)[1].split("          descriptors=", 1)[0]
        self.assertIn("CODE_SIGNING_ALLOWED=YES", command)
        self.assertIn("CODE_SIGN_IDENTITY=-", command)
        self.assertIn("CODE_SIGN_STYLE=Manual", command)
        self.assertNotIn("CODE_SIGNING_ALLOWED=NO", command)
        self.assertNotIn("secrets.", command)
        # Never restore unsigned runner artifacts from the previous cache contract.
        self.assertNotIn("native-v1-", build)
        self.assertEqual(build.count("native-v2-"), 3)

    def test_native_descriptors_refresh_without_removing_compiled_products(self):
        build = job("native-build")
        cleanup = re.search(r"(?m)^          rm -f .+$", build)[0].strip()
        self.assertLess(build.index(cleanup), build.index("xcodebuild build-for-testing"))
        guard = re.search(r"(?m)^          descriptors=.+\n          \[\[ .+$", build)[0]
        self.assertGreater(build.index(guard), build.index("xcodebuild build-for-testing"))
        with tempfile.TemporaryDirectory(prefix="native cache ") as directory:
            products = Path(directory) / "DerivedData/Build/Products"
            products.mkdir(parents=True)
            binary = products / "Debug/Intents.app/Contents/MacOS/Intents"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"compiled app")
            foreign = products / "Other_macosx.xctestrun"
            foreign.touch()
            for name in ("FoundationEvals", "FoundationEvalsCoreCI"):
                (products / f"{name}_macosx27.0-arm64.xctestrun").touch()
            environment = {**os.environ, "RUNNER_TEMP": directory, "scheme": "FoundationEvalsCoreCI"}
            subprocess.run(["bash", "-e", "-c", cleanup], env=environment, check=True)
            self.assertEqual(binary.read_bytes(), b"compiled app")
            self.assertTrue(foreign.exists())
            descriptor = products / "FoundationEvalsCoreCI_macosx27.0-arm64.xctestrun"
            def status():
                return subprocess.run(["bash", "-c", textwrap.dedent(guard)], env=environment).returncode
            self.assertNotEqual(status(), 0)
            descriptor.touch()
            self.assertEqual(status(), 0)
            environment["scheme"] = "FoundationEvals"
            self.assertNotEqual(status(), 0)
            (products / "FoundationEvals_macosx27.0-arm64.xctestrun").touch()
            self.assertNotEqual(status(), 0)


if __name__ == "__main__":
    unittest.main()
