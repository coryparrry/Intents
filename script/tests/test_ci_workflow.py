"""Execute the CI aggregate gates against failed, cancelled, and skipped shards."""

import os
import json
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

WORKFLOW = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()


def job(name):
    return re.search(r"(?ms)^  " + re.escape(name) + r":\n(.*?)(?=^  [\w-]+:|\Z)", WORKFLOW)[1]


class FailureSummaryTests(unittest.TestCase):
    def test_summary_runs_after_terminal_checks_with_read_only_log_access(self):
        summary = job("summary")
        self.assertIn("if: ${{ always() }}", summary)
        self.assertIn("needs: [changes, quality, regression, build, automation-e2e, input-conversion]", summary)
        self.assertIn("actions: read", summary)
        self.assertIn("contents: read", summary)
        self.assertNotIn("write", summary)
        self.assertIn("CI_NEEDS_JSON: ${{ toJSON(needs) }}", summary)
        self.assertIn("GITHUB_TOKEN: ${{ github.token }}", summary)
        self.assertIn("run: python3 script/ci_failure_summary.py", summary)


def gate(name, **environment):
    script = job(name).split("        run: |\n", 1)[1]
    return subprocess.run(
        ["bash", "-e", "-c", textwrap.dedent(script)],
        env={**os.environ, **environment}, capture_output=True,
    ).returncode


