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
    def test_script_job_invokes_selected_python_test_runner(self):
        workflow = job("script-tests")
        self.assertIn("CI_TEST_SELECTION: ${{ needs.changes.outputs.python_tests }}", workflow)
        self.assertIn("python3 script/ci_run_tests.py python", workflow)

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
