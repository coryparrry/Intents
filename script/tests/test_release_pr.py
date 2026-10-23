"""Exercise release PR publication gates and CI dispatch with a recording GitHub fixture."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


class ReleasePRTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.script = Path(__file__).resolve().parents[1] / "release_pr.py"
        fixture = self.root / "gh"
        fixture.write_text("""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["CALL_LOG"], "a") as output:
    output.write(json.dumps(args) + "\\n")
if args[0] == "api":
    endpoint = args[1]
    if endpoint.endswith("/.release-please-manifest.json?ref=main"):
        assert endpoint == "repos/owner/repo/contents/.release-please-manifest.json?ref=main"
        assert args[2:] == ["-H", "Accept: application/vnd.github.raw+json"]
        if os.environ.get("FAIL_MANIFEST"):
            sys.exit(1)
        print(os.environ["MANIFEST"])
    else:
        assert args[2:] == ["--include"]
        if endpoint == "repos/owner/repo/releases/tags/v1.2.0":
            status = os.environ.get("RELEASE_STATUS", "200")
            body = os.environ["RELEASE"]
        else:
            assert endpoint == "repos/owner/repo/git/ref/tags/v1.2.0"
            status = os.environ.get("TAG_STATUS", "404")
            body = '{"ref":"refs/tags/v1.2.0"}'
        if status == "network":
            sys.exit("network unavailable")
        print("HTTP/2.0 " + status + " Test\\nX-Test: fixture\\n\\n" + body)
        sys.exit(0 if status == "200" else 1)
elif args[:2] == ["workflow", "run"]:
    assert args[2:6] == ["ci.yml", "--repo", "owner/repo", "--ref"]
    assert len(args) == 7
    sys.exit(1 if os.environ.get("FAIL_DISPATCH") else 0)
else:
    sys.exit("Unexpected GitHub operation: " + repr(args))
