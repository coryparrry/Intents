import io
import http.client
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from script import ci_failure_summary as summary


class Response(io.BytesIO):
    def __init__(self, body=b"", status=200, headers=None):
        super().__init__(body)
        self.status, self.headers = status, headers or {}


class Opener:
    def __init__(self, responses):
        self.responses, self.requests = list(responses), []

    def open(self, request, timeout):
        self.requests.append(request)
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


class FakeAPI:
    def __init__(self, jobs=(), artifacts=(), logs=None, job_error=None, artifact_error=None):
        self.jobs, self.artifacts, self.logs = jobs, artifacts, logs or {}
        self.job_error, self.artifact_error, self.paths = job_error, artifact_error, []

    def pages(self, path, key):
        self.paths.append(path)
        yield from (self.jobs if key == "jobs" else self.artifacts)
        error = self.job_error if key == "jobs" else self.artifact_error
        if error:
            raise RuntimeError(error)

    def get(self, path, logs=False):
        self.paths.append(path)
        value = self.logs[int(path.split("/")[-2])]
        if isinstance(value, Exception):
            raise value
        return value.encode(), False


def failed_job(identifier=23, name="Mac UI"):
    return {"id": identifier, "name": name, "conclusion": "failure", "steps": [
        {"name": "Build private app", "conclusion": "failure", "number": 4}]}


