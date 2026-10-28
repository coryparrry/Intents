import contextlib
import copy
import io
import hashlib
import shutil
import json
from pathlib import Path
import tempfile
import unittest

from script import document_quality_report as quality


class QualityReportTests(unittest.TestCase):
    def setUp(self):
        """Prepare isolated synthetic evidence and temporary storage for each report regression."""
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        (self.directory / 'exit-code.txt').write_text('0\n')
        cases = []
        digest = hashlib.sha256(b"Source").hexdigest()
        passage = {"id": "p", "location": "Page 1", "text": "Source"}
        sources, documents = [], []
        for index in range(10):
            name = f"document-{index}.txt"
            (self.directory / name).write_text("Source")
            sources.append({"name": name, "fileDigest": digest, "passages": [passage]})
            documents.append({"id": f"document-{index}", "format": "txt", "requested": 10})
        (self.directory / "input.json").write_text(json.dumps({"documents": documents, "controls": []}))
        (self.directory / "sources.jsonl").write_text("\n".join(map(json.dumps, sources)))
        for index in range(100):
            cases.append({"documentID": f"document-{index // 10}", "slot": index % 10, "passage": passage, "outcome": "surfaced",
                "candidate": {"id": str(index), "prompt": "Question", "expected": "Answer", "criteriaOverride": ["Requirement"],
                    "documentEvidence": {"generatorVersion": "document-draft-v6", "sourceName": f"document-{index // 10}.txt", "sourceDigest": digest, "passages": [{"id": "p", "location": "Page 1", "text": "Source"}],
                        "citations": [{"passageID": "p", "quote": "Source"}]}}})
        (self.directory / "attempts.jsonl").write_text("\n".join(json.dumps(case) for case in cases))
        (self.directory / "summary.json").write_text(json.dumps({"generationVersion": "document-draft-v6", "documents": 10, "surfaced": 100, "attempts": 100, "requested": 100}))

    def tearDown(self):
        """Remove only the temporary fixture storage allocated by this test."""
        self.temporary.cleanup()

    def run_report(self, labels=None, controls=None, reviewer_kind="human"):
        """Invoke the report against the isolated evidence fixture and return its qualification result."""
        with contextlib.redirect_stdout(io.StringIO()):
            quality.report(self.directory, labels, controls, reviewer_kind)
        return json.loads((self.directory / "quality-gates.json").read_text())

    def set_summary_version(self, version):
        """Change the fixture summary version to exercise stale-evidence rejection."""
        path = self.directory / 'summary.json'
        summary = json.loads(path.read_text())
        summary['generationVersion'] = version
        path.write_text(json.dumps(summary))

    def test_semantic_candidates_cannot_bypass_review_with_stale_summary(self):
        """Require current semantic receipts even when older summary metadata would otherwise omit the review gate."""
        path = self.directory / 'attempts.jsonl'
        rows = quality.load_lines(path)
        for row in rows:
            row['candidate']['documentEvidence']['generatorVersion'] = 'document-draft-v17'
        path.write_text('\n'.join(map(json.dumps, rows)))
        for version in [None, 'document-draft-v15', 'unknown']:
            self.set_summary_version(version)
            with self.assertRaisesRegex(AssertionError, 'generation version'):
                self.run_report()
        self.set_summary_version('document-draft-v17')
        # Matching metadata must enter semantic verification, not silently skip it.
        with self.assertRaises(FileNotFoundError):
            self.run_report()
        rows[0]['candidate']['documentEvidence']['generatorVersion'] = 'document-draft-v15'
        path.write_text('\n'.join(map(json.dumps, rows)))
        with self.assertRaisesRegex(AssertionError, 'generation version mismatch'):
            self.run_report()

    def test_no_human_labels_cannot_pass(self):
        """Refuse human-reviewed qualification when the retained run has no complete human labeling evidence."""
        result = self.run_report()
        self.assertFalse(result["generation_gate_passed"])
        self.assertEqual(result["human_reviewed"], 0)

    def test_missing_or_failed_terminal_state_cannot_qualify(self):
        """Require successful process completion before trusting partial quality artifacts."""
        self.run_report()
        labels = json.loads((self.directory / 'review-template.json').read_text())
        for label in labels.values():
            for field in ['supported', 'useful_distinct', 'rubric_correct', 'acceptable_without_edits']:
                label[field] = True
        path = self.directory / 'labels.json'
        path.write_text(json.dumps(labels))
        self.assertTrue(self.run_report(path)['generation_gate_passed'])
        (self.directory / 'exit-code.txt').write_text('65\n')
        self.assertFalse(self.run_report(path)['generation_gate_passed'])
        (self.directory / 'exit-code.txt').unlink()
        self.assertFalse(self.run_report(path)['generation_gate_passed'])

    def test_ai_labels_or_mismatched_candidates_do_not_count(self):
        """Keep human-review counts bound to the exact surfaced candidates and reject automated substitutes."""
        self.run_report()
        labels = json.loads((self.directory / "review-template.json").read_text())
        for index, label in enumerate(labels.values()):
            for field in ["supported", "useful_distinct", "rubric_correct", "acceptable_without_edits"]:
                label[field] = True
            if index % 2: label["reviewer_kind"] = "automated"
            else: label["candidate_sha256"] = "different-candidate"
        path = self.directory / "test-labels.json"
        path.write_text(json.dumps(labels))
        self.assertEqual(self.run_report(path)["human_reviewed"], 0)

    def test_duplicate_attempts_cannot_inflate_denominator(self):
        """Reject repeated attempt identities so duplicated records cannot improve apparent generation yield."""
        path = self.directory / "attempts.jsonl"
        rows = path.read_text().splitlines()
        rows[1] = rows[0]
        path.write_text("\n".join(rows))
        with self.assertRaises(AssertionError): self.run_report()

    def test_complete_consistent_fixture_passes_but_inconsistent_score_does_not(self):
        """Accept internally consistent evidence while rejecting scores that disagree with their retained control results."""
        self.run_report()
        labels = json.loads((self.directory / "review-template.json").read_text())
        for label in labels.values():
            for field in ["supported", "useful_distinct", "rubric_correct", "acceptable_without_edits"]:
                label[field] = True
        labels_path = self.directory / "fixture-labels.json"
        labels_path.write_text(json.dumps(labels))
        controls = self.directory / "controls"
        controls.mkdir()
        (controls / "exit-code.txt").write_text("0\n")
        manifest = json.loads((self.directory / "input.json").read_text())
        manifest["controls"] = [{"id": str(index), "source": "Source", "question": "Question",
            "reference": "Answer", "response": "Answer", "criteria": ["Requirement"],
            "expectedRequirementPasses": [True], "shouldPass": True} for index in range(28)]
        for name, value in [("input.json", manifest), ("judge-source-hashes.json", {"fixture.swift": "fixture-hash"}),
                            ("runtime.json", {"model": "fixture", "os": "fixture"})]:
            (self.directory / name).write_text(json.dumps(value))
            (controls / name).write_text(json.dumps(value))
        results = [{"control": control, "status": "passed", "score": 4,
            "trace": {"checks": [{"criterionIndex": 1, "score": 4}]}} for control in manifest["controls"]]
        path = controls / "controls.jsonl"
        path.write_text("\n".join(map(json.dumps, results)))
        self.assertTrue(self.run_report(labels_path, controls)["overall_gate_passed"])
        for label in labels.values():
            label["reviewer_kind"] = "automated"
        labels_path.write_text(json.dumps(labels))
        self.assertFalse(self.run_report(labels_path, controls)["overall_gate_passed"])
        automated = self.run_report(labels_path, controls, "automated")
        self.assertTrue(automated["overall_gate_passed"])
        self.assertEqual(automated["reviewed"], 100)
        self.assertEqual(automated["human_reviewed"], 0)
        self.assertFalse(automated["human_review_complete"])
        self.assertFalse(automated["human_overall_gate_passed"])
        results[0]["score"] = 2
        path.write_text("\n".join(map(json.dumps, results)))
        self.assertFalse(self.run_report(labels_path, controls, "automated")["scoring_gate_passed"])

    def test_automated_review_keeps_thresholds_and_candidate_integrity(self):
        """Apply the same quality and identity checks when review labels come from an automated workflow."""
        self.run_report(reviewer_kind="automated")
        labels = json.loads((self.directory / "review-template.json").read_text())
        for index, label in enumerate(labels.values()):
            for field in ["supported", "useful_distinct", "rubric_correct", "acceptable_without_edits"]:
                label[field] = index >= 10
        path = self.directory / "automated-labels.json"
        path.write_text(json.dumps(labels))
        self.assertTrue(self.run_report(path, reviewer_kind="automated")["generation_gate_passed"])
        first = next(iter(labels.values()))
        first["candidate_sha256"] = "different"
        path.write_text(json.dumps(labels))
        self.assertFalse(self.run_report(path, reviewer_kind="automated")["review_complete"])
        self.run_report(reviewer_kind="automated")
        first["candidate_sha256"] = next(iter(json.loads((self.directory / "review-template.json").read_text()).values()))["candidate_sha256"]
        for index, label in enumerate(labels.values()):
            label["supported"] = index >= 11
            label["acceptable_without_edits"] = index >= 21
        path.write_text(json.dumps(labels))
        self.assertFalse(self.run_report(path, reviewer_kind="automated")["generation_gate_passed"])

    def test_changed_source_or_retained_passage_rejected(self):
        """Bind qualification to the exact imported source rather than edited or substituted retained passages."""
        (self.directory / "document-0.txt").write_text("Changed source")
        with self.assertRaises(AssertionError): self.run_report()
        (self.directory / "document-0.txt").write_text("Source")
        path = self.directory / "attempts.jsonl"
        rows = quality.load_lines(path)
        rows[0]["candidate"]["documentEvidence"]["passages"][0]["text"] = "Changed excerpt"
        path.write_text("\n".join(map(json.dumps, rows)))
        with self.assertRaises(AssertionError): self.run_report()

    def test_v7_context_must_retain_the_complete_imported_source(self):
        """Reject context that omits imported qualifications even if its remaining citations still resolve."""
        source_path = self.directory / "sources.jsonl"
        sources = quality.load_lines(source_path)
        sources[0]["passages"].append({"id": "exception", "location": "Page 2", "text": "An exception."})
        source_path.write_text("\n".join(map(json.dumps, sources)))
        path = self.directory / "attempts.jsonl"
        rows = quality.load_lines(path)
        evidence = rows[0]["candidate"]["documentEvidence"]
        for row in rows:
            row['candidate']['documentEvidence']['generatorVersion'] = 'document-draft-v7'
            if row['documentID'] == 'document-0':
                row['candidate']['documentEvidence']['passages'] = sources[0]['passages']
        self.set_summary_version('document-draft-v7')
        evidence["passages"] = sources[0]["passages"]
        path.write_text("\n".join(map(json.dumps, rows)))
        self.run_report()
        evidence["passages"] = [rows[0]["passage"]]
        path.write_text("\n".join(map(json.dumps, rows)))
        with self.assertRaises(AssertionError): self.run_report()

    def test_scope_planned_generation_cannot_drop_background_exception(self):
        """Keep background exceptions authoritative when generation focuses on a narrower passage."""
        sources_path = self.directory / "sources.jsonl"
        sources = quality.load_lines(sources_path)
        exception = {"id": "exception", "location": "Page 2", "text": "Read-only documents do not autosave."}
        for source in sources:
            source["passages"].append(exception)
        sources_path.write_text("\n".join(map(json.dumps, sources)))
        attempts_path = self.directory / "attempts.jsonl"
        attempts = quality.load_lines(attempts_path)
        for row in attempts:
            evidence = row["candidate"]["documentEvidence"]
            evidence["generatorVersion"] = "document-draft-v15"
            evidence["passages"].append(exception)
        attempts_path.write_text("\n".join(map(json.dumps, attempts)))
        self.set_summary_version("document-draft-v15")
        self.run_report()
        attempts[0]["candidate"]["documentEvidence"]["passages"].pop()
        attempts_path.write_text("\n".join(map(json.dumps, attempts)))
        with self.assertRaises(AssertionError):
            self.run_report()

    def test_controls_require_same_definitions_sources_and_runtime(self):
        """Refuse reusable control evidence when any frozen definition, source input, or runtime identity differs."""
        controls = self.directory / "controls"
        controls.mkdir()
        (controls / "exit-code.txt").write_text("0\n")
        manifest = json.loads((self.directory / "input.json").read_text())
        for name, value in [("input.json", manifest), ("judge-source-hashes.json", {"judge.swift": "hash"}),
                            ("runtime.json", {"model": "model", "os": "os", "contextSize": 8192})]:
            (self.directory / name).write_text(json.dumps(value))
            shutil.copy(self.directory / name, controls / name)
        self.assertTrue(quality.compatible_controls(self.directory, controls, manifest))
        for name in ["input.json", "judge-source-hashes.json", "runtime.json"]:
            original = (controls / name).read_text()
            value = json.loads(original)
            if name == "input.json": value["controls"] = [{"id": "different-control"}]
            else: value[next(iter(value))] = "changed"
            (controls / name).write_text(json.dumps(value))
            self.assertFalse(quality.compatible_controls(self.directory, controls, manifest))
            (controls / name).write_text(original)


