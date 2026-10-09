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

        # Compile a test-only copy with a deterministic mutation immediately
        # after descriptor validation. Production has no hook or environment flag.
        marker = "        var data = Data()\n"
        probe = """        if let replacement = ProcessInfo.processInfo.environment["INTENTS_TEST_REPLACEMENT"] {
            try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("opened"))
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: URL(fileURLWithPath: replacement))
        }
        if ProcessInfo.processInfo.environment["INTENTS_TEST_GROW_FILE"] == "1" {
            try Data(repeating: 65, count: 5000).write(to: file)
        }
"""
        production = CLI.read_text()
        if production.count(marker) != 1:
            raise RuntimeError("Credential descriptor probe requires a unique post-validation read marker")
        probe_source = production.replace(marker, probe + marker, 1)
        probe_source = probe_source.replace("func run() throws -> Int32 {", """func run() throws -> Int32 {
    if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--probe-credential" {
        let token = try MCPCredential.load(for: URL(string: CommandLine.arguments[2])!, file: URL(fileURLWithPath: CommandLine.arguments[3]))
        return token == "synthetic-cli-regression-credential" ? 0 : 31
    }
""", 1)
        source.write_text(probe_source)
        cls.race_executable = Path(cls.build_directory.name) / "credential-race-probe"
        completed = subprocess.run(["swiftc", str(source), "-o", str(cls.race_executable)], capture_output=True, text=True, timeout=120, check=False)
        if completed.returncode:
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
    def connector(self, responder, *, redirect=None, address="127.0.0.1"):
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

        server = ThreadingHTTPServer((address, 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://{address}:{server.server_port}/mcp", requests
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    def test_saved_automation_reads_use_authenticated_existing_connector(self):
        calls = []
        digest = "a" * 64
        def respond(params):
            calls.append(params)
            return {"outcome": "read", "cases": [{"caseID": "case", "revision": 1, "digest": digest, "action": "ContractAction", "bundleID": "example.Fixture"}], "total": 1, "truncated": False, "nextCursor": None}
        with self.connector(respond) as (endpoint, requests):
            completed = self.run_cli("automation-cases", "--limit", "10", "--endpoint", endpoint)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(calls, [{"name": "eval_list_automation_cases", "arguments": {"limit": 10}}])
        self.assertTrue(all(header == f"Bearer {TOKEN}" for _, header in requests))
        self.assertFalse(json.loads(completed.stdout)["truncated"])

    def test_native_execution_request_only_queues_confirmation(self):
        request_id = "B895560E-634B-4323-A9E6-6C9EB12C5DE6"
        digest = "a" * 64
        calls = []
        def response(params):
            calls.append(params)
            return {"outcome": "committed", "request": {"requestID": request_id, "digest": digest, "state": "awaitingApproval"}}
        with self.connector(response) as (endpoint, requests):
            completed = self.run_cli("automation-run", "--request-id", request_id, "--digest", digest, "--endpoint", endpoint)
        self.assertEqual(completed.returncode, 10, completed.stderr)
        self.assertEqual(calls, [{"name": "eval_request_automation_run", "arguments": {"requestID": request_id, "digest": digest}}])
        self.assertEqual(len(requests), 2)
        self.assertIn("awaitingApproval", completed.stdout)

    def test_admitted_app_listing_and_selection_use_exact_population_digest(self):
        digest = "c" * 64
        listing = {"applications": [{"id": "/selected/Project.xcodeproj#TARGET", "name": "Subject", "kind": "sourceTarget", "configurations": ["Debug"]}],
                   "snapshotDigest": digest, "selectedID": "/selected/Project.xcodeproj#TARGET", "total": 1, "truncated": False}
        calls = []
        def response(params):
            calls.append(params)
            return {"outcome": "committed" if params["name"] == "eval_select_automation_app" else "read", "listing": listing}
        with self.connector(response) as (endpoint, requests):
            read = self.run_cli("automation-apps", "--endpoint", endpoint)
            selected = self.run_cli("automation-select", "--app-id", listing["selectedID"], "--digest", digest, "--endpoint", endpoint)
        self.assertEqual(read.returncode, 0, read.stderr); self.assertEqual(selected.returncode, 0, selected.stderr)
        self.assertEqual(calls, [{"name": "eval_list_automation_apps", "arguments": {}}, {"name": "eval_select_automation_app", "arguments": {"appID": listing["selectedID"], "snapshotDigest": digest}}])
        for flags in (["--app-id", listing["selectedID"]], ["--app-id", listing["selectedID"], "--digest", digest, "--path", "/arbitrary.app"]):
            with self.subTest(flags=flags), self.connector(response) as (endpoint, requests):
                rejected = self.run_cli("automation-select", *flags, "--endpoint", endpoint)
            self.assertNotEqual(rejected.returncode, 0); self.assertEqual(requests, [])

    def test_app_listing_and_selection_reject_mismatched_response(self):
        listing = {"applications": [{"id": "known", "name": "Subject", "kind": "sourceTarget", "configurations": []}],
                   "snapshotDigest": "c" * 64, "selectedID": "known", "total": 1, "truncated": False}
        full = [dict(listing["applications"][0], id=f"listed-{i}") for i in range(200)]
        for change in ({"snapshotDigest": "d" * 64}, {"selectedID": "other"}, {"total": 0},
                       {"total": 2, "truncated": True},
                       {"total": 201, "truncated": True, "applications": full, "selectedID": "known"}):
            with self.subTest(change=change), self.connector(lambda _: {"outcome": "committed", "listing": dict(listing, **change)}) as (endpoint, _):
                completed = self.run_cli("automation-select", "--app-id", "known", "--digest", "c" * 64, "--endpoint", endpoint)
            self.assertNotEqual(completed.returncode, 0)

    def fix_request(self, *, state="completed", candidate_failures=0):
        request = {"requestID": "B895560E-634B-4323-A9E6-6C9EB12C5DE6", "digest": "a" * 64, "state": state,
                   "kind": "fixComparison", "caseID": "case", "revision": 1, "caseDigest": "b" * 64, "originalAttemptID": "original"}
        if state == "completed":
            def population(prefix, failures):
                return [{"attemptID": f"{prefix}-{i}", "resourcesReleased": True,
                         "result": {"summary": "assertionFailed" if i < failures else "passed", "assessed": True,
                                    "evidenceComplete": True, "subjectDispatched": True, "subjectCompleted": True,
                                    "subjectDispatchUncertain": False, "failedObservations": ["visible"] if i < failures else []}} for i in range(30)]
            def counts(failures):
                return {"planned": 30, "dispatched": 30, "completed": 30, "assessed": 30, "failed": failures, "unassessed": 0, "notRun": 0, "unresolved": 0}
            request.update(resourcesReleased=True, comparison={"requestedAttemptsPerBuild": 30, "complete": True,
                           "contractDigest": "e" * 64, "oracleDigest": "d" * 64, "candidateCaseDigest": "c" * 64,
                           "beforeProductDigest": "f" * 64, "afterProductDigest": "a" * 64,
                           "before": population("before", 15), "after": population("after", candidate_failures),
                           "beforeCounters": counts(15), "afterCounters": counts(candidate_failures), "environmentQualificationComplete": False})
        return request

    def test_fix_request_waits_for_native_confirmation_and_denies_extra_authority(self):
        request = self.fix_request(state="awaitingApproval"); calls = []
        def response(params):
            calls.append(params); return {"outcome": "committed", "request": request}
        with self.connector(response) as (endpoint, _):
            completed = self.run_cli("automation-check-fix", "--request-id", request["requestID"], "--digest", request["digest"], "--endpoint", endpoint)
        self.assertEqual(completed.returncode, 10, completed.stderr)
        self.assertEqual(calls, [{"name": "eval_request_automation_fix", "arguments": {"requestID": request["requestID"], "digest": request["digest"]}}])
        for extra in (["--path", "/foreign.app"], ["--requested-attempts", "1"], ["--approval", "true"]):
            with self.subTest(extra=extra), self.connector(response) as (endpoint, requests):
                rejected = self.run_cli("automation-check-fix", "--request-id", request["requestID"], "--digest", request["digest"], *extra, "--endpoint", endpoint)
            self.assertNotEqual(rejected.returncode, 10); self.assertEqual(requests, [])

    def test_fix_comparison_requires_all_sixty_attempts_and_all_candidate_passes(self):
        for failures, code in ((0, 0), (1, 20)):
            request = self.fix_request(candidate_failures=failures)
            with self.subTest(failures=failures), self.connector(lambda _: {"outcome": "read", "request": request}) as (endpoint, _):
                completed = self.run_cli("automation-status", "--request-id", request["requestID"], "--endpoint", endpoint)
            self.assertEqual(completed.returncode, code, completed.stderr)
            self.assertEqual(len(json.loads(completed.stdout)["request"]["comparison"]["after"]), 30)
        incomplete = self.fix_request(); outcome = incomplete["comparison"]
        outcome["after"] = outcome["after"][:17]; outcome["complete"] = False; outcome["stopReason"] = "Fixture budget exhausted"
        outcome["afterCounters"].update(planned=17, dispatched=17, completed=17, assessed=17)
        with self.connector(lambda _: {"outcome": "read", "request": incomplete}) as (endpoint, _):
            completed = self.run_cli("automation-status", "--request-id", incomplete["requestID"], "--endpoint", endpoint)
        self.assertEqual(completed.returncode, 20, completed.stderr)

    def test_fix_comparison_rejects_false_counters_reused_ids_and_qualification_claims(self):
        for mutation in ("counters", "reuse", "original", "qualified", "same-build", "false-complete"):
            request = self.fix_request(); outcome = request["comparison"]
            if mutation == "counters": outcome["afterCounters"]["failed"] = 1
            elif mutation == "reuse": outcome["after"][0]["attemptID"] = outcome["before"][0]["attemptID"]
            elif mutation == "original": outcome["before"][0]["attemptID"] = "original"
            elif mutation == "qualified": outcome["environmentQualificationComplete"] = True
            elif mutation == "same-build": outcome["afterProductDigest"] = outcome["beforeProductDigest"]
            else: outcome["complete"] = False
            with self.subTest(mutation=mutation), self.connector(lambda _: {"outcome": "read", "request": request}) as (endpoint, _):
                completed = self.run_cli("automation-status", "--request-id", request["requestID"], "--endpoint", endpoint)
            self.assertNotIn(completed.returncode, (0, 10, 20))

    def reproduction_request(self, *, state="completed", complete=True, matching=2):
        request = {"requestID": "B895560E-634B-4323-A9E6-6C9EB12C5DE6", "digest": "a" * 64,
                   "state": state, "kind": "reproduction", "caseID": "case", "revision": 1,
                   "caseDigest": "b" * 64, "originalAttemptID": "original"}
        if state == "completed":
            attempts = []
            for i in range(5):
                fails = i < matching
                attempts.append({"attemptID": f"attempt-{i}", "resourcesReleased": True,
                                 "result": {"summary": "assertionFailed" if fails else "passed", "assessed": True,
                                            "evidenceComplete": True, "subjectDispatched": True,
                                            "subjectCompleted": True, "subjectDispatchUncertain": False,
                                            "failedObservations": ["visible"] if fails else []}})
            request.update(resourcesReleased=True, reproduction={"requestedAttempts": 5, "complete": complete,
                           "reproduced": complete and matching > 0, "matchingFailures": matching,
                           "assessedPasses": 5-matching, "otherFailures": 0, "unassessed": 0,
                           "signature": ["visible"], "attempts": attempts})
        return request

    def test_reproduction_request_queues_native_confirmation_with_strict_options(self):
        calls = []
        pending = self.reproduction_request(state="awaitingApproval")
        def response(params):
            calls.append(params)
            return {"outcome": "committed", "request": pending}
        with self.connector(response) as (endpoint, _requests):
            completed = self.run_cli("automation-reproduce", "--request-id", pending["requestID"], "--digest", pending["digest"], "--endpoint", endpoint)
        self.assertEqual(completed.returncode, 10, completed.stderr)
        self.assertEqual(calls, [{"name": "eval_request_automation_reproduction", "arguments": {"requestID": pending["requestID"], "digest": pending["digest"]}}])
        for extra in (["--approval", "true"], ["--requested-attempts", "1"], ["--original-attempt-id", "other"]):
            with self.subTest(extra=extra), self.connector(response) as (endpoint, requests):
                stopped = self.run_cli("automation-reproduce", "--request-id", pending["requestID"], "--digest", pending["digest"], *extra, "--endpoint", endpoint)
            self.assertNotIn(stopped.returncode, (0, 10, 20)); self.assertEqual(requests, [])

    def test_reproduction_status_counts_all_attempts_even_when_last_passes(self):
        for matching, code in [(2, 0), (0, 20)]:
            request = self.reproduction_request(matching=matching)
            with self.subTest(matching=matching), self.connector(lambda _params: {"outcome": "read", "request": request}) as (endpoint, _requests):
                completed = self.run_cli("automation-status", "--request-id", request["requestID"], "--endpoint", endpoint)
            self.assertEqual(completed.returncode, code, completed.stderr)
            self.assertEqual(json.loads(completed.stdout)["request"]["reproduction"]["matchingFailures"], matching)

    def test_reproduction_rejects_contradictory_or_last_attempt_evidence(self):
        from copy import deepcopy
        base = self.reproduction_request()
        variants = []
        for key, value in [("kind", "future-kind"), ("attemptID", "last"), ("result", base["reproduction"]["attempts"][-1]["result"])]:
            variants.append({**base, key: value})
        missing = deepcopy(base); del missing["reproduction"]; variants.append(missing)
        wrong = deepcopy(base); wrong["reproduction"]["matchingFailures"] = 0; variants.append(wrong)
        duplicate = deepcopy(base); duplicate["reproduction"]["attempts"][4]["attemptID"] = "attempt-0"; variants.append(duplicate)
        reused = deepcopy(base); reused["reproduction"]["attempts"][4]["attemptID"] = "original"; variants.append(reused)
        unreleased = deepcopy(base); unreleased["reproduction"]["attempts"][4]["resourcesReleased"] = False; variants.append(unreleased)
        missing_sig = deepcopy(base); del missing_sig["reproduction"]["attempts"][4]["result"]["failedObservations"]; variants.append(missing_sig)
        for variant in variants:
            with self.subTest(variant=variant), self.connector(lambda _params: {"outcome": "read", "request": variant}) as (endpoint, _requests):
                completed = self.run_cli("automation-status", "--request-id", base["requestID"], "--endpoint", endpoint)
            self.assertNotIn(completed.returncode, (0, 10, 20))

    def test_interrupted_reproduction_is_explicit_and_never_a_success(self):
        request = self.reproduction_request()
        outcome = request["reproduction"]
        outcome.update(attempts=outcome["attempts"][:2], complete=False, reproduced=False, assessedPasses=0,
                       interruption={"attemptID": "interrupted", "caseDigest": request["caseDigest"], "dispatchMayHaveOccurred": True, "reason": "Cancelled"}, stopReason="Cancelled")
        request["resourcesReleased"] = False
        with self.connector(lambda _params: {"outcome": "read", "request": request}) as (endpoint, _requests):
            completed = self.run_cli("automation-status", "--request-id", request["requestID"], "--endpoint", endpoint)
        self.assertEqual(completed.returncode, 20, completed.stderr)
        self.assertFalse(json.loads(completed.stdout)["request"]["resourcesReleased"])

    def test_execution_request_options_fail_before_connector(self):
        for command, options in [("automation-run", ["--request-id", "not-a-uuid", "--digest", "a" * 64]),
                                 ("automation-run", ["--request-id", "B895560E-634B-4323-A9E6-6C9EB12C5DE6"]),
                                 ("automation-preview", ["--approval", "true"])]:
            with self.subTest(command=command), self.connector(lambda _params: {}) as (endpoint, requests):
                completed = self.run_cli(command, *options, "--endpoint", endpoint)
            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(requests, [])

    def test_execution_status_needs_matching_identity_and_complete_business_proof(self):
        request_id = "B895560E-634B-4323-A9E6-6C9EB12C5DE6"
        base = {"requestID": request_id, "digest": "a" * 64, "state": "completed", "attemptID": "attempt",
                "caseID": "case", "revision": 1, "caseDigest": "b" * 64, "resourcesReleased": True,
                "result": {"summary": "executedUnassessed", "assessed": False, "evidenceComplete": True,
                           "subjectDispatched": True, "subjectCompleted": True, "subjectDispatchUncertain": False}}
        for variant, expected in [(base, 20), ({**base, "requestID": "00000000-0000-0000-0000-000000000000"}, None),
                                  ({key: value for key, value in base.items() if key != "result"}, None),
                                  ({**base, "attemptID": ""}, None), ({**base, "caseID": "../case"}, None),
                                  ({**base, "revision": -1}, None), ({**base, "revision": 100001}, None)]:
            with self.subTest(variant=variant), self.connector(lambda _params: {"outcome": "read", "request": variant}) as (endpoint, _requests):
                completed = self.run_cli("automation-status", "--request-id", request_id, "--endpoint", endpoint)
            if expected is None:
                self.assertNotIn(completed.returncode, (0, 10, 20))
            else:
                self.assertEqual(completed.returncode, expected, completed.stderr)
    def test_unassessed_saved_automation_is_not_reported_as_pass(self):
        digest = "b" * 64
        calls = []
        def respond(params):
            calls.append(params)
            return {"outcome": "read", "attemptID": "attempt", "caseDigest": digest, "resourcesReleased": True,
                    "result": {"summary": "executedUnassessed", "assessed": False, "evidenceComplete": True, "subjectDispatched": True, "subjectCompleted": True, "subjectDispatchUncertain": False}}
        with self.connector(respond) as (endpoint, _requests):
            completed = self.run_cli("automation-report", "--case-id", "case", "--revision", "1", "--digest", digest, "--attempt-id", "attempt", "--endpoint", endpoint)
        self.assertEqual(completed.returncode, 20, completed.stderr)
        self.assertEqual(calls[0]["name"], "eval_get_automation_attempt")
        self.assertEqual(calls[0]["arguments"], {"caseID": "case", "revision": 1, "digest": digest, "attemptID": "attempt"})
        self.assertEqual(json.loads(completed.stdout)["result"]["summary"], "executedUnassessed")

    def test_numeric_flags_and_mismatched_reports_are_rejected_without_output(self):
        digest = "c" * 64
        for invalid_field in ["assessed", "evidenceComplete", "subjectDispatched", "subjectCompleted", "subjectDispatchUncertain", "resourcesReleased"]:
            def respond(_params):
                result = {"summary": "passed", "assessed": True, "evidenceComplete": True, "subjectDispatched": True, "subjectCompleted": True, "subjectDispatchUncertain": False}
                report = {"outcome": "read", "attemptID": "attempt", "caseDigest": digest, "resourcesReleased": True, "result": result}
                if invalid_field == "resourcesReleased": report[invalid_field] = 1
                else: result[invalid_field] = 1
                return report
            with self.connector(respond) as (endpoint, _requests):
                completed = self.run_cli("automation-report", "--case-id", "case", "--revision", "1", "--digest", digest, "--attempt-id", "attempt", "--endpoint", endpoint)
            self.assertEqual(completed.returncode, 30, invalid_field)
            self.assertEqual(completed.stdout, "", invalid_field)

    def test_saved_automation_options_fail_before_connector(self):
        completed = self.run_cli("automation-cases", "--limit", "0")
        self.assertEqual(completed.returncode, 30)
        completed = self.run_cli("automation-report", "--case-id", "../case", "--revision", "1", "--digest", "a" * 64, "--attempt-id", "attempt")
        self.assertEqual(completed.returncode, 30)

    def native_preview(self):
        return {"digest": "a" * 64, "bundleID": "example.Fixture", "targetID": "target", "environmentID": "environment",
                "action": "ContractAction", "effects": ["Opens the fixture"], "maximumActions": 1,
                "installApproved": True, "disposable": True}

    def fix_preview(self):
        return {"digest": "a" * 64, "bundleID": "example.Fixture", "targetID": "target", "environmentID": "environment",
                "caseID": "case", "revision": 1, "caseDigest": "b" * 64, "candidateCaseDigest": "c" * 64,
                "beforeProductDigest": "d" * 64, "afterProductDigest": "e" * 64, "originalAttemptID": "original",
                "requestedAttemptsPerBuild": 30, "installApproved": True, "disposable": True}

    def reproduction_preview(self):
        return {"digest": "a" * 64, "bundleID": "example.Fixture", "targetID": "target", "environmentID": "environment",
                "caseID": "case", "revision": 1, "caseDigest": "b" * 64, "originalAttemptID": "original",
                "requestedAttempts": 5, "installApproved": True, "disposable": True}

    def assert_preview_rejected(self, command, preview, outcome="read"):
        with self.connector(lambda _params: {"outcome": outcome, "preview": preview}) as (endpoint, requests):
            completed = self.run_cli(command, "--endpoint", endpoint)
        self.assertEqual(completed.returncode, 30, completed.stdout + completed.stderr)
        self.assertEqual(completed.stdout, "")
        self.assertEqual(len(requests), 2)
        return completed

    def test_complete_previews_are_read_and_printed(self):
        for command, tool, preview in [("automation-preview", "eval_preview_automation", self.native_preview()),
                                       ("automation-fix-preview", "eval_preview_automation_fix", self.fix_preview()),
                                       ("automation-reproduction-preview", "eval_preview_automation_reproduction", self.reproduction_preview())]:
            calls = []
            def respond(params, preview=preview):
                calls.append(params)
                return {"outcome": "read", "preview": preview}
            with self.subTest(command=command), self.connector(respond) as (endpoint, requests):
                completed = self.run_cli(command, "--endpoint", endpoint)
                self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
                self.assertEqual(calls, [{"name": tool, "arguments": {}}])
                self.assertTrue(all(header == f"Bearer {TOKEN}" for _, header in requests))
                self.assertEqual(json.loads(completed.stdout), {"outcome": "read", "preview": preview})

    def test_previews_must_be_read_only_responses(self):
        for command, preview in [("automation-preview", self.native_preview()), ("automation-fix-preview", self.fix_preview()),
                                 ("automation-reproduction-preview", self.reproduction_preview())]:
            with self.subTest(command=command):
                completed = self.assert_preview_rejected(command, preview, outcome="committed")
                self.assertIn("canonical automation response", completed.stderr)

    def test_native_preview_rejects_unbounded_actions_and_missing_effects(self):
        for change in ({"maximumActions": 0}, {"maximumActions": 1001}, {"effects": []}, {"digest": "A" * 64},
                       {"digest": "a" * 63}, {"bundleID": ""}, {"action": ""}):
            with self.subTest(change=change):
                completed = self.assert_preview_rejected("automation-preview", dict(self.native_preview(), **change))
                self.assertIn("Incomplete native action preview", completed.stderr)
        for boundary in (1, 1000):
            with self.subTest(maximumActions=boundary), self.connector(lambda _params: {"outcome": "read", "preview": dict(self.native_preview(), maximumActions=boundary)}) as (endpoint, _):
                completed = self.run_cli("automation-preview", "--endpoint", endpoint)
            self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_fix_preview_rejects_incomplete_or_self_comparing_plans(self):
        preview = self.fix_preview()
        for change in ({"digest": "not-a-digest"}, {"afterProductDigest": "E" * 64},
                       {"candidateCaseDigest": preview["caseDigest"]},
                       {"afterProductDigest": preview["beforeProductDigest"]},
                       {"requestedAttemptsPerBuild": 29}, {"requestedAttemptsPerBuild": 31},
                       {"installApproved": False}, {"originalAttemptID": "../original"},
                       {"revision": 0}, {"targetID": ""}):
            with self.subTest(change=change):
                completed = self.assert_preview_rejected("automation-fix-preview", dict(preview, **change))
                self.assertIn("Incomplete fix comparison preview", completed.stderr)

    def test_reproduction_preview_requires_exactly_five_attempts(self):
        for change in ({"requestedAttempts": 4}, {"requestedAttempts": 6}, {"requestedAttempts": 30},
                       {"caseDigest": "b" * 65}, {"caseID": "../case"}, {"revision": 100001}):
            with self.subTest(change=change):
                completed = self.assert_preview_rejected("automation-reproduction-preview", dict(self.reproduction_preview(), **change))
                self.assertIn("Incomplete reproduction preview", completed.stderr)

    def test_saved_case_cursor_is_forwarded_and_validated(self):
        cursor = "f" * 64 + ":50"
        calls = []
        def respond(params):
            calls.append(params)
            return {"outcome": "read", "cases": [], "total": 51, "truncated": True, "nextCursor": "f" * 64 + ":100"}
        with self.connector(respond) as (endpoint, _):
            completed = self.run_cli("automation-cases", "--limit", "50", "--cursor", cursor, "--endpoint", endpoint)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(calls, [{"name": "eval_list_automation_cases", "arguments": {"limit": 50, "cursor": cursor}}])
        self.assertEqual(json.loads(completed.stdout)["nextCursor"], "f" * 64 + ":100")
        for invalid in ("f" * 64, "F" * 64 + ":1", "f" * 63 + ":1", "f" * 64 + ":12345", "f" * 64 + ":-1", "../" + "f" * 61 + ":1"):
            with self.subTest(cursor=invalid), self.connector(respond) as (endpoint, requests):
                rejected = self.run_cli("automation-cases", "--cursor", invalid, "--endpoint", endpoint)
            self.assertEqual(rejected.returncode, 30)
            self.assertIn("Invalid saved-case cursor", rejected.stderr)
            self.assertEqual(requests, [])
        for next_cursor in (None, "opaque"):
            with self.subTest(next_cursor=next_cursor), self.connector(lambda _params: {"outcome": "read", "cases": [], "total": 51, "truncated": True, "nextCursor": next_cursor}) as (endpoint, _):
                truncated = self.run_cli("automation-cases", "--endpoint", endpoint)
            self.assertEqual(truncated.returncode, 30)
            self.assertEqual(truncated.stdout, "")

    def test_cancel_commits_only_the_matching_request(self):
        request_id = "B895560E-634B-4323-A9E6-6C9EB12C5DE6"
        calls = []
        def respond(params):
            calls.append(params)
            return {"outcome": "committed", "request": {"requestID": request_id, "digest": "a" * 64, "state": "cancelling"}}
        with self.connector(respond) as (endpoint, requests):
            completed = self.run_cli("automation-cancel", "--request-id", request_id.lower(), "--endpoint", endpoint)
        self.assertEqual(completed.returncode, 10, completed.stderr)
        self.assertEqual(calls, [{"name": "eval_cancel_automation_request", "arguments": {"requestID": request_id}}])
        self.assertTrue(all(header == f"Bearer {TOKEN}" for _, header in requests))
        self.assertEqual(json.loads(completed.stdout)["request"]["state"], "cancelling")
        with self.connector(lambda _params: {"outcome": "committed", "request": {"requestID": request_id, "digest": "a" * 64, "state": "cancelled"}}) as (endpoint, _):
            completed = self.run_cli("automation-cancel", "--request-id", request_id, "--endpoint", endpoint)
        self.assertEqual(completed.returncode, 20, completed.stderr)
        for outcome, response_id in (("committed", "00000000-0000-0000-0000-000000000000"), ("read", request_id)):
            with self.subTest(outcome=outcome, response_id=response_id), self.connector(lambda _params: {"outcome": outcome, "request": {"requestID": response_id, "digest": "a" * 64, "state": "cancelling"}}) as (endpoint, _):
                rejected = self.run_cli("automation-cancel", "--request-id", request_id, "--endpoint", endpoint)
            self.assertEqual(rejected.returncode, 30)
            self.assertEqual(rejected.stdout, "")
        for options in (["--request-id", "not-a-uuid"], ["--request-id", request_id, "--digest", "a" * 64]):
            with self.subTest(options=options), self.connector(respond) as (endpoint, requests):
                rejected = self.run_cli("automation-cancel", *options, "--endpoint", endpoint)
            self.assertEqual(rejected.returncode, 30)
            self.assertEqual(requests, [])

    def test_automation_endpoint_must_be_absolute_http(self):
        for endpoint in ("ftp://127.0.0.1/mcp", "file:///tmp/mcp", "/mcp"):
            with self.subTest(endpoint=endpoint):
                completed = self.run_cli("automation-preview", "--endpoint", endpoint)
            self.assertEqual(completed.returncode, 30)
            self.assertIn("Invalid MCP endpoint", completed.stderr)
            self.assertEqual(completed.stdout, "")

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

    def test_path_replacement_after_validation_reads_the_opened_file(self):
        replacement = Path(self.directory.name) / "replacement"
        replacement.write_text("synthetic-replacement-credential")
        replacement.chmod(0o644)
        with self.connector(lambda _params: {"releaseCheck": {"outcome": "passed", "summary": "Verified", "failures": []}}) as (endpoint, requests):
            completed = subprocess.run([str(self.race_executable), "scenario-report", "--run-id", "b895560e-634b-4323-a9e6-6c9eb12c5de6", "--endpoint", endpoint, "--credential-file", str(self.credential)], capture_output=True, text=True, env={**os.environ, "INTENTS_TEST_REPLACEMENT": str(replacement)}, timeout=30, check=False)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertTrue(requests)
            self.assertTrue(all(header == f"Bearer {TOKEN}" for _, header in requests))
            self.assertTrue(self.credential.is_symlink())

    def test_file_growth_after_validation_is_bounded_and_rejected(self):
        with self.connector(lambda _params: {}) as (endpoint, requests):
            completed = subprocess.run([str(self.race_executable), "scenario-report", "--run-id", "b895560e-634b-4323-a9e6-6c9eb12c5de6", "--endpoint", endpoint, "--credential-file", str(self.credential)], capture_output=True, text=True, env={**os.environ, "INTENTS_TEST_GROW_FILE": "1"}, timeout=30, check=False)
            self.assertNotEqual(completed.returncode, 0)
            self.assertFalse(requests)

    def test_other_literal_loopback_addresses_accept_explicit_credentials(self):
        for endpoint in ["http://127.0.0.2/mcp", "http://127.255.255.254/mcp", "http://[::1]/mcp"]:
            with self.subTest(endpoint=endpoint):
                completed = subprocess.run([str(self.race_executable), "--probe-credential", endpoint, str(self.credential)], capture_output=True, text=True, timeout=30, check=False)
                self.assertEqual(completed.returncode, 0, completed.stderr)
        for endpoint in ["http://126.0.0.1/mcp", "http://128.0.0.1/mcp", "http://127.0.0.1.example.invalid/mcp"]:
            with self.subTest(endpoint=endpoint):
                completed = subprocess.run([str(self.race_executable), "--probe-credential", endpoint, str(self.credential)], capture_output=True, text=True, timeout=30, check=False)
                self.assertNotEqual(completed.returncode, 0)
                self.assertIn("loopback HTTP", completed.stderr)

    def test_fifo_directory_and_oversized_credentials_are_rejected_without_hanging(self):
        fifo = Path(self.directory.name) / "fifo"
        os.mkfifo(fifo, 0o600)
        large = Path(self.directory.name) / "large"
        large.write_text("a" * 4097)
        large.chmod(0o600)
        for path in [fifo, Path(self.directory.name), large]:
            with self.subTest(path=path.name), self.connector(lambda _params: {}) as (endpoint, requests):
                completed = self.run_cli("scenario-report", "--run-id", "b895560e-634b-4323-a9e6-6c9eb12c5de6", "--endpoint", endpoint, credential=path)
                self.assertNotEqual(completed.returncode, 0)
                self.assertFalse(requests)

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