""")
        fixture.chmod(0o755)
        self.calls_path = self.root / "calls.jsonl"
        self.output_path = self.root / "output"
        self.env = dict(
            os.environ,
            PATH=f"{self.root}:{os.environ['PATH']}",
            GITHUB_REPOSITORY="owner/repo",
            GITHUB_OUTPUT=str(self.output_path),
            CALL_LOG=str(self.calls_path),
            MANIFEST=json.dumps({".": "1.2.0"}),
            RELEASE=json.dumps({"tag_name": "v1.2.0", "draft": False}),
        )
        self.env.pop("RELEASE_PRS", None)

    def run_script(self, mode, **environment):
        self.calls_path.unlink(missing_ok=True)
        self.output_path.unlink(missing_ok=True)
        return subprocess.run(
            ["python3", str(self.script), mode],
            cwd=self.root,
            env=dict(self.env, **environment),
            text=True,
            capture_output=True,
            timeout=10,
        )

    def calls(self):
        if not self.calls_path.exists():
            return []
        return [json.loads(line) for line in self.calls_path.read_text().splitlines()]

    def output(self):
        return self.output_path.read_text() if self.output_path.exists() else ""

    def test_published_manifest_version_allows_pr_generation(self):
        result = self.run_script("check-baseline")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output(), "ready=true\n")
        self.assertEqual(len(self.calls()), 2)

    def test_pending_draft_defers_pr_generation_without_failure(self):
        result = self.run_script(
            "check-baseline", RELEASE=json.dumps({"tag_name": "v1.2.0", "draft": True})
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output(), "ready=false\n")
        self.assertIn("waiting for installer publication", result.stdout)
        self.assertFalse(any(call[:2] == ["workflow", "run"] for call in self.calls()))


    def test_missing_150_recovery_starts_after_its_recorded_release(self):
        repository = self.script.parents[1]
        config = json.loads((repository / "release-please-config.json").read_text())
        boundary = config["bootstrap-sha"]
        self.assertRegex(boundary, r"^[0-9a-f]{40}$")
        # Inspect the historical manifest, so this remains valid after future releases.
        # Using the old v1.4.0 anchor would replay the already-recorded 1.5.0 features.
        historical = subprocess.check_output(
            ["git", "show", f"{boundary}:.release-please-manifest.json"],
            cwd=repository, text=True,
        )
        self.assertEqual(json.loads(historical)["."], "1.5.0")

    def test_missing_release_and_tag_allows_a_new_proposal(self):
        result = self.run_script("check-baseline", RELEASE_STATUS="404")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output(), "ready=true\n")
        self.assertIn("neither a release nor a tag", result.stdout)
        self.assertEqual(self.calls()[-1], ["api", "repos/owner/repo/git/ref/tags/v1.2.0", "--include"])

    def test_missing_release_with_existing_tag_never_allows_a_proposal(self):
        result = self.run_script("check-baseline", RELEASE_STATUS="404", TAG_STATUS="200")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.output(), "")

    def test_api_errors_never_count_as_absent_artifacts(self):
        cases = [{"FAIL_MANIFEST": "1"}]
        for status in ("401", "403", "429", "500", "network"):
            cases += [{"RELEASE_STATUS": status}, {"RELEASE_STATUS": "404", "TAG_STATUS": status}]
        for environment in cases:
            with self.subTest(environment=environment):
                result = self.run_script("check-baseline", **environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.output(), "")

    def test_invalid_manifest_stops_before_release_lookup(self):
        for manifest in (
            '{".": ""}',
            '{".": "1.2"}',
            '{".": "1.3.0-rc.1"}',
            '{".": null}',
            "{}",
            "invalid",
        ):
            with self.subTest(manifest=manifest):
                result = self.run_script("check-baseline", MANIFEST=manifest)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.output(), "")
                self.assertEqual(len(self.calls()), 1)

    def test_invalid_release_response_never_allows_pr_generation(self):
        for release in (
            '{"tag_name": "v1.1.1", "draft": false}',
            '{"tag_name": "v1.2.0", "draft": "false"}',
            "{}",
            "null",
            "[]",
            "invalid",
        ):
            with self.subTest(release=release):
                result = self.run_script("check-baseline", RELEASE=release)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.output(), "")

    def test_absent_empty_or_empty_array_pr_output_is_a_successful_noop(self):
        for environment in ({}, {"RELEASE_PRS": ""}, {"RELEASE_PRS": "[]"}):
            with self.subTest(environment=environment):
                result = self.run_script("dispatch-ci", **environment)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.calls(), [])

    def test_created_pr_dispatches_ci_on_its_branch(self):
        branch = "release-please--branches--main"
        result = self.run_script(
            "dispatch-ci", RELEASE_PRS=json.dumps([{"headBranchName": branch}])
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.calls(),
            [["workflow", "run", "ci.yml", "--repo", "owner/repo", "--ref", branch]],
        )

    def test_each_distinct_pr_branch_gets_ci_once(self):
        prs = [
            {"headBranchName": branch}
            for branch in ("release-a", "release-b", "release-a")
        ]
        result = self.run_script("dispatch-ci", RELEASE_PRS=json.dumps(prs))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [call[-1] for call in self.calls()], ["release-a", "release-b"]
        )

    def test_malformed_pr_output_never_dispatches(self):
        for prs in (
            "invalid",
            "{}",
            "null",
            "[null]",
            "[{}]",
            '[{"headBranchName": ""}]',
            '[{"headBranchName": "valid"}, {"headBranchName": 2}]',
        ):
            with self.subTest(prs=prs):
                result = self.run_script("dispatch-ci", RELEASE_PRS=prs)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])

    def test_dispatch_failure_is_reported(self):
        result = self.run_script(
            "dispatch-ci",
            FAIL_DISPATCH="1",
            RELEASE_PRS=json.dumps([{"headBranchName": "release-a"}]),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.calls()), 1)


if __name__ == "__main__":
    unittest.main()