class AttemptLedgerTests(unittest.TestCase):
    def setUp(self):
        """Create two complete document ledgers with the same request bounds as the Swift harness."""
        self.manifest = {"documents": [{"id": "first", "requested": 2}, {"id": "second", "requested": 2}]}
        self.rows = [{"documentID": document["id"], "slot": slot, "outcome": "surfaced", "candidate": {"fixture": True}}
                     for document in self.manifest["documents"] for slot in range(2)]

    def validate(self, rows=None, version="document-draft-v19", summary=None):
        """Validate fixture attempts with independently derived manifest and ledger counters."""
        rows = self.rows if rows is None else rows
        if summary is None:
            summary = {"documents": len(self.manifest["documents"]),
                       "requested": sum(document["requested"] for document in self.manifest["documents"]),
                       "attempts": len(rows), "surfaced": sum(row.get("candidate") is not None for row in rows)}
        return quality.validate_attempt_ledger(self.manifest, rows, summary, version)

    def test_missing_manifest_document_and_changed_requested_total_are_rejected(self):
        """Reject omitted corpus documents and summary totals that understate the frozen request."""
        self.manifest["documents"].append({"id": "missing", "requested": 2})
        with self.assertRaisesRegex(AssertionError, "Every corpus document"):
            self.validate()
        self.manifest["documents"].pop()
        with self.assertRaisesRegex(AssertionError, "Summary.*requested"):
            self.validate(summary={"documents": 2, "requested": 3, "attempts": 4, "surfaced": 4})

    def test_slot_gaps_impossible_values_and_reordered_documents_are_rejected(self):
        """Require the original document order and a zero-based contiguous integer slot sequence."""
        for slot in [-1, 999, True, 0.0, "0"]:
            with self.subTest(slot=slot):
                rows = copy.deepcopy(self.rows)
                rows[0]["slot"] = slot
                with self.assertRaisesRegex(AssertionError, "slots"):
                    self.validate(rows)
        rows = copy.deepcopy(self.rows)
        rows[1]["slot"] = 2
        with self.assertRaisesRegex(AssertionError, "contiguous"):
            self.validate(rows)
        with self.assertRaisesRegex(AssertionError, "manifest document order"):
            self.validate(self.rows[2:] + self.rows[:2])

    def test_unsurfaced_rows_cannot_be_dropped_before_attempt_exhaustion(self):
        """Keep failed passage attempts in the ledger until the request or its full attempt bound is reached."""
        rows = [dict(row, candidate=None, outcome="runtime_failure") for row in self.rows[:2]] + self.rows[2:]
        with self.assertRaisesRegex(AssertionError, "Incomplete document"):
            self.validate(rows)
        exhausted = [dict(rows[0], slot=slot) for slot in range(4)] + self.rows[2:]
        self.assertEqual(self.validate(exhausted).count("runtime_failure"), 4)
        with self.assertRaisesRegex(AssertionError, "bounded attempt count"):
            self.validate([dict(rows[0], slot=slot) for slot in range(5)] + self.rows[2:])

    def test_outcomes_must_match_candidates_and_current_records_cannot_omit_them(self):
        """Prevent missing or relabeled outcomes from changing which attempts count as surfaced drafts."""
        for outcome in [None, "unknown", "duplicate"]:
            with self.subTest(outcome=outcome):
                rows = copy.deepcopy(self.rows)
                rows[0]["outcome"] = outcome
                with self.assertRaisesRegex(AssertionError, "outcome"):
                    self.validate(rows)
        rows = copy.deepcopy(self.rows)
        rows[0].pop("outcome")
        with self.assertRaisesRegex(AssertionError, "outcome"):
            self.validate(rows)
        rows = copy.deepcopy(self.rows)
        rows[0]["candidate"] = None
        with self.assertRaisesRegex(AssertionError, "outcome"):
            self.validate(rows)

    def test_early_stopping_requires_terminal_reason_and_forbids_later_attempts(self):
        """Allow the harness's budget/error stops while rejecting unexplained truncation or later continuation."""
        for outcome in ["suite_budget_rejection", "semantic_review_error"]:
            with self.subTest(outcome=outcome):
                terminal = dict(self.rows[0], candidate=None, outcome=outcome, issue="Retained terminal reason")
                self.validate([terminal] + self.rows[2:])
                with self.assertRaisesRegex(AssertionError, "after a terminal"):
                    self.validate([terminal] + self.rows[1:])
                terminal.pop("issue")
                with self.assertRaisesRegex(AssertionError, "retained reason"):
                    self.validate([terminal] + self.rows[2:])
        with self.assertRaisesRegex(AssertionError, "requested draft count"):
            self.validate(self.rows[:2] + [dict(self.rows[0], slot=2)] + self.rows[2:])

    def test_legacy_missing_outcomes_keep_the_same_completion_requirements(self):
        """Preserve candidate-derived historical outcomes without allowing legacy metadata to hide partial attempts."""
        rows = [{key: value for key, value in row.items() if key != "outcome"} for row in self.rows]
        self.assertEqual(self.validate(rows, version="document-draft-v6"), ["surfaced"] * 4)
        rows[0]["candidate"] = None
        with self.assertRaisesRegex(AssertionError, "Incomplete document"):
            self.validate(rows, version="document-draft-v6")
        omitted = [dict(rows[0], slot=slot) for slot in range(4)] + rows[2:]
        self.assertEqual(self.validate(omitted, version="document-draft-v6").count("legacy_omitted"), 4)


if __name__ == "__main__":
    unittest.main()
