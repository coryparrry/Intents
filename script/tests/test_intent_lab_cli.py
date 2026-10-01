import json
import os
import shutil
import subprocess
import tempfile
import threading
import unittest
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / "script" / "foundation-evals"
TOKEN = "synthetic-cli-regression-credential"


@unittest.skipUnless(shutil.which("swift"), "Swift is required to run the CLI integration check")
class IntentLabCLITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_directory = tempfile.TemporaryDirectory(prefix="intents-cli-tests-")
        source = Path(cls.build_directory.name) / "main.swift"
        source.write_text(CLI.read_text())
        cls.executable = Path(cls.build_directory.name) / "foundation-evals"
        completed = subprocess.run(
            ["swiftc", str(source), "-o", str(cls.executable)],
            capture_output=True, text=True, timeout=120, check=False,
        )
        if completed.returncode:
            cls.build_directory.cleanup()
            raise RuntimeError(completed.stdout + completed.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.build_directory.cleanup()

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="intents-cli-credential-")
        self.addCleanup(self.directory.cleanup)
        self.credential = Path(self.directory.name) / "credential"
        self.credential.write_text(TOKEN + "\n")
        self.credential.chmod(0o600)

    def run_cli(self, *arguments, credential=None):
        completed = subprocess.run(
            [str(self.executable), *arguments, "--credential-file", str(credential or self.credential)],
            cwd=ROOT, capture_output=True, text=True, timeout=30, check=False,
        )
        self.assertNotIn(TOKEN, completed.stdout + completed.stderr)
        return completed

    @contextmanager
    def connector(self, responder, *, redirect=None):
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                requests.append((request, self.headers.get("Authorization")))
                if self.headers.get("Authorization") != f"Bearer {TOKEN}":
                    self.send_response(401)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if redirect:
                    self.send_response(302)
                    self.send_header("Location", redirect)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                result = {} if request["method"] == "initialize" else {
                    "structuredContent": responder(request["params"]), "isError": False,
                }
                body = json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, _format, *_args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}/mcp", requests
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    def test_failed_report_with_zero_xctest_capture_exits_nonzero(self):
        run_id = "b895560e-634b-4323-a9e6-6c9eb12c5de6"
        tool_calls = []
        response_content = {
            "outcome": "read",
            "run": {
                "id": run_id,
                "outcome": "notObserved",
                "xctestExitCode": None,
                "laneResults": [],
            },
            "diagnostic": "No XCTest lane evidence was captured.",
            "releaseCheck": {
                "outcome": "failed",
                "summary": "Required intent evidence is missing.",
                "failures": ["The required Intent integration lane has no result."],
            },
        }

        def respond(params):
            tool_calls.append(params)
            return response_content

        with self.connector(respond) as (endpoint, requests):
            completed = self.run_cli(
                "scenario-report", "--run-id", run_id, "--endpoint", endpoint,
            )
        self.assertTrue(all(header == f"Bearer {TOKEN}" for _, header in requests))

        self.assertNotEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("Required intent evidence is missing.", completed.stdout)
        self.assertIn("The required Intent integration lane has no result.", completed.stdout)
        self.assertEqual(len(tool_calls), 1)
        self.assertEqual(tool_calls[0]["name"], "eval_get_scenario_report")
        self.assertEqual(tool_calls[0]["arguments"]["runID"].casefold(), run_id.casefold())

    def test_scenario_report_authenticates_initialization_and_tool_request(self):
        with self.connector(lambda _params: {
            "releaseCheck": {"outcome": "passed", "summary": "Verified", "failures": []}
        }) as (endpoint, requests):
            completed = self.run_cli("scenario-report", "--run-id", "b895560e-634b-4323-a9e6-6c9eb12c5de6", "--endpoint", endpoint)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertEqual([item[0]["method"] for item in requests], ["initialize", "tools/call"])
        self.assertTrue(all(header == f"Bearer {TOKEN}" for _, header in requests))

    def test_check_authenticates_all_requests_and_reports_success(self):
        def respond(params):
            return {
                "eval_list_projects": {"projects": [{"id": "project", "name": "Project", "suites": [{"id": "suite", "name": "Suite"}]}]},
                "eval_check": {"revision": "fixture"},
                "eval_get_run": {"run": {"phase": "completed", "completedSamples": 1, "plannedSampleCount": 1}},
                "eval_release_report": {"markdown": "Release passed", "report": {"outcome": 0}},
            }[params["name"]]
        with self.connector(respond) as (endpoint, requests):
            completed = self.run_cli("check", "--project", "Project", "--suite", "Suite", "--endpoint", endpoint)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("Release passed", completed.stdout)
        self.assertEqual(len(requests), 5)
        self.assertTrue(all(header == f"Bearer {TOKEN}" for _, header in requests))

    def test_wrong_credential_is_rejected_without_disclosing_it(self):
        self.credential.write_text("wrong-synthetic-credential")
        with self.connector(lambda _params: {}) as (endpoint, requests):
            completed = self.run_cli("scenario-report", "--run-id", "b895560e-634b-4323-a9e6-6c9eb12c5de6", "--endpoint", endpoint)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("HTTP 401", completed.stderr)
        self.assertNotIn("wrong-synthetic-credential", completed.stdout + completed.stderr)
        self.assertEqual(len(requests), 1)

    def test_invalid_or_missing_credential_fails_before_network_access(self):
        for contents in ["", "fixture\r\nInjected: header", "x" * 4097]:
            with self.subTest(contents_length=len(contents)):
                self.credential.write_text(contents)
                with self.connector(lambda _params: {}) as (endpoint, requests):
                    completed = self.run_cli("scenario-report", "--run-id", "b895560e-634b-4323-a9e6-6c9eb12c5de6", "--endpoint", endpoint)
                self.assertNotEqual(completed.returncode, 0)
                self.assertEqual(requests, [])
        with self.connector(lambda _params: {}) as (endpoint, requests):
            completed = self.run_cli("scenario-report", "--run-id", "b895560e-634b-4323-a9e6-6c9eb12c5de6", "--endpoint", endpoint, credential=Path(self.directory.name) / "missing")
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(requests, [])

    def test_group_readable_or_symlinked_credential_is_rejected(self):
        link = Path(self.directory.name) / "link"
        link.symlink_to(self.credential)
        self.credential.chmod(0o644)
        for path in [self.credential, link]:
            if path == link:
                self.credential.chmod(0o600)
            with self.subTest(path=path.name), self.connector(lambda _params: {}) as (endpoint, requests):
                completed = self.run_cli("scenario-report", "--run-id", "b895560e-634b-4323-a9e6-6c9eb12c5de6", "--endpoint", endpoint, credential=path)
            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(requests, [])

    def test_redirect_does_not_forward_a_credential(self):
        with self.connector(lambda _params: {}) as (target, forwarded):
            with self.connector(lambda _params: {}, redirect=target) as (endpoint, requests):
                completed = self.run_cli("scenario-report", "--run-id", "b895560e-634b-4323-a9e6-6c9eb12c5de6", "--endpoint", endpoint)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("HTTP 302", completed.stderr)
        self.assertEqual(len(requests), 1)
        self.assertEqual(forwarded, [])

    def test_remote_http_endpoint_is_rejected_before_loading_a_credential(self):
        completed = self.run_cli("scenario-report", "--run-id", "b895560e-634b-4323-a9e6-6c9eb12c5de6", "--endpoint", "http://example.invalid/mcp")
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("loopback HTTP", completed.stderr)


    def test_custom_endpoint_requires_explicit_credential(self):
        environment = os.environ.copy()
        environment.pop("FOUNDATION_EVALS_MCP_CREDENTIAL", None)
        with self.connector(lambda _params: {}) as (endpoint, requests):
            completed = subprocess.run([str(self.executable), "scenario-report", "--run-id", "b895560e-634b-4323-a9e6-6c9eb12c5de6", "--endpoint", endpoint], cwd=ROOT, capture_output=True, text=True, env=environment, timeout=30, check=False)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("A custom endpoint requires", completed.stderr)
        self.assertEqual(requests, [])

    def test_environment_credential_remains_supported(self):
        with self.connector(lambda _params: {"releaseCheck": {"outcome": "passed", "summary": "Verified", "failures": []}}) as (endpoint, requests):
            completed = subprocess.run([str(self.executable), "scenario-report", "--run-id", "b895560e-634b-4323-a9e6-6c9eb12c5de6", "--endpoint", endpoint], cwd=ROOT, capture_output=True, text=True, env={**os.environ, "FOUNDATION_EVALS_MCP_CREDENTIAL": TOKEN}, timeout=30, check=False)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertTrue(all(header == f"Bearer {TOKEN}" for _, header in requests))
        self.assertNotIn(TOKEN, completed.stdout + completed.stderr)

    def test_saved_execution_reports_keep_qualification_exit_codes(self):
        for expected, incomplete, failures, outcome in [(0, [], [], "passed"), (10, [], ["failed"], "failed"), (20, ["missing"], [], "failed")]:
            with self.subTest(expected=expected):
                with self.connector(lambda _params: {"qualification": {"incompleteEvidence": incomplete, "requiredFailures": failures, "report": {"outcome": outcome}}}) as (endpoint, requests):
                    completed = self.run_cli("scenario-execution-report", "--execution-id", "b895560e-634b-4323-a9e6-6c9eb12c5de6", "--endpoint", endpoint)
                self.assertEqual(completed.returncode, expected, completed.stdout + completed.stderr)
                self.assertEqual(requests[1][0]["params"]["name"], "eval_get_scenario_execution_report")
                self.assertTrue(all(header == f"Bearer {TOKEN}" for _, header in requests))

if __name__ == "__main__":
    unittest.main()
