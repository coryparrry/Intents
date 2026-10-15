"""Execute the CI aggregate gates against failed, cancelled, and skipped shards."""

import os
from pathlib import Path
import re
import subprocess
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
        common = dict(ROUTING="success", BUILD="success", CORE="success", UI="success", UI_SELECTED="true", STABILITY="skipped", STABILITY_SELECTED="false")
        self.assertEqual(gate("build", **common), 0)
        for field in ("ROUTING", "BUILD", "CORE", "UI"):
            for result in ("failure", "cancelled", "skipped"):
                self.assertNotEqual(gate("build", **{**common, field: result}), 0)
        self.assertEqual(gate("build", **{**common, "UI_SELECTED": "false", "UI": "skipped"}), 0)
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


if __name__ == "__main__":
    unittest.main()
