import contextlib
import importlib.util
import io
import hashlib
import shutil
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("quality", Path(__file__).with_name("document_quality_report.py"))
quality = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quality)


class QualityReportTests(unittest.TestCase):
    def setUp(self):
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
            cases.append({"documentID": f"document-{index // 10}", "slot": index % 10, "passage": passage,
                "candidate": {"id": str(index), "prompt": "Question", "expected": "Answer", "criteriaOverride": ["Requirement"],
                    "documentEvidence": {"generatorVersion": "document-draft-v6", "sourceName": f"document-{index // 10}.txt", "sourceDigest": digest, "passages": [{"id": "p", "location": "Page 1", "text": "Source"}],
                        "citations": [{"passageID": "p", "quote": "Source"}]}}})
        (self.directory / "attempts.jsonl").write_text("\n".join(json.dumps(case) for case in cases))
        (self.directory / "summary.json").write_text(json.dumps({"generationVersion": "document-draft-v6", "documents": 10, "surfaced": 100, "attempts": 100, "requested": 100}))

    def tearDown(self):
        self.temporary.cleanup()

    def run_report(self, labels=None, controls=None, reviewer_kind="human"):
        with contextlib.redirect_stdout(io.StringIO()):
            quality.report(self.directory, labels, controls, reviewer_kind)
        return json.loads((self.directory / "quality-gates.json").read_text())

    def set_summary_version(self, version):
        path = self.directory / 'summary.json'
        summary = json.loads(path.read_text())
        summary['generationVersion'] = version
        path.write_text(json.dumps(summary))

    def test_semantic_candidates_cannot_bypass_review_with_stale_summary(self):
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
        result = self.run_report()
        self.assertFalse(result["generation_gate_passed"])
        self.assertEqual(result["human_reviewed"], 0)

    def test_missing_or_failed_terminal_state_cannot_qualify(self):
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
        path = self.directory / "attempts.jsonl"
        rows = path.read_text().splitlines()
        rows[1] = rows[0]
        path.write_text("\n".join(rows))
        with self.assertRaises(AssertionError): self.run_report()

    def test_complete_consistent_fixture_passes_but_inconsistent_score_does_not(self):
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
        (self.directory / "document-0.txt").write_text("Changed source")
        with self.assertRaises(AssertionError): self.run_report()
        (self.directory / "document-0.txt").write_text("Source")
        path = self.directory / "attempts.jsonl"
        rows = quality.load_lines(path)
        rows[0]["candidate"]["documentEvidence"]["passages"][0]["text"] = "Changed excerpt"
        path.write_text("\n".join(map(json.dumps, rows)))
        with self.assertRaises(AssertionError): self.run_report()

    def test_v7_context_must_retain_the_complete_imported_source(self):
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


if __name__ == "__main__":
    unittest.main()
