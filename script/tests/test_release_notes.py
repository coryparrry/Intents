"""Release-note policy for squash-merged pull requests."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "script"))
from release_notes import ALLOWED_ENTRY_TYPES, validate_pull_request


def override(*entries):
    return "\n".join(("BEGIN_COMMIT_OVERRIDE", *entries, "END_COMMIT_OVERRIDE"))


class ReleaseNotesTests(unittest.TestCase):
    def test_feature_and_fix_pull_requests_require_curated_notes(self):
        for title in ("feat(workspace): add projects", "fix(release): preserve notes"):
            with self.subTest(title=title), self.assertRaises(ValueError):
                validate_pull_request(title, "")

    def test_multiple_user_visible_entries_are_preserved(self):
        body = override(
            "feat(workspace): add projects and saved suites",
            "feat(judging): reassess saved responses independently",
            "fix(history): retain approved assessment identity",
        )
        self.assertEqual(
            validate_pull_request("feat(workflow): add daily checks", body),
            [
                "feat(workspace): add projects and saved suites",
                "feat(judging): reassess saved responses independently",
                "fix(history): retain approved assessment identity",
            ],
        )

    def test_maintenance_and_documentation_overrides_preserve_multiple_entries(self):
        entries = [
            "docs(site): explain first evaluations",
            "test(mcp): cover malformed tool requests",
            "ci(release): keep release branches current",
            "refactor(core): simplify request routing",
        ]
        self.assertEqual(
            validate_pull_request("docs: describe the workflow", override(*entries)),
            entries,
        )

    def test_override_retains_the_pull_request_release_type(self):
        with self.assertRaises(ValueError):
            validate_pull_request(
                "feat(workflow): add daily checks",
                override("fix(ui): align the sidebar"),
            )

    def test_non_feature_or_fix_pull_request_can_omit_override(self):
        for title in (
            "docs: explain releases",
            "ci: route tests",
            "chore: update metadata",
        ):
            with self.subTest(title=title):
                self.assertEqual(validate_pull_request(title, ""), [])

    def test_commented_template_instruction_is_not_active(self):
        template = (ROOT / ".github/pull_request_template.md").read_text()
        self.assertNotIn("BEGIN_COMMIT_OVERRIDE", template)
        self.assertNotIn("END_COMMIT_OVERRIDE", template)
        self.assertEqual(validate_pull_request("docs: update guidance", template), [])
        with self.assertRaises(ValueError):
            validate_pull_request("feat(ui): add navigation", template)

    def test_override_markers_hidden_in_html_comments_fail(self):
        body = "<!--\n" + override("feat(ui): hidden example") + "\n-->"
        for title in ("feat(ui): add navigation", "docs: explain navigation"):
            with self.subTest(title=title), self.assertRaises(ValueError):
                validate_pull_request(title, body)

    def test_inline_or_earlier_commented_markers_cannot_shadow_the_active_block(self):
        bodies = (
            "<!-- BEGIN_COMMIT_OVERRIDE -->\n" + override("feat(ui): visible example"),
            "<!-- hidden BEGIN_COMMIT_OVERRIDE\nfeat(ui): hidden\nEND_COMMIT_OVERRIDE -->\n"
            + override("feat(ui): visible example"),
            "<!--\n" + override("feat(ui): hidden in an unclosed comment"),
            "prefix BEGIN_COMMIT_OVERRIDE\nfeat(ui): ambiguous\nEND_COMMIT_OVERRIDE",
        )
        for body in bodies:
            with self.subTest(body=body), self.assertRaises(ValueError):
                validate_pull_request("feat(ui): add navigation", body)

    def test_fix_pull_request_cannot_accidentally_request_a_feature_bump(self):
        body = override("fix(ui): align the sidebar", "feat(ui): add navigation")
        with self.assertRaises(ValueError):
            validate_pull_request("fix(ui): align the sidebar", body)

    def test_breaking_intent_must_match_the_title_and_override(self):
        valid = override("feat(api)!: replace the response contract")
        self.assertEqual(
            validate_pull_request("feat(api)!: replace the response contract", valid),
            ["feat(api)!: replace the response contract"],
        )
        invalid_pairs = (
            (
                "feat(api)!: replace the response contract",
                override("feat(api): replace the response contract"),
            ),
            (
                "feat(api): extend the response contract",
                override("feat(api)!: replace the response contract"),
            ),
            (
                "fix(api)!: replace the response contract",
                override("fix(api): replace the response contract"),
            ),
        )
        for title, body in invalid_pairs:
            with self.subTest(title=title), self.assertRaises(ValueError):
                validate_pull_request(title, body)

    def test_malformed_empty_duplicate_and_unknown_entries_fail(self):
        bodies = (
            "END_COMMIT_OVERRIDE\nfeat(ui): example\nBEGIN_COMMIT_OVERRIDE",
            "BEGIN_COMMIT_OVERRIDE\nEND_COMMIT_OVERRIDE",
            override("feat(ui): one") + "\n" + override("feat(ui): two"),
            override("unknown: implementation detail"),
            override("feat(ui) missing separator"),
        )
        for body in bodies:
            with self.subTest(body=body), self.assertRaises(ValueError):
                validate_pull_request("feat(ui): add navigation", body)

    def test_configured_changelog_sections_match_allowed_entry_types(self):
        config = json.loads((ROOT / "release-please-config.json").read_text())
        sections = config["packages"]["."]["changelog-sections"]
        self.assertEqual({section["type"] for section in sections}, ALLOWED_ENTRY_TYPES)
        self.assertTrue(all(section["section"] for section in sections))
        self.assertEqual(len(sections), len(ALLOWED_ENTRY_TYPES))
        self.assertTrue(all(not section.get("hidden", False) for section in sections))

    def test_release_pr_refreshes_even_when_generated_notes_are_unchanged(self):
        config = json.loads((ROOT / "release-please-config.json").read_text())
        self.assertIs(config.get("always-update"), True)

    def test_ci_revalidates_edited_pull_request_bodies(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("types: [opened, synchronize, reopened, edited]", workflow)

    def test_cli_reads_the_pull_request_event(self):
        with tempfile.TemporaryDirectory() as temporary:
            event = Path(temporary) / "event.json"
            event.write_text(
                json.dumps(
                    {
                        "pull_request": {
                            "title": "fix(release): preserve notes",
                            "body": override(
                                "fix(release): preserve curated squash notes"
                            ),
                        }
                    }
                )
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "script/release_notes.py"),
                    "validate-event",
                    "--event",
                    str(event),
                ],
                text=True,
                capture_output=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Validated 1 curated release note entry.", result.stdout)


if __name__ == "__main__":
    unittest.main()
