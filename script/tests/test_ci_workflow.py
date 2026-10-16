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
        for name in ("script-tests", "ui-tests"):
            self.assertIn("fail-fast: false", job(name))
            self.assertNotIn("max-parallel:", job(name))
        self.assertNotIn("--iterations", job("ui-tests"))

    def test_simulator_cache_is_saved_only_after_successful_compilation(self):
        workflow = job("automation-e2e-scenarios")
        self.assertIn("uses: actions/cache/restore@", workflow)
        self.assertIn("--record-build-cache", workflow)
        self.assertIn("steps.contract.outputs.cli_built == 'true'", workflow)
        self.assertIn("steps.cli-cache.outputs.cache-hit != 'true'", workflow)
        self.assertIn("uses: actions/cache/save@", workflow)
        self.assertIn("key: ${{ steps.cli-cache.outputs.cache-primary-key }}", workflow)

    def test_simulator_groups_run_in_parallel_with_unique_evidence_and_one_cache_writer(self):
        workflow = job("automation-e2e-scenarios")
        groups = re.search(r"group: \[([^\]]+)\]", workflow)[1].split(", ")
        self.assertEqual(groups, ["codec-1", "codec-2", "codec-file", "mixed", "wrong-assertion", "timeout-recovery"])
        self.assertIn("needs: changes", workflow)
        self.assertIn("fail-fast: false", workflow)
        self.assertNotIn("max-parallel:", workflow)
        self.assertIn('--scenario-group "$SCENARIO_GROUP"', workflow)
        self.assertIn("SCENARIO_GROUP: ${{ matrix.group }}", workflow)
        self.assertIn("name: automation-e2e-${{ matrix.group }}", workflow)
        condition = re.search(r"Save successfully compiled automation CLI\n        if: (.+)", workflow)[1]
        self.assertIn("always()", condition)
        self.assertIn("matrix.group == 'codec-1'", condition)
        self.assertIn("steps.contract.outputs.cli_built == 'true'", condition)
        self.assertNotIn("success()", condition)

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
