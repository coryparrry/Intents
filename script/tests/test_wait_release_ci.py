"""Exercise exact-commit CI polling with a deterministic GitHub fixture."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class WaitReleaseCITests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.script = Path(__file__).resolve().parents[1] / "wait_release_ci.sh"
        fixture = self.root / "gh"
        fixture.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
state = Path(os.environ["STATE_FILE"])
attempt = int(state.read_text()) if state.exists() else 0
state.write_text(str(attempt + 1))
args = sys.argv[1:]
assert args[:2] == ["run", "list"]
assert args[args.index("--commit") + 1] == os.environ["RELEASE_SOURCE_SHA"]
assert args[args.index("--workflow") + 1] == "ci.yml"
assert args[args.index("--branch") + 1] == "main"
assert args[args.index("--event") + 1] == "push"
if os.environ.get("FAIL_API"):
    sys.exit(1)
results = json.loads(os.environ["CI_RESULTS"])
print(results[min(attempt, len(results) - 1)])
''')
        fixture.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.root}:{os.environ['PATH']}",
                        GITHUB_REPOSITORY="owner/repo", RELEASE_SOURCE_SHA="a" * 40,
                        RELEASE_BRANCH="main", CI_WAIT_INTERVAL="0", CI_WAIT_ATTEMPTS="3",
                        STATE_FILE=str(self.root / "state"))

    def wait(self, results, **environment):
        return subprocess.run(["bash", str(self.script)],
                              env=dict(self.env, CI_RESULTS=json.dumps(results), **environment),
                              text=True, capture_output=True, timeout=10)

    def attempts(self):
        return int((self.root / "state").read_text())

    def test_absent_then_pending_then_success(self):
        result = self.wait(["missing", "in_progress", "success"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.attempts(), 3)

    def test_failure_stops_immediately(self):
        result = self.wait(["failure", "success"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not pass: failure", result.stderr)
        self.assertEqual(self.attempts(), 1)

    def test_timeout_is_bounded(self):
        result = self.wait(["queued"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Timed out", result.stderr)
        self.assertEqual(self.attempts(), 3)

    def test_api_error_is_not_success(self):
        result = self.wait(["success"], FAIL_API="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.attempts(), 1)


if __name__ == "__main__":
    unittest.main()
