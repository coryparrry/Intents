import copy
import json
import tempfile
import unittest
from pathlib import Path
from document_semantic_report import candidate_digest, connection_digest, validate_review, semantic_metrics


class SemanticEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.connection = dict(id='connection', modelID='reviewer', kind='customCompatible',
                               baseURL='https://example.invalid/v1', providerOrder=[],
                               capabilities=dict(structuredOutputs=True), generationPolicy='portable')
        self.case = dict(prompt={'format': 'document-case-v1', 'text': 'When does autosave not run?'},
                         expected='In read-only mode.', criteriaOverride=['Identifies read-only mode.'],
                         documentEvidence=dict(passages=[dict(id='p', text='No autosave in read-only mode.')]))
        checks = [dict(criterionIndex=i, score=4, rationale='Source supports it') for i in range(1, 7)]
        self.review = dict(policyVersion='document-semantic-v5', candidateDigest=candidate_digest(self.case),
                           connectionID='connection', connectionDigest=connection_digest(self.connection),
                           modelID='reviewer', checks=checks, reviewedQuestions=[],
                           rawResponse=json.dumps(dict(requirements=checks)))

    def test_acceptance_is_bound_to_all_scoring_inputs(self):
        validate_review(self.review, self.case, self.connection)
        for field in ['prompt', 'expected', 'criteriaOverride', 'documentEvidence']:
            changed = copy.deepcopy(self.case)
            if field == 'prompt': changed[field]['text'] += ' changed'
            elif field == 'documentEvidence': changed[field]['passages'][0]['text'] += ' changed'
            elif field == 'criteriaOverride': changed[field][0] += ' changed'
            else: changed[field] += ' changed'
            with self.assertRaises(AssertionError): validate_review(self.review, changed, self.connection)

    def test_raw_verdict_cannot_be_relabelled_as_acceptance(self):
        changed = copy.deepcopy(self.review)
        changed['rawResponse'] = json.dumps(dict(requirements=[dict(c, score=2) for c in changed['checks']]))
        with self.assertRaises(AssertionError): validate_review(changed, self.case, self.connection)

    def test_every_check_must_fully_pass(self):
        changed = copy.deepcopy(self.review)
        changed['checks'][2]['score'] = 3
        changed['rawResponse'] = json.dumps(dict(requirements=changed['checks']))
        with self.assertRaises(AssertionError): validate_review(changed, self.case, self.connection)
        self.assertFalse(validate_review(changed, self.case, self.connection, False))

    def test_duplicate_indexes_and_wrong_endpoint_are_rejected(self):
        changed = copy.deepcopy(self.review)
        changed['checks'][-1]['criterionIndex'] = 1
        changed['rawResponse'] = json.dumps(dict(requirements=changed['checks']))
        with self.assertRaises(AssertionError): validate_review(changed, self.case, self.connection)
        with self.assertRaises(AssertionError):
            validate_review(self.review, self.case, dict(self.connection, baseURL='https://other.invalid/v1'))

    def write_run(self, path, events):
        (path / 'runtime.json').write_text(json.dumps(dict(judgeConfiguration=self.connection)))
        (path / 'semantic-attempts.jsonl').write_text('\n'.join(json.dumps(e) for e in events))

    def test_missing_receipt_cannot_surface_and_missing_controls_cannot_qualify(self):
        row = dict(documentID='doc', slot=0, candidate=self.case, semanticReview=self.review, outcome='surfaced')
        event = dict(batchID='doc:0', attempt=1, outcome='accepted', review=self.review, candidateDigest=self.review['candidateDigest'])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            self.write_run(path, [event])
            result = semantic_metrics(path, [row])
            self.assertTrue(result['semantic_review_gate_passed'])
            self.assertFalse(result['semantic_controls_gate_passed'])
            self.write_run(path, [])
            with self.assertRaises((AssertionError, IndexError)): semantic_metrics(path, [row])

    def test_provider_failure_blocks_gate_and_attempts_remain_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            self.write_run(path, [dict(batchID='doc:0', attempt=1, outcome='review_error')])
            result = semantic_metrics(path, [dict(documentID='doc', slot=0, outcome='semantic_review_error')])
            self.assertFalse(result['semantic_review_gate_passed'])
            self.assertEqual(result['semantic_review_errors'], 1)
            self.write_run(path, [dict(batchID='doc:0', attempt=i, outcome='rejected') for i in range(1, 5)])
            with self.assertRaises(AssertionError): semantic_metrics(path, [])

    def test_sibling_context_cannot_be_swapped(self):
        review = dict(self.review, reviewedQuestions=['unrelated-context'])
        row = dict(documentID='doc', slot=0, candidate=self.case, semanticReview=review, outcome='surfaced')
        event = dict(batchID='doc:0', attempt=1, outcome='accepted', review=review, candidateDigest=review['candidateDigest'])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory); self.write_run(path, [event])
            with self.assertRaises(AssertionError): semantic_metrics(path, [row])


if __name__ == '__main__':
    unittest.main()