class FailureSummaryTests(unittest.TestCase):
    def render(self, api, needs=None):
        return summary.summarize(api, "owner/repo", "99", "2", needs=needs)

    def test_original_failure_step_error_and_direct_links_survive_failed_gates(self):
        api = FakeAPI(jobs=[failed_job(), failed_job(24, "Compile app and tests")],
            artifacts=[{"id": 77, "name": "native-results", "expired": False}],
            logs={23: "error: exact compiler mismatch\n##[error]Process completed with exit code 65"})
        report = self.render(api)
        self.assertIn("Build private app", report)
        self.assertIn("exact compiler mismatch", report)
        self.assertNotIn("Process completed", report)
        self.assertIn("Failed aggregate gates: Compile app and tests", report)
        self.assertNotIn("/jobs/24/logs", api.paths)
        self.assertIn("/actions/runs/99/job/23#step:4:1", report)
        self.assertIn("/actions/runs/99/artifacts/77", report)
        self.assertIn("/repos/owner/repo/actions/runs/99/attempts/2/jobs", api.paths)

    def test_cancelled_skipped_and_unknown_are_distinct_from_original_failures(self):
        report = self.render(FakeAPI(jobs=[{"name": "Build", "conclusion": "cancelled"},
            {"name": "Tests", "conclusion": "skipped"}]))
        self.assertIn("cancellation is the recorded blocker", report)
        self.assertIn("Cancelled jobs: Build", report)
        self.assertIn("Skipped jobs: Tests", report)
        report = self.render(FakeAPI(jobs=[failed_job(name="Portable regression tests")]))
        self.assertIn("underlying cause is unknown", report)
        self.assertNotIn("Original failed jobs:", report)
        self.assertIn("unknown or infrastructure", self.render(FakeAPI()))
        self.assertIn("cancellation", self.render(FakeAPI(), {"gate": "cancelled"}))
        self.assertIn("terminal checks succeeded", self.render(FakeAPI(), {"gate": "success"}))

    def test_all_four_exact_workflow_gate_names_remain_aggregate_failures(self):
        names = ["Workflow and script checks", "Portable regression tests", "Compile app and tests",
                 "Automation e2e (simulator)"]
        api = FakeAPI(jobs=[failed_job(index, name) for index, name in enumerate(names, 1)])
        report = self.render(api)
        self.assertEqual(summary.GATES, {name.casefold() for name in names})
        self.assertIn("Failed aggregate gates", report)
        self.assertNotIn("Original failed jobs:", report)
        self.assertFalse(any(path.endswith("/logs") for path in api.paths))

    def test_partial_api_failure_preserves_known_original_job(self):
        api = FakeAPI(jobs=[failed_job()], logs={23: RuntimeError("GitHub request returned HTTP 403")},
                      job_error="GitHub request returned HTTP 502", artifact_error="invalid listing")
        report = self.render(api)
        for value in ["Mac UI", "Build private app", "Job listing incomplete", "Artifact listing incomplete", "Log unavailable for job 23", "HTTP 403"]:
            self.assertIn(value, report)

    def test_run_wide_artifacts_are_not_attributed_to_current_attempt(self):
        api = FakeAPI(artifacts=[{"id": 77, "name": "results-attempt-1", "expired": False,
            "created_at": "2026-10-17T18:00:00Z", "workflow_run": {
                "id": 99, "head_sha": "same-commit-for-both-attempts", "head_branch": "main"}}])
        report = self.render(api)
        self.assertIn("### Retained artifacts (entire workflow run)", report)
        self.assertIn("Jobs above are from attempt 2", report)
        self.assertIn("Artifacts may include other attempts", report)
        self.assertIn("does not identify the producing attempt", report)
        self.assertIn("results\\-attempt\\-1", report)
        self.assertIn("/repos/owner/repo/actions/runs/99/artifacts", api.paths)

    def test_redaction_and_markdown_escaping_cover_all_untrusted_fields(self):
        log = "\n".join(["2026-10-17T18:00:00Z error: valid <diagnostic> [x](evil)",
            "error: Authorization: Bearer actual-credential", "error: ghp_ABCDEFGHIJK123",
            "error: github_pat_ABCDEFGHIJK123", "error: sk-proj-ABCDEFGHIJK123",
            "export HOME=/private/home", "SECRET_ENV=private-value", "EnvironmentVariables: private-dump",
            '  "ENV_VAR": private-environment-field', "error: https://logs.example/file?sig=private-signature"])
        report = self.render(FakeAPI(jobs=[failed_job(name="job [unsafe](url) <script>")], logs={23: log}))
        for secret in ["actual-credential", "ghp_ABCDEFGHIJK123", "github_pat_ABCDEFGHIJK123", "sk-proj-ABCDEFGHIJK123", "/private/home", "private-value", "private-dump", "private-environment-field", "private-signature", "<script>"]:
            self.assertNotIn(secret, report)
        self.assertIn("&lt;diagnostic&gt;", report)
        self.assertIn(r"\[unsafe\]\(url\)", report)

    def test_logs_are_bounded_and_missing_actual_error_is_explicit(self):
        self.assertLessEqual(len(summary.error_excerpt("\n".join(f"error: item {i}" for i in range(30)))), 6)
        report = self.render(FakeAPI(jobs=[failed_job()], logs={23: "Process completed with exit code 1"}))
        self.assertIn("No specific error was found", report)

    def test_xctest_reason_precedes_export_filenames_and_wrapper_noise(self):
        assertion = "/project/MacTests.swift:118: error: testMac : XCTAssertTrue failed - Private app was not ready"
        noise = [f'File: {index}.txt, suggested name: "fixture-native-failure-attempt-{index}.txt"' for index in range(12)]
        noise += ["Executed 5 tests, with 1 failure (0 unexpected)", "Traceback (most recent call last):",
                  "subprocess.CalledProcessError: Command '['xcodebuild', 'test']' returned non-zero exit status 65."]
        excerpt = summary.error_excerpt("\n".join([assertion] + noise))
        self.assertEqual(excerpt, [assertion])
        self.assertTrue(all("fixture-native-failure" not in line for line in excerpt))
        self.assertEqual(summary.error_excerpt("FAIL: test_missing_fixture"), ["FAIL: test_missing_fixture"])

    def test_markdown_preserves_quotes_without_broken_numeric_entities(self):
        rendered = summary.markdown('error: expected \'ready\', received "waiting" <diagnostic>')
        self.assertIn("'ready'", rendered)
        self.assertIn('"waiting"', rendered)
        self.assertIn("&lt;diagnostic&gt;", rendered)
        self.assertNotIn("#x27", rendered)

    def test_ordinary_signature_token_and_credential_diagnostics_survive(self):
        diagnostics = ["error: invalid code signature", "SyntaxError: unexpected token",
                       "error: credential provider could not connect", "error: secret storage is unavailable"]
        report = self.render(FakeAPI(jobs=[failed_job()], logs={23: "\n".join(diagnostics)}))
        for diagnostic in diagnostics:
            self.assertIn(diagnostic, report)

    def test_credential_values_and_known_current_token_are_still_withheld(self):
        secrets = ["private-password-value", "private-key-value", "private-header-value", "opaque-current-auth-value"]
        log = '\n'.join(["error: password=private-password-value", 'error: "api_key": "private-key-value"',
                         "Authorization: private-header-value", "error: opaque-current-auth-value"])
        api = FakeAPI(jobs=[failed_job()], logs={23: log})
        api.token = "opaque-current-auth-value"
        report = self.render(api)
        for secret in secrets:
            self.assertNotIn(secret, report)

    def test_pagination_fetches_current_attempt_beyond_first_hundred_jobs(self):
        opener = Opener([Response(json.dumps({"jobs": [{"id": i} for i in range(100)]}).encode()),
                         Response(json.dumps({"jobs": [{"id": 101}]}).encode())])
        api = summary.GitHubAPI("https://api.github.com", "token", opener)
        jobs = list(api.pages("/repos/o/r/actions/runs/1/attempts/2/jobs", "jobs"))
        self.assertEqual(len(jobs), 101)
        self.assertTrue(opener.requests[1].full_url.endswith("per_page=100&page=2"))

    def test_redirect_does_not_forward_api_token_to_external_log_host(self):
        opener = Opener([Response(status=302, headers={"Location": "https://logs.example/log?sig=private"}),
                         Response(b"error: actual failure", status=206)])
        api = summary.GitHubAPI("https://api.github.com", "super-sensitive", opener)
        self.assertEqual(api.get("/repos/o/r/actions/jobs/1/logs", logs=True)[0], b"error: actual failure")
        self.assertEqual(opener.requests[0].get_header("Authorization"), "Bearer super-sensitive")
        self.assertIsNone(opener.requests[1].get_header("Authorization"))
        self.assertEqual(opener.requests[1].get_header("Range"), f"bytes=-{summary.LOG_LIMIT}")

    def test_redirect_errors_hide_signed_destination_and_reject_http(self):
        for destination in ["https://logs.example/log?sig=private", "http://logs.example/log"]:
            opener = Opener([Response(status=302, headers={"Location": destination}), Response(status=403)])
            api = summary.GitHubAPI("https://api.github.com", "sensitive", opener)
            with self.assertRaises(RuntimeError) as raised:
                api.get("/logs", logs=True)
            self.assertNotIn("private", str(raised.exception))
            self.assertNotIn("sensitive", str(raised.exception))

    def test_response_read_failure_is_reported_without_destination_credentials(self):
        class UnreadableResponse(Response):
            def read(self, size):
                raise OSError("https://logs.example/file?sig=private")
            read1 = read
        api = summary.GitHubAPI("https://api.github.com", "", Opener([UnreadableResponse()]))
        with self.assertRaisesRegex(RuntimeError, "GitHub response could not be read") as raised:
            api.get("/logs", logs=True)
        self.assertNotIn("private", str(raised.exception))

    def test_incomplete_http_read_preserves_safe_partial_summary(self):
        class IncompleteResponse(Response):
            def read(self, size):
                raise http.client.IncompleteRead(b"private-response-bytes", 12)
        api = summary.GitHubAPI("https://api.github.com", "", Opener([
            IncompleteResponse(), Response(b'{"artifacts": []}')]))
        report = self.render(api)
        self.assertIn("Job listing incomplete: GitHub response could not be read", report)
        self.assertNotIn("private-response-bytes", report)

    def test_response_size_bound_and_cli_writes_step_summary(self):
        api = summary.GitHubAPI("https://api.github.com", "", Opener([Response(b"x" * (summary.LOG_LIMIT + 20))]))
        body, truncated = api.get("/logs", logs=True)
        self.assertTrue(truncated)
        self.assertLessEqual(len(body), summary.LOG_LIMIT)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "summary.md"
            with patch.object(summary, "GitHubAPI", return_value=FakeAPI()):
                summary.main({"GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "99",
                    "GITHUB_RUN_ATTEMPT": "2", "GITHUB_STEP_SUMMARY": str(path),
                    "CI_NEEDS_JSON": '{"gate":{"result":"cancelled"}}'})
            self.assertIn("cancellation", path.read_text())

    def test_ignored_range_retains_late_assertion_with_bounded_reads(self):
        assertion = b"/project/Tests.swift:118: error: XCTAssertTrue failed - late failure"
        log = b"setup output\n" * summary.LOG_LIMIT + b"error: token=private-token\n" + assertion + b"\n"
        class ChunkedResponse(Response):
            def read1(self, size):
                self.asserted_read_size = size
                if size > 64 * 1024:
                    raise AssertionError("unbounded read")
                return super().read1(size)
        response = ChunkedResponse(log)
        opener = Opener([response])
        api = summary.GitHubAPI("https://api.github.com", "", opener)
        body, truncated = api.get("/logs", logs=True)
        self.assertTrue(truncated)
        self.assertLessEqual(len(body), summary.LOG_LIMIT)
        self.assertEqual(summary.error_excerpt(body.decode()), [assertion.decode()])
        self.assertEqual(opener.requests[0].get_header("Range"), f"bytes=-{summary.LOG_LIMIT}")

    def test_partial_content_retains_late_assertion_and_bounds_oversized_response(self):
        assertion = b"/project/Tests.swift:118: error: XCTAssertTrue failed - late failure\n"
        suffix = b"setup\n" * 100 + assertion
        api = summary.GitHubAPI("https://api.github.com", "", Opener([Response(suffix, status=206),
            Response(b"x" * (summary.LOG_LIMIT + 20), status=206)]))
        body, truncated = api.get("/logs", logs=True)
        self.assertFalse(truncated)
        self.assertEqual(summary.error_excerpt(body.decode()), [assertion.decode().strip()])
        body, truncated = api.get("/logs", logs=True)
        self.assertTrue(truncated)
        self.assertEqual(len(body), summary.LOG_LIMIT)

    def test_ignored_range_stream_has_a_read_deadline(self):
        class EndlessResponse(Response):
            def read1(self, size):
                return b"still running\n"
        api = summary.GitHubAPI("https://api.github.com", "", Opener([EndlessResponse()]))
        with patch.object(summary.time, "monotonic", side_effect=[0, 0, 31]):
            with self.assertRaisesRegex(RuntimeError, "exceeded its read time limit"):
                api.get("/logs", logs=True)

    def test_truncated_suffix_drops_partial_credential_line(self):
        log = b"Authorization: " + b"x" * summary.LOG_LIMIT + b"error: sensitive-fragment\nerror: actual failure\n"
        api = summary.GitHubAPI("https://api.github.com", "", Opener([Response(log)]))
        body, truncated = api.get("/logs", logs=True)
        self.assertTrue(truncated)
        self.assertNotIn(b"sensitive-fragment", body)
        self.assertEqual(summary.error_excerpt(body.decode()), ["error: actual failure"])


if __name__ == "__main__":
    unittest.main()
