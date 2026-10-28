"""Exercise exact-checkout production qualification without native build work."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from script import ci_gate
from script.release_validation import REQUIRED_CHECKS, validate_checks


class ProductionQualificationTests(unittest.TestCase):
    """Keep fixture execution and its source release gate fail closed."""

    def run_qualification(self, failed_stage=""):
        """Run the maintained script in an isolated checkout with recording tools."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "script").mkdir()
            source = Path(__file__).resolve().parents[1] / "ci_production_evals.sh"
            shutil.copy2(source, root / "script/ci_production_evals.sh")
            tools = root / "bin"
            tools.mkdir()
            log = root / "commands.log"
            for name in ("swift", "python3"):
                command = tools / name
                command.write_text(
                    "#!/bin/sh\n"
                    'printf "%s|%s|%s|%s\\n" "${0##*/}" "$PWD" '
                    '"$SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH" "$*" >> "$CALL_LOG"\n'
                    'if [ "$1" = "$FAILED_STAGE" ]; then exit 19; fi\n'
                )
                command.chmod(0o700)
            environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                               CALL_LOG=str(log), FAILED_STAGE=failed_stage)
            result = subprocess.run(
                ["bash", str(root / "script/ci_production_evals.sh")], cwd=tools,
                env=environment, capture_output=True, text=True, check=False,
            )
            calls = [line.split("|", 3) for line in log.read_text().splitlines()]
            self.assertTrue(all(Path(call[1]) == root for call in calls))
            self.assertTrue(all(call[2] == "4" for call in calls))
            return result, [(call[0], call[3]) for call in calls]

    def test_current_checkout_runs_package_then_built_cli_protocol(self):
        """Qualification tests the nested package and the CLI built from that checkout."""
        result, calls = self.run_qualification()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [
            ("swift", "test --package-path Packages/ProductionEvals -j 2"),
            ("swift", "build -j 2 --product intents-evals"),
            ("python3", "script/test_production_evals.py .build/debug/intents-evals"),
        ])

    def test_each_failure_stops_qualification_and_blocks_source_release_gates(self):
        """A package, CLI build, or worker-protocol failure cannot authorize release."""
        for stage, count in (("test", 1), ("build", 2), ("script/test_production_evals.py", 3)):
            with self.subTest(stage=stage):
                result, calls = self.run_qualification(stage)
                self.assertEqual(result.returncode, 19, result.stderr)
                self.assertEqual(len(calls), count)
                selection = {key: "false" for key in ci_gate.FLAGS}
                selection.update({key: "[]" for key in ci_gate.ARRAYS})
                selection.update(production_evals="true", regression="true")
                needs = {worker: {"result": "skipped"} for worker in ci_gate.WORKERS}
                needs["changes"] = {"result": "success"}
                needs["swift-tests"] = {"result": "failure"}
                self.assertTrue(ci_gate.evaluate(needs, selection, "false"))
                jobs = [{"name": name, "conclusion": "success"} for name in REQUIRED_CHECKS]
                for job in jobs:
                    if job["name"] == "Portable regression tests":
                        job["conclusion"] = "failure"
                with self.assertRaisesRegex(ValueError, "Portable regression tests"):
                    validate_checks(jobs)
