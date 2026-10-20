"""Check runner allocation against the router's actual Actions output contract."""

import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from script import ci_routes


class RegressionOutputTests(unittest.TestCase):
    def test_only_selected_regression_work_allocates_a_mac(self):
        cases = (
            ({}, False),
            ({"native": True}, False),
            ({"native": True, "native_tests": ["FoundationEvalsTests/CoreTests"]}, True),
            ({"input_conversion": True}, True),
            ({"sdk_consumer": True}, True),
            ({"swift_suites": ["CoreTests"]}, True),
            ({"macos_tests": ["script.tests.test_mac_fixture"]}, True),
        )
        for changes, expected in cases:
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                event, output, summary = (root / name for name in ("event.json", "output", "summary"))
                event.write_text("{}")
                plan = ci_routes.coverage([])
                plan.update(changes)
                env = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_EVENT_PATH": str(event),
                       "GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(summary)}
                with patch.dict(os.environ, env), patch.object(ci_routes, "coverage", return_value=plan), \
                     contextlib.redirect_stdout(io.StringIO()):
                    ci_routes.main()
                outputs = dict(line.split("=", 1) for line in output.read_text().splitlines())
                self.assertEqual(outputs["regression"], str(expected).lower())
                self.assertEqual(json.loads(outputs["native_tests"]), plan["native_tests"])
                self.assertEqual(outputs["input_conversion"], str(plan["input_conversion"]).lower())


if __name__ == "__main__":
    unittest.main()
