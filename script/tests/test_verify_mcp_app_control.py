"""Keep the live MCP verification harness on the supported evaluation surface."""

import ast
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "verify_mcp_app_control.py"


class MCPVerificationContractTests(unittest.TestCase):
    def test_live_harness_does_not_invoke_retired_intent_actions(self):
        tree = ast.parse(SCRIPT.read_text())
        calls = {
            node.args[0].value
            for node in ast.walk(tree)
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and node.func.attr in {"call", "write"}
            and node.args
            and isinstance(node.args[0], ast.Constant)
            and isinstance(node.args[0].value, str)
        }
        self.assertFalse({name for name in calls if name.startswith("eval_intent_")})
        self.assertIn("eval_runner_state", calls)
        self.assertIn("eval_suite_configure", calls)
        self.assertIn("eval_production_job_start", calls)
        self.assertIn("eval_production_baseline_approve", calls)


if __name__ == "__main__":
    unittest.main()
