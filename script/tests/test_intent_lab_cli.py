import json
import shutil
import subprocess
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / "script" / "foundation-evals"


@unittest.skipUnless(shutil.which("swift"), "Swift is required to run the CLI integration check")
class IntentLabCLITests(unittest.TestCase):
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

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if request["method"] == "initialize":
                    result = {}
                else:
                    params = request["params"]
                    tool_calls.append(params)
                    result = {
                        "structuredContent": response_content,
                        "isError": False,
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
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        try:
            endpoint = f"http://127.0.0.1:{server.server_port}/mcp"
            completed = subprocess.run(
                [
                    "swift",
                    str(CLI),
                    "scenario-report",
                    "--run-id",
                    run_id,
                    "--endpoint",
                    endpoint,
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=120,
                check=False,
            )
        finally:
            server.shutdown()
            server.server_close()
            server_thread.join(timeout=5)

        self.assertNotEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("Required intent evidence is missing.", completed.stdout)
        self.assertIn("The required Intent integration lane has no result.", completed.stdout)
        self.assertEqual(len(tool_calls), 1)
        self.assertEqual(tool_calls[0]["name"], "eval_get_scenario_report")
        self.assertEqual(tool_calls[0]["arguments"]["runID"].casefold(), run_id.casefold())


if __name__ == "__main__":
    unittest.main()
