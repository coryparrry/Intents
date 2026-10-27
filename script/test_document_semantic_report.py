import copy
import json
import tempfile
import unittest
from pathlib import Path
from document_semantic_report import candidate_digest, connection_digest, validate_review, validate_acceptance_controls, semantic_metrics


class SemanticEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.connection = dict(id='connection', modelID='reviewer', kind='customCompatible',
                               baseURL='https://example.invalid/v1', providerOrder=[],
                               capabilities=dict(structuredOutputs=True), generationPolicy='portable')
        self.case = dict(prompt={'format': 'document-case-v1', 'text': 'When does autosave not run?'},
                         expected='In read-only mode.', criteriaOverride=['Identifies read-only mode.'],
                         documentEvidence=dict(passages=[dict(id='p', text='No autosave in read-only mode.')]))
        checks = [dict(criterionIndex=i, score=4, rationale='Source supports it') for i in range(1, 7)]
        question_checks = [dict(criterionIndex=i, score=4, rationale='Independently answerable and distinct') for i in range(1, 4)]
        self.review = dict(policyVersion='document-semantic-v6', candidateDigest=candidate_digest(self.case),
                           connectionID='connection', connectionDigest=connection_digest(self.connection),
                           modelID='reviewer', checks=checks, reviewedQuestions=[],
                           rawResponse=json.dumps(dict(requirements=checks)), questionChecks=question_checks,
                           questionRawResponse=json.dumps(dict(requirements=question_checks)))

    def test_reference_approval_cannot_replace_question_only_approval(self):
        for field in ['questionChecks', 'questionRawResponse']:
            changed = copy.deepcopy(self.review)
            changed.pop(field)
            with self.assertRaises((AssertionError, KeyError)):
                validate_review(changed, self.case, self.connection)
        changed = copy.deepcopy(self.review)
        changed['questionChecks'][0]['score'] = 2
        changed['questionRawResponse'] = json.dumps(dict(requirements=changed['questionChecks']))
        changed['checks'] = []
        changed['rawResponse'] = ''
        self.assertFalse(validate_review(changed, self.case, self.connection, False))
        with self.assertRaises(AssertionError):
            validate_review(changed, self.case, self.connection)

    def test_acceptance_is_bound_to_all_scoring_inputs(self):
        validate_review(self.review, self.case, self.connection)
        for field in ['prompt', 'expected', 'criteriaOverride', 'documentEvidence']:
            changed = copy.deepcopy(self.case)
            if field == 'prompt': changed[field]['text'] += ' changed'
            elif field == 'documentEvidence': changed[field]['passages'][0]['text'] += ' changed'
            elif field == 'criteriaOverride': changed[field][0] += ' changed'
            else: changed[field] += ' changed'
            with self.assertRaises(AssertionError): validate_review(self.review, changed, self.connection)

    def test_historical_controls_require_every_result_and_exact_question_history(self):
        case = copy.deepcopy(self.case)
        case['documentEvidence'].update(sourceDigest='source', citations=[dict(passageID='p', quote='No autosave')])
        review = dict(self.review, candidateDigest=candidate_digest(case))
        fixture = dict(sourceID='doc', question=case['prompt']['text'], reference=case['expected'],
                       citations=case['documentEvidence']['citations'], existingQuestions=[], accepted=True)
        contract = dict(sources=dict(doc=dict(passages=case['documentEvidence']['passages'], fileDigest='source')),
                        controls=[dict(fixture, id=str(i)) for i in range(10)])
        rows = [dict(id=str(i), candidate=case, review=copy.deepcopy(review), expectedAcceptance=True, correct=True) for i in range(10)]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'acceptance-control-contract.json').write_text(json.dumps(contract))
            result = path / 'acceptance-controls.jsonl'
            result.write_text('\n'.join(map(json.dumps, rows)))
            validate_acceptance_controls(path, path, self.connection)
            negative_contract = copy.deepcopy(contract)
            negative_contract['controls'][0]['accepted'] = False
            (path / 'acceptance-control-contract.json').write_text(json.dumps(negative_contract))
            wrong_stage = copy.deepcopy(rows)
            wrong_stage[0]['expectedAcceptance'] = False
            wrong_stage[0]['review']['checks'][0]['score'] = 2
            wrong_stage[0]['review']['rawResponse'] = json.dumps(dict(requirements=wrong_stage[0]['review']['checks']))
            result.write_text('\n'.join(map(json.dumps, wrong_stage)))
            with self.assertRaises(AssertionError): validate_acceptance_controls(path, path, self.connection)
            (path / 'acceptance-control-contract.json').write_text(json.dumps(contract))
            result.write_text('\n'.join(map(json.dumps, rows[:-1])))
            with self.assertRaises(AssertionError): validate_acceptance_controls(path, path, self.connection)
            changed = copy.deepcopy(rows)
            changed[0]['review']['reviewedQuestions'] = ['wrong-context']
            result.write_text('\n'.join(map(json.dumps, changed)))
            with self.assertRaises(AssertionError): validate_acceptance_controls(path, path, self.connection)

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
