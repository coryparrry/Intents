"""Execute the CI aggregate gates against failed, cancelled, and skipped shards."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

WORKFLOW = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()


def job(name):
    return re.search(r"(?ms)^  " + re.escape(name) + r":\n(.*?)(?=^  [\w-]+:|\Z)", WORKFLOW)[1]


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
        self.assertEqual(gate("quality", ROUTING="success", LINT="success", SELECTED="[]", TESTS="skipped"), 0)
        self.assertNotEqual(gate("quality", ROUTING="failure", LINT="success", SELECTED="[]", TESTS="skipped"), 0)

    def test_regression_requires_both_independent_platform_results(self):
        common = dict(ROUTING="success", SWIFT="success", MACOS="success", SWIFT_SELECTION='["A"]', MACOS_SELECTION='["B"]')
        self.assertEqual(gate("regression", **common), 0)
        for field in ("SWIFT", "MACOS", "ROUTING"):
            for result in ("failure", "cancelled", "skipped"):
                self.assertNotEqual(gate("regression", **{**common, field: result}), 0)
        self.assertEqual(gate("regression", **{**common, "MACOS_SELECTION": "[]", "MACOS": "skipped"}), 0)

    def test_native_gate_rejects_any_missing_build_core_or_ui_shard(self):
        common = dict(ROUTING="success", BUILD="success", CORE="success", CORE_SELECTION='["FoundationEvalsTests"]', UI="success", UI_SELECTED="true", STABILITY="skipped", STABILITY_SELECTED="false")
        self.assertEqual(gate("build", **common), 0)
        for field in ("ROUTING", "BUILD", "CORE", "UI"):
            for result in ("failure", "cancelled", "skipped"):
                self.assertNotEqual(gate("build", **{**common, field: result}), 0)
        self.assertEqual(gate("build", **{**common, "UI_SELECTED": "false", "UI": "skipped"}), 0)
        self.assertEqual(gate("build", **{**common, "CORE_SELECTION": "[]", "CORE": "skipped"}), 0)
        self.assertNotEqual(gate("build", **{**common, "STABILITY_SELECTED": "true"}), 0)
        self.assertEqual(gate("build", **{**common, "STABILITY_SELECTED": "true", "STABILITY": "success"}), 0)

    def test_parallel_consumers_only_depend_on_the_shared_build(self):
        for name in ("native-tests", "ui-tests", "picker-stability"):
            self.assertIn("needs: [changes, native-build]", job(name))
            self.assertIn("name: native-test-products", job(name))
            self.assertIn("tar -xf", job(name))
            self.assertNotIn("xcodebuild build", job(name))
        self.assertIn("fail-fast: false", job("ui-tests"))
        self.assertNotIn("max-parallel:", job("ui-tests"))
        self.assertNotIn("--iterations", job("ui-tests"))

    def test_ui_execution_deadline_leaves_time_for_failure_artifacts(self):
        workflow = job("ui-tests")
        invocation = re.search(r"(?m)^        run: python3 script/ci_native_tests\.py .+$", workflow)[0]
        seconds = int(re.search(r"--timeout-seconds (\d+)", invocation)[1])
        minutes = int(re.search(r"(?m)^    timeout-minutes: (\d+)", workflow)[1])
        self.assertEqual(seconds, 900)
        self.assertLess(seconds + 180, minutes * 60, "Desktop preparation and evidence need job time")

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
        self.assertIn("needs: changes", workflow)
        self.assertNotIn("matrix", workflow)
        self.assertIn("--scenario-group all", workflow)
        self.assertIn("name: automation-e2e", workflow)
        condition = re.search(r"Save successfully compiled automation CLI\n        if: (.+)", workflow)[1]
        self.assertIn("!cancelled()", condition)
        self.assertIn("steps.contract.outputs.cli_built == 'true'", condition)
        self.assertNotIn("success()", condition)

    def test_signing_configuration_is_scoped_to_the_two_live_mac_commands(self):
        ui = job("ui-tests")
        mac = ui.split("      - name: Prepare and test selected live Mac UI fixture\n", 1)[1].split("      - name:", 1)[0]
        ordinary = ui.split("      - name: Run affected UI tests once\n", 1)[1].split("      - name:", 1)[0]
        cli = job("automation-e2e-scenarios").split("      - name: Reproduce Mac automation and saved fix comparison\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("if: ${{ matrix.mac_fixture == true }}", mac)
        self.assertIn("if: ${{ !matrix.mac_fixture }}", ordinary)
        self.assertNotIn("CI_MAC_CERTIFICATE", ordinary)
        self.assertNotIn("ci_macos_signing.py", ordinary)
        for step in (mac, cli):
            self.assertIn("CI_MAC_CERTIFICATE_P12_BASE64: ${{ secrets.CI_MAC_CERTIFICATE_P12_BASE64 }}", step)
            self.assertIn("CI_MAC_CERTIFICATE_PASSWORD: ${{ secrets.CI_MAC_CERTIFICATE_PASSWORD }}", step)
            self.assertIn("CI_MAC_SIGNING_TEAM: ${{ vars.CI_MAC_SIGNING_TEAM }}", step)
            self.assertIn("python3 script/ci_macos_signing.py -- /bin/bash -e -c", step)
            self.assertIn('--signing-team "$INTENTS_CI_SIGNING_TEAM" --signing-identity "$INTENTS_CI_SIGNING_IDENTITY"', step)
            self.assertNotIn("continue-on-error", step)
            self.assertNotIn("environment:", step)
        self.assertEqual(WORKFLOW.count("secrets.CI_MAC_CERTIFICATE_P12_BASE64"), 2)
        self.assertEqual(WORKFLOW.count("secrets.CI_MAC_CERTIFICATE_PASSWORD"), 2)
        self.assertLess(mac.index("ci_automation_ui_fixture.py"), mac.index("ci_native_tests.py"))
        self.assertIn("CI_TEST_SELECTION: ${{ toJSON(matrix.tests) }}", mac)
        self.assertIn("--timeout-seconds 900", mac)

    def test_scripts_run_all_selected_modules_in_one_job(self):
        workflow = job("script-tests")
        self.assertNotIn("matrix", workflow)
        self.assertIn("CI_TEST_SELECTION: ${{ needs.changes.outputs.python_tests }}", workflow)
        self.assertIn("python3 script/ci_run_tests.py python", workflow)

    def test_evidence_is_retained_after_failure_without_blocking_cancellation(self):
        # A status function overrides implicit success(), preserving failed-run evidence.
        # Unlike always(), !cancelled() lets superseding PR runs release their runners.
        for name in ("Upload core results", "Export UI test attachments", "Upload UI results",
                     "Upload stability results", "Upload automation evidence",
                     "Upload input conversion diagnostic evidence"):
            with self.subTest(step=name):
                condition = re.search(re.escape(name) + r"\n        if: (.+)", WORKFLOW)[1]
                self.assertEqual(condition, "${{ !cancelled() }}")
        # Required gates still reject cancellation rather than treating it as success.
        for name in ("quality", "regression", "build", "automation-e2e"):
            self.assertIn("always()", job(name).split("    steps:", 1)[0])

    def test_stable_simulator_gate_requires_all_selected_groups(self):
        workflow = job("automation-e2e")
        self.assertIn("name: Automation e2e (simulator)", workflow)
        self.assertIn("needs: [changes, automation-e2e-scenarios]", workflow)
        self.assertIn("if: ${{ always() }}", workflow)
        self.assertEqual(gate("automation-e2e", ROUTING="success", SELECTED="true", SCENARIOS="success"), 0)
        for result in ("failure", "cancelled", "skipped", ""):
            with self.subTest(result=result):
                self.assertNotEqual(gate("automation-e2e", ROUTING="success", SELECTED="true", SCENARIOS=result), 0)
        self.assertNotEqual(gate("automation-e2e", ROUTING="failure", SELECTED="true", SCENARIOS="success"), 0)
        self.assertEqual(gate("automation-e2e", ROUTING="success", SELECTED="false", SCENARIOS="skipped"), 0)
        self.assertNotEqual(gate("automation-e2e", ROUTING="success", SELECTED="false", SCENARIOS="failure"), 0)
        self.assertNotEqual(gate("automation-e2e", ROUTING="success", SELECTED="false", SCENARIOS="success"), 0)
        self.assertNotEqual(gate("automation-e2e", ROUTING="success", SELECTED="", SCENARIOS="skipped"), 0)

    def test_native_cache_fallback_keeps_toolchain_and_manifest_boundaries(self):
        build = job("native-build")
        prefixes = build.split("          restore-keys: |\n", 1)[1].split("      - name:", 1)[0].strip().splitlines()
        self.assertEqual(len(prefixes), 2)
        self.assertEqual(prefixes[1].strip(), prefixes[0].strip().replace(
            "${{ needs.changes.outputs.ui }}", "${{ needs.changes.outputs.ui != 'true' }}"))
        self.assertIn("${{ steps.toolchain.outputs.version }}", prefixes[0])
        self.assertIn("${{ hashFiles(", prefixes[0])

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