class GateTests(unittest.TestCase):
    def test_quality_requires_selected_script_shards(self):
        common = dict(ROUTING="success", LINT="success", SELECTED='["test"]')
        self.assertEqual(gate("quality", **common, TESTS="success"), 0)
        for result in ("skipped", "failure", "cancelled"):
            self.assertNotEqual(gate("quality", **common, TESTS=result), 0)
        self.assertEqual(gate("quality", ROUTING="success", LINT="success", SELECTED="[]", TESTS="success"), 0)
        self.assertNotEqual(gate("quality", ROUTING="success", LINT="success", SELECTED="[]", TESTS="skipped"), 0)
        self.assertNotEqual(gate("quality", ROUTING="failure", LINT="success", SELECTED="[]", TESTS="skipped"), 0)

    def test_regression_requires_selected_tests_and_external_consumer(self):
        common = dict(ROUTING="success", QUALITY="success", SWIFT="success", SDK="success", SDK_SELECTED="true", CORE_SELECTION="[]", SWIFT_SELECTION='["A"]', MACOS_SELECTION='["B"]')
        self.assertEqual(gate("regression", **common), 0)
        for field in ("SWIFT", "SDK", "QUALITY", "ROUTING"):
            for result in ("failure", "cancelled", "skipped"):
                self.assertNotEqual(gate("regression", **{**common, field: result}), 0)
        for selection in ("SWIFT_SELECTION", "MACOS_SELECTION"):
            self.assertEqual(gate("regression", **{**common, selection: "[]"}), 0)
            self.assertNotEqual(gate("regression", **{**common, selection: "[]", "SWIFT": "skipped"}), 0)
        self.assertNotEqual(gate("regression", **{**common, "SWIFT_SELECTION": "[]", "MACOS_SELECTION": "[]", "SWIFT": "skipped"}), 0)
        for result in ("failure", "cancelled", "skipped", ""):
            self.assertNotEqual(gate("regression", **{**common, "SWIFT_SELECTION": "[]", "MACOS_SELECTION": "[]", "CORE_SELECTION": '["FoundationEvalsTests"]', "SWIFT": result}), 0)
        self.assertEqual(gate("regression", **{**common, "SWIFT_SELECTION": "[]", "MACOS_SELECTION": "[]", "CORE_SELECTION": "[]", "SDK_SELECTED": "false", "SDK": "skipped", "SWIFT": "skipped"}), 0)
        self.assertEqual(gate("regression", **{**common, "SDK_SELECTED": "false", "SDK": "skipped"}), 0)
        self.assertNotEqual(gate("regression", **{**common, "SDK_SELECTED": "false"}), 0)
        self.assertNotEqual(gate("regression", **{**common, "SDK_SELECTED": ""}), 0)

    def test_required_gate_rejects_failed_cancelled_or_skipped_selected_checks(self):
        common = dict(ROUTING="success", QUALITY="success", REGRESSION="success", AUTOMATION="success", BUILD="success", BUILD_SELECTED="true", SDK="success", SDK_SELECTED="true", CORE="success", CORE_SELECTION='["FoundationEvalsTests"]', UI="success", UI_SELECTED="true", STABILITY="skipped", STABILITY_SELECTED="false", INPUT_CONVERSION="success", INPUT_CONVERSION_SELECTED="true")
        self.assertEqual(gate("build", **common), 0)
        # Pull requests have no inputs context. Comparing the optional input to
        # true yields a boolean false instead of short-circuiting to an empty string.
        stability = "${{ inputs.stability == true && needs.changes.outputs.ui == 'true' }}"
        self.assertIn("STABILITY_SELECTED: " + stability, job("build"))
        self.assertIn("if: " + stability, job("picker-stability"))
        self.assertNotEqual(gate("build", **{**common, "STABILITY_SELECTED": ""}), 0)
        self.assertEqual(gate("build", **{**common, "STABILITY_SELECTED": "true", "STABILITY": "success"}), 0)
        for result in ("failure", "cancelled", "skipped", ""):
            self.assertNotEqual(gate("build", **{**common, "STABILITY_SELECTED": "true", "STABILITY": result}), 0)
        for field in ("ROUTING", "QUALITY", "REGRESSION", "AUTOMATION", "BUILD", "SDK", "CORE", "UI", "INPUT_CONVERSION"):
            for result in ("failure", "cancelled", "skipped", ""):
                with self.subTest(field=field, result=result):
                    self.assertNotEqual(gate("build", **{**common, field: result}), 0)
        for field in ("BUILD", "SDK", "UI", "INPUT_CONVERSION"):
            self.assertEqual(gate("build", **{**common, field + "_SELECTED": "false", field: "skipped"}), 0)
            self.assertNotEqual(gate("build", **{**common, field + "_SELECTED": "false"}), 0)
            self.assertNotEqual(gate("build", **{**common, field + "_SELECTED": ""}), 0)
        self.assertEqual(gate("build", **{**common, "CORE_SELECTION": "[]", "CORE": "skipped"}), 0)
        self.assertNotEqual(gate("build", **{**common, "STABILITY_SELECTED": "true"}), 0)
        self.assertEqual(gate("build", **{**common, "STABILITY_SELECTED": "true", "STABILITY": "success"}), 0)
        # Docs-only changes still produce a required result; expected skips pass.
        unselected = {**common, "CORE_SELECTION": "[]", "CORE": "skipped"}
        for field in ("BUILD", "SDK", "UI", "INPUT_CONVERSION"):
            unselected.update({field: "skipped", field + "_SELECTED": "false"})
        self.assertEqual(gate("build", **unselected), 0)
        self.assertNotEqual(gate("build", **{**unselected, "ROUTING": "failure"}), 0)

    def test_required_gate_waits_for_acceptance_even_without_native_build(self):
        workflow = job("build")
        self.assertIn("if: ${{ always() }}", workflow)
        dependencies = re.search(r"needs: \[([^]]+)\]", workflow)[1].split(", ")
        for required in ("quality", "regression", "automation-e2e", "input-conversion", "native-build", "native-tests", "ui-tests", "sdk-consumer", "picker-stability"):
            self.assertIn(required, dependencies)

    def test_expensive_jobs_wait_for_fast_checks_and_share_macos_scripts(self):
        for name in ("native-build", "automation-e2e-scenarios", "input-conversion"):
            header = job(name).split("    steps:", 1)[0]
            self.assertIn("needs: [changes, quality]", header)
            self.assertNotIn("always()", header)
        self.assertNotIn("\n  macos-script-tests:", WORKFLOW)
        self.assertIn("CI_TEST_SELECTION: ${{ needs.changes.outputs.macos_tests }}", job("swift-tests"))
        self.assertIn("needs.changes.outputs.swift_suites != '[]' || needs.changes.outputs.macos_tests != '[]'", job("swift-tests"))
        self.assertIn("needs.changes.outputs.sdk_consumer == 'true'", job("swift-tests"))

    def test_external_consumer_requires_exact_remote_revision_and_both_products(self):
        script = job("swift-tests").split("      - name: Verify external consumer build receipt\n", 1)[1].split("        run: |\n", 1)[1].split("      - name:", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipt.json"
            environment = {
                **os.environ,
                "INTENT_LAB_CONSUMER_BUILD_RECEIPT": str(path),
                "INTENT_LAB_CONSUMER_PACKAGE_URL": "https://github.com/coryparrry/Intents.git",
                "INTENT_LAB_CONSUMER_REVISION": "a" * 40,
            }
            receipt = {
                "schemaVersion": 1,
                "packageURL": environment["INTENT_LAB_CONSUMER_PACKAGE_URL"],
                "revision": environment["INTENT_LAB_CONSUMER_REVISION"],
                "check": "generatedMacUITestTargetBuildsWithXcode",
                "signing": "disabled",
                "runtime": "not-executed",
                "products": ["IntentLabTesting", "FoundationEvalsDeveloper"],
            }
            def status():
                return subprocess.run(["bash", "-e", "-c", textwrap.dedent(script)], env=environment, capture_output=True).returncode
            self.assertNotEqual(status(), 0, "A skipped test must not satisfy the consumer gate")
            path.write_text(json.dumps(receipt))
            self.assertEqual(status(), 0)
            for field, invalid in (
                ("revision", "b" * 40), ("packageURL", "/tmp/local-package"),
                ("products", ["IntentLabTesting"]), ("runtime", "executed"),
            ):
                with self.subTest(field=field):
                    path.write_text(json.dumps({**receipt, field: invalid}))
                    self.assertNotEqual(status(), 0)

    def test_external_consumer_reads_the_actual_installer_pin(self):
        script = job("swift-tests").split("      - name: Read immutable installer package revision\n", 1)[1].split("        run: |\n", 1)[1].split("      - name:", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            environment_file = Path(directory) / "environment"
            subprocess.run(["bash", "-e", "-c", textwrap.dedent(script)],
                           cwd=Path(__file__).resolve().parents[2], check=True,
                           env={**os.environ, "GITHUB_ENV": str(environment_file), "RUNNER_TEMP": directory})
            values = dict(line.split("=", 1) for line in environment_file.read_text().splitlines())
            self.assertRegex(values["INTENT_LAB_CONSUMER_REVISION"], r"^[0-9a-f]{40}$")
            self.assertEqual(values["INTENT_LAB_CONSUMER_BUILD_RECEIPT"], str(Path(directory) / "intentlab-consumer/receipt.json"))

    def test_regression_worker_survives_skipped_native_build_without_running_unselected_core(self):
        worker = job("swift-tests")
        header = worker.split("    steps:", 1)[0]
        self.assertIn("needs: [changes, quality, native-build]", header)
        self.assertIn("always() && !cancelled()", header)
        self.assertIn("needs.changes.result == 'success' && needs.quality.result == 'success'", header)
        self.assertIn("needs.changes.outputs.native_tests == '[]' || needs.native-build.result == 'success'", header)
        self.assertIn("timeout-minutes: 35", header)
        for name in ("native-tests", "sdk-consumer"):
            aggregate = job(name)
            self.assertIn("runs-on: ubuntu-24.04", aggregate)
            self.assertIn("needs: [changes, swift-tests]", aggregate)
            self.assertIn("always()", aggregate)
            self.assertEqual(gate(name, ROUTING="success", WORKER="success"), 0)
            for status in ("failure", "cancelled", "skipped", ""):
                self.assertNotEqual(gate(name, ROUTING="success", WORKER=status), 0)
                self.assertNotEqual(gate(name, ROUTING=status, WORKER="success"), 0)

    def test_shared_swift_build_qualifies_fresh_consumers_once_with_scoped_opt_in(self):
        worker = job("swift-tests")
        step = worker.split("      - name: Run selected Swift suites and fresh SDK consumers once\n", 1)[1].split("      - name:", 1)[0]
        self.assertEqual(worker.count("python3 script/ci_run_tests.py swift"), 1)
        self.assertIn("--scratch-path \"$RUNNER_TEMP/portable-build\"", step)
        self.assertIn('if [[ "$SDK_SELECTED" == true ]]; then args+=(--include-installer); fi', step)
        self.assertIn("INTENT_LAB_RUN_MAC_INSTALLER_BUILD_TEST: ${{ needs.changes.outputs.sdk_consumer == 'true' && '1' || '0' }}", step)
        self.assertEqual(worker.count("INTENT_LAB_RUN_MAC_INSTALLER_BUILD_TEST"), 1)
        self.assertNotIn("INTENT_LAB_RUN_MAC_INSTALLER_BUILD_TEST", worker.split("    steps:", 1)[0])
        self.assertNotIn("intentlab-consumer-build", worker)
        self.assertNotIn("path: ${{ runner.temp }}/intentlab-consumer", worker.split("      - name: Run selected Swift suites", 1)[0])
        self.assertIn("needs.changes.outputs.native_tests != '[]'", worker.split("      - name: Run core tests without rebuilding", 1)[1].split("      - name:", 1)[0])
        self.assertIn('python3 script/ci_native_tests.py --products "$RUNNER_TEMP/Products"', worker)

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
            "Install consumer project generator", "Read immutable installer package revision",
            "Run selected macOS script tests", "Identify Swift toolchain",
            "Restore reusable Swift build", "Run selected Swift suites and fresh SDK consumers once",
            "Verify external consumer build receipt",
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
                                or "needs.changes.outputs.macos_tests" in condition)

    def test_continuation_respects_setup_and_keeps_receipt_evidence_after_test_failure(self):
        worker = job("swift-tests")
        conditions = {
            name: re.search(re.escape(name) + r"\n        if: (.+)", worker)[1]
            for name in ("Restore reusable Swift build", "Run selected Swift suites and fresh SDK consumers once",
                         "Verify external consumer build receipt")
        }
        self.assertIn("steps.toolchain.outcome == 'success'", conditions["Restore reusable Swift build"])
        run = conditions["Run selected Swift suites and fresh SDK consumers once"]
        for prerequisite in ("toolchain", "swift-cache", "consumer-generator", "consumer-pin"):
            self.assertIn("steps." + prerequisite + ".outcome == 'success'", run)
        self.assertIn("needs.changes.outputs.sdk_consumer != 'true' ||", run)
        receipt = conditions["Verify external consumer build receipt"]
        self.assertIn("steps.consumer-pin.outcome == 'success'", receipt)
        self.assertIn("steps.swift-regressions.outcome != 'skipped'", receipt)
        self.assertNotIn("steps.swift-regressions.outcome == 'success'", receipt)

    def test_ui_consumers_only_depend_on_the_shared_build(self):
        for name in ("ui-tests", "picker-stability"):
            self.assertIn("needs: [changes, native-build]", job(name))
            self.assertIn("name: native-test-products", job(name))
            self.assertIn("tar -xf", job(name))
            self.assertNotIn("xcodebuild build", job(name))
        self.assertIn("fail-fast: false", job("ui-tests"))
        self.assertNotIn("max-parallel:", job("ui-tests"))
        self.assertNotIn("--iterations", job("ui-tests"))

    def test_simulator_cache_is_saved_only_after_successful_compilation(self):
        workflow = job("automation-e2e-scenarios")
        self.assertIn("uses: actions/cache/restore@", workflow)
        self.assertIn("--record-build-cache", workflow)
        self.assertIn("steps.contract.outputs.cli_built == 'true'", workflow)
        self.assertIn("steps.cli-cache.outputs.cache-hit != 'true'", workflow)
        self.assertIn("uses: actions/cache/save@", workflow)
        self.assertIn("key: ${{ steps.cli-cache.outputs.cache-primary-key }}", workflow)

    def test_simulator_runs_every_scenario_with_one_setup_and_cache_writer(self):
        workflow = job("automation-e2e-scenarios")
        self.assertIn("needs: [changes, quality]", workflow)
        self.assertNotIn("matrix", workflow)
        self.assertIn("--scenario-group all", workflow)
        self.assertIn("name: automation-e2e", workflow)
        condition = re.search(r"Save successfully compiled automation CLI\n        if: (.+)", workflow)[1]
        self.assertIn("!cancelled()", condition)
        self.assertIn("steps.contract.outputs.cli_built == 'true'", condition)
        self.assertNotIn("success()", condition)

    def test_simulator_and_mac_acceptance_do_not_suppress_each_other(self):
        workflow = job("automation-e2e-scenarios")
        simulator = workflow.index("      - name: Reproduce prepared-app automation\n")
        mac = workflow.index("      - name: Reproduce Mac automation and saved fix comparison\n")
        self.assertLess(simulator, mac)
        mac_step = workflow[mac:].split("\n      - name:", 1)[0]
        self.assertIn("if: ${{ !cancelled() }}", mac_step)
        self.assertIn("--scenario-group all", workflow[:mac])

    def test_mac_acceptance_uses_temporary_development_signing(self):
        workflow = job("automation-e2e-scenarios")
        mac = workflow.split("      - name: Reproduce Mac automation and saved fix comparison\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("CI_MAC_CERTIFICATE_P12_BASE64: ${{ secrets.CI_MAC_CERTIFICATE_P12_BASE64 }}", mac)
        self.assertIn("CI_MAC_CERTIFICATE_PASSWORD: ${{ secrets.CI_MAC_CERTIFICATE_PASSWORD }}", mac)
        self.assertIn("CI_MAC_SIGNING_TEAM: ${{ vars.CI_MAC_SIGNING_TEAM }}", mac)
        self.assertIn("python3 script/ci_macos_signing.py -- /bin/bash -e <<'SIGNED_MAC_CHECK'", mac)
        self.assertIn('--signing-team "$INTENTS_CI_SIGNING_TEAM" --signing-identity "$INTENTS_CI_SIGNING_IDENTITY"', mac)
        self.assertNotIn("continue-on-error", mac)
        self.assertEqual(WORKFLOW.count("secrets.CI_MAC_CERTIFICATE_P12_BASE64"), 1)
        self.assertEqual(WORKFLOW.count("secrets.CI_MAC_CERTIFICATE_PASSWORD"), 1)

    def test_scripts_run_all_selected_modules_in_one_job(self):
        workflow = job("script-tests")
        self.assertNotIn("matrix", workflow)
        self.assertNotIn("    if:", workflow.split("    steps:", 1)[0])
        self.assertIn("CI_TEST_SELECTION: ${{ needs.changes.outputs.python_tests }}", workflow)
        self.assertIn("python3 script/ci_run_tests.py python", workflow)

    def test_evidence_is_retained_after_failure_without_blocking_cancellation(self):
        # A status function overrides implicit success(), preserving failed-run evidence.
        # Unlike always(), !cancelled() lets superseding PR runs release their runners.
        for name in ("Upload core results", "Export UI test attachments", "Upload UI results",
                     "Upload stability results", "Upload automation evidence",
                     "Upload input conversion diagnostic evidence", "Upload external consumer build evidence"):
            with self.subTest(step=name):
                condition = re.search(re.escape(name) + r"\n        if: (.+)", WORKFLOW)[1]
                self.assertIn("!cancelled()", condition)
                self.assertNotIn("always()", condition)
        # Required gates still reject cancellation rather than treating it as success.
        for name in ("quality", "regression", "build", "automation-e2e"):
            self.assertIn("always()", job(name).split("    steps:", 1)[0])

    def test_stable_simulator_gate_requires_all_selected_groups(self):
        self.assertEqual(gate("automation-e2e", ROUTING="success", SELECTED="true", SCENARIOS="success"), 0)
        for result in ("failure", "cancelled", "skipped", ""):
            with self.subTest(result=result):
                self.assertNotEqual(gate("automation-e2e", ROUTING="success", SELECTED="true", SCENARIOS=result), 0)
        self.assertNotEqual(gate("automation-e2e", ROUTING="failure", SELECTED="true", SCENARIOS="success"), 0)
        self.assertEqual(gate("automation-e2e", ROUTING="success", SELECTED="false", SCENARIOS="skipped"), 0)
        self.assertNotEqual(gate("automation-e2e", ROUTING="success", SELECTED="false", SCENARIOS="failure"), 0)
        self.assertNotEqual(gate("automation-e2e", ROUTING="success", SELECTED="false", SCENARIOS="success"), 0)
        self.assertNotEqual(gate("automation-e2e", ROUTING="success", SELECTED="", SCENARIOS="skipped"), 0)

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
