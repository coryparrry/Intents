"""Exercise release preflight guards and the Linux-to-macOS source contract."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest


WORKFLOW = (
    Path(__file__).resolve().parents[2] / ".github/workflows/package-installer.yml"
).read_text()
RELEASE_WORKFLOW = (
    Path(__file__).resolve().parents[2] / ".github/workflows/release-me.yml"
).read_text()


def job(name, workflow=WORKFLOW):
    return re.search(
        r"(?ms)^  " + re.escape(name) + r":\n(.*?)(?=^  [\w-]+:|\Z)", workflow
    )[1]


def job_permissions(name, workflow=WORKFLOW):
    block = re.search(r"(?m)^    permissions:\n((?:      [\w-]+: \w+\n)+)", job(name, workflow))
    return dict(re.findall(r"([\w-]+): (\w+)", block[1])) if block else {}


def step_script(name, workflow=WORKFLOW):
    step = job("preflight", workflow).split("      - name: " + name + "\n", 1)[1]
    return textwrap.dedent(
        re.search(r"(?ms)^        run: \|\n(.*?)(?=^\S|^ {0,8}\S|\Z)", step)[1]
    )


class PackageInstallerWorkflowTests(unittest.TestCase):
    def test_wait_and_exact_ci_validation_finish_before_the_mac_job(self):
        preflight, release = job("preflight"), job("release")
        self.assertIn("runs-on: ubuntu-latest", preflight)
        self.assertIn("timeout-minutes: 45", preflight)
        self.assertIn("bash control/script/wait_release_ci.sh", preflight)
        self.assertIn('bash control/script/verify_release_source.sh "$RELEASE_SOURCE_SHA"', preflight)
        self.assertLess(preflight.index("wait_release_ci.sh"), preflight.index("verify_release_source.sh"))
        self.assertIn("needs: preflight", release)
        self.assertNotIn("if:", release)
        self.assertIn("runs-on: xcode-27", release)
        self.assertNotIn("wait_release_ci.sh", release)
        self.assertIn("source_sha: ${{ steps.candidate.outputs.source_sha }}", preflight)
        self.assertIn("ref: ${{ needs.preflight.outputs.source_sha }}\n          path: source", release)
        self.assertNotIn("gh release view", release)

    def test_preflight_can_read_drafts_without_signing_credentials(self):
        preflight, release = job("preflight"), job("release")
        # GitHub hides draft releases from tokens without contents: write.
        self.assertEqual(job_permissions("preflight"), {"contents": "write", "actions": "read"})
        self.assertNotIn("secrets.", preflight)
        self.assertNotIn("environment:", preflight)
        self.assertIn("environment: release", release)
        self.assertIn("contents: write", release)
        self.assertIn("cancel-in-progress: false", WORKFLOW)
        self.assertIn("needs: release", job("homebrew"))

    def test_release_baseline_can_read_unpublished_drafts(self):
        self.assertEqual(job_permissions("release", RELEASE_WORKFLOW)["contents"], "write")

    def test_reusable_caller_grants_draft_access(self):
        caller = job("installer", RELEASE_WORKFLOW)
        self.assertIn("uses: ./.github/workflows/package-installer.yml", caller)
        self.assertEqual(job_permissions("installer", RELEASE_WORKFLOW),
                         {"contents": "write", "actions": "read"})

    def test_both_jobs_use_protected_control_and_mac_revalidates_before_build(self):
        for name in ("preflight", "release"):
            self.assertIn("ref: ${{ github.sha }}\n          path: control", job(name))
            self.assertIn("persist-credentials: false", job(name))
        release = job("release")
        self.assertLess(release.index("release_dispatch.sh prepare"), release.index("control/script/release.sh"))
        self.assertLess(release.index("control/script/release.sh"), release.index("release_dispatch.sh publish"))
        self.assertIn("RELEASE_BRANCH: ${{ github.event.repository.default_branch }}", release)

    def test_default_branch_and_tag_guard_executes(self):
        script = step_script("Require the default branch")
        for ref, tag, valid in (
            ("refs/heads/main", "v1.2.3", True),
            ("refs/heads/feature", "v1.2.3", False),
            ("refs/tags/v1.2.3", "v1.2.3", False),
            ("refs/heads/main", "release/latest", False),
        ):
            with self.subTest(ref=ref, tag=tag):
                result = subprocess.run(
                    ["bash", "-e", "-o", "pipefail", "-c", script],
                    env={**os.environ, "GITHUB_REF": ref, "EXPECTED_REF": "refs/heads/main", "RELEASE_TAG": tag},
                    capture_output=True,
                )
                self.assertEqual(result.returncode == 0, valid, result.stderr)

    def candidate(self, *, workflow=WORKFLOW, caller=None, **overrides):
        draft_access = job_permissions("preflight", workflow).get("contents") == "write"
        if caller is not None:
            # A reusable workflow cannot elevate the caller's token permissions.
            draft_access &= job_permissions("installer", caller).get("contents") == "write"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / "gh"
            fixture.write_text('''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
if os.environ.get("FAIL_API"):
    sys.exit(1)
if args[:2] == ["release", "view"]:
    if os.environ["FIXTURE_DRAFT_ACCESS"] != "1":
        sys.exit("release not found")
    assert args[args.index("--json") + 1] == "targetCommitish,isDraft"
    assert 'if .isDraft' in args[args.index("--jq") + 1]
    if os.environ.get("PUBLISHED"):
        sys.exit(1)
    print(os.environ["DRAFT_SHA"])
elif args[0] == "api" and "/git/matching-refs/" in args[1]:
    print("refs/tags/v1.2.3" if os.environ.get("HAS_TAG") else "")
elif args[0] == "api" and "/commits/" in args[1]:
    print(os.environ["REMOTE_SHA"])
else:
    sys.exit("Unexpected GitHub call: " + repr(args))
''')
            fixture.chmod(0o755)
            output = root / "outputs"
            output.touch()
            result = subprocess.run(
                ["bash", "-e", "-o", "pipefail", "-c", step_script("Resolve the draft's immutable source", workflow)],
                env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}", "GITHUB_OUTPUT": str(output),
                     "GH_TOKEN": "fixture-token", "FIXTURE_DRAFT_ACCESS": str(int(draft_access)),
                     "GITHUB_REPOSITORY": "owner/repo", "RELEASE_TAG": "v1.2.3", "DRAFT_SHA": "a" * 40,
                     "EXPECTED_SOURCE_SHA": "a" * 40, "REMOTE_SHA": "a" * 40, **overrides},
                capture_output=True,
            )
            return result, output.read_text()

    def test_source_resolution_accepts_only_exact_immutable_draft(self):
        for caller in (None, RELEASE_WORKFLOW):
            for environment in ({}, {"HAS_TAG": "1"}, {"EXPECTED_SOURCE_SHA": ""}):
                with self.subTest(reusable=caller is not None, environment=environment):
                    result, output = self.candidate(caller=caller, **environment)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(output, "source_sha=" + "a" * 40 + "\n")

    def test_read_only_preflight_or_caller_cannot_export_draft_source(self):
        def read_only(source, name):
            original = job(name, source)
            return source.replace(original, original.replace("contents: write", "contents: read"))

        for workflow, caller in (
            (read_only(WORKFLOW, "preflight"), None),
            (read_only(WORKFLOW, "preflight"), RELEASE_WORKFLOW),
            (WORKFLOW, read_only(RELEASE_WORKFLOW, "installer")),
        ):
            with self.subTest(preflight=job_permissions("preflight", workflow), caller=caller is not None):
                result, output = self.candidate(workflow=workflow, caller=caller)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b"release not found", result.stderr)
                self.assertEqual(output, "")

    def test_rejected_candidate_never_exports_source_for_mac(self):
        for environment in (
            {"DRAFT_SHA": "main"}, {"DRAFT_SHA": "a" * 39},
            {"DRAFT_SHA": "b" * 40}, {"PUBLISHED": "1"},
            {"HAS_TAG": "1", "REMOTE_SHA": "b" * 40}, {"FAIL_API": "1"},
        ):
            with self.subTest(environment=environment):
                result, output = self.candidate(**environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output, "")


if __name__ == "__main__":
    unittest.main()
