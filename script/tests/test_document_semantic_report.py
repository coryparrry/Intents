import copy
import json
import tempfile
import unittest
from pathlib import Path
from script.document_semantic_report import (
    candidate_digest, connection_digest, prompt_text, question_digests,
    validate_review, validate_acceptance_controls, semantic_metrics,
)


class SemanticEvidenceTests(unittest.TestCase):
    def setUp(self):
        """Prepare isolated synthetic evidence and temporary storage for each report regression."""
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
        """Require historical negatives to fail the question stage rather than relying on later reference rejection."""
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
        """Invalidate acceptance receipts when any field that changes the scoring contract is edited."""
        validate_review(self.review, self.case, self.connection)
        for field in ['prompt', 'expected', 'criteriaOverride', 'documentEvidence']:
            changed = copy.deepcopy(self.case)
            if field == 'prompt': changed[field]['text'] += ' changed'
            elif field == 'documentEvidence': changed[field]['passages'][0]['text'] += ' changed'
            elif field == 'criteriaOverride': changed[field][0] += ' changed'
            else: changed[field] += ' changed'
            with self.assertRaises(AssertionError): validate_review(self.review, changed, self.connection)

    def test_historical_controls_require_every_result_and_exact_question_history(self):
        """Require the complete frozen control set and its original prior-question context for historical qualification."""
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
        """Verify raw judge responses so stored acceptance flags cannot override what the judge actually returned."""
        changed = copy.deepcopy(self.review)
        changed['rawResponse'] = json.dumps(dict(requirements=[dict(c, score=2) for c in changed['checks']]))
        with self.assertRaises(AssertionError): validate_review(changed, self.case, self.connection)

    def test_raw_numbers_cannot_use_boolean_equivalence(self):
        """Validate raw numeric types before Python equality can equate booleans with integers."""
        for checks_key, raw_key in [('questionChecks', 'questionRawResponse'), ('checks', 'rawResponse')]:
            with self.subTest(stage=checks_key, field='criterionIndex'):
                review = copy.deepcopy(self.review)
                raw = json.loads(review[raw_key])
                raw['requirements'][0]['criterionIndex'] = True
                review[raw_key] = json.dumps(raw)
                with self.assertRaises(AssertionError):
                    validate_review(review, self.case, self.connection)
            with self.subTest(stage=checks_key, field='score'):
                review = copy.deepcopy(self.review)
                review[checks_key][0]['score'] = 1
                raw = copy.deepcopy(review[checks_key])
                raw[0]['score'] = True
                review[raw_key] = json.dumps(dict(requirements=raw))
                if checks_key == 'questionChecks':
                    review['checks'], review['rawResponse'] = [], ''
                with self.assertRaises(AssertionError):
                    validate_review(review, self.case, self.connection, False)

    def test_raw_and_retained_verdicts_require_text_and_bounded_raw_bytes(self):
        """Reject malformed rationale values and oversized UTF-8 verdicts before comparing fields."""
        for checks_key, raw_key in [('questionChecks', 'questionRawResponse'), ('checks', 'rawResponse')]:
            for rationale in [None, '   ']:
                with self.subTest(stage=checks_key, rationale_type=type(rationale).__name__):
                    review = copy.deepcopy(self.review)
                    review[checks_key][0]['rationale'] = rationale
                    review[raw_key] = json.dumps(dict(requirements=review[checks_key]))
                    with self.assertRaises(AssertionError):
                        validate_review(review, self.case, self.connection)
            review = copy.deepcopy(self.review)
            # Raw JSON may contain harmless whitespace, but the decoder still bounds its bytes.
            review[raw_key] += ' ' * 32_768
            with self.subTest(stage=checks_key, boundary='raw_utf8_bytes'), self.assertRaises(AssertionError):
                validate_review(review, self.case, self.connection)

    def test_combining_mark_rationales_do_not_use_a_scalar_length_cap(self):
        """Preserve receipts whose combining text exceeds Python length but fits retained raw bytes."""
        for checks_key, raw_key in [('questionChecks', 'questionRawResponse'), ('checks', 'rawResponse')]:
            review = copy.deepcopy(self.review)
            review[checks_key][0]['rationale'] = 'a\u0301' * 3_000
            review[raw_key] = json.dumps(dict(requirements=review[checks_key]), ensure_ascii=False)
            self.assertLess(len(review[raw_key].encode('utf-8')), 32_768)
            with self.subTest(stage=checks_key):
                self.assertTrue(validate_review(review, self.case, self.connection))

    def test_raw_integral_decimals_preserve_historical_receipt_compatibility(self):
        """Allow integral raw decimal numbers while retained checks continue to require integer types."""
        for checks_key, raw_key in [('questionChecks', 'questionRawResponse'), ('checks', 'rawResponse')]:
            review = copy.deepcopy(self.review)
            checks = copy.deepcopy(review[checks_key])
            for check in checks:
                check['criterionIndex'] = float(check['criterionIndex'])
                check['score'] = float(check['score'])
            review[raw_key] = json.dumps(dict(requirements=checks))
            with self.subTest(stage=checks_key, representation='raw'):
                self.assertTrue(validate_review(review, self.case, self.connection))
            review[checks_key] = checks
            with self.subTest(stage=checks_key, representation='retained'), self.assertRaises(AssertionError):
                validate_review(review, self.case, self.connection)
            for invalid in [1.5, float('inf'), float('nan')]:
                changed = copy.deepcopy(self.review)
                raw = json.loads(changed[raw_key])
                raw['requirements'][0]['score'] = invalid
                changed[raw_key] = json.dumps(raw)
                with self.subTest(stage=checks_key, invalid=invalid), self.assertRaises(AssertionError):
                    validate_review(changed, self.case, self.connection)

    def test_every_check_must_fully_pass(self):
        """Reject aggregate approval when even one independent requirement is less than fully satisfied."""
        changed = copy.deepcopy(self.review)
        changed['checks'][2]['score'] = 3
        changed['rawResponse'] = json.dumps(dict(requirements=changed['checks']))
        with self.assertRaises(AssertionError): validate_review(changed, self.case, self.connection)
        self.assertFalse(validate_review(changed, self.case, self.connection, False))

    def test_duplicate_indexes_and_wrong_endpoint_are_rejected(self):
        """Bind receipts to a uniquely indexed verdict from the explicitly configured judge endpoint."""
        changed = copy.deepcopy(self.review)
        changed['checks'][-1]['criterionIndex'] = 1
        changed['rawResponse'] = json.dumps(dict(requirements=changed['checks']))
        with self.assertRaises(AssertionError): validate_review(changed, self.case, self.connection)
        with self.assertRaises(AssertionError):
            validate_review(self.review, self.case, dict(self.connection, baseURL='https://other.invalid/v1'))
        for checks, raw in [('questionChecks', 'questionRawResponse'), ('checks', 'rawResponse')]:
            changed = copy.deepcopy(self.review)
            changed[checks][0]['criterionIndex'] = True
            changed[raw] = json.dumps(dict(requirements=changed[checks]))
            with self.subTest(checks=checks), self.assertRaises(AssertionError):
                validate_review(changed, self.case, self.connection)

    def write_run(self, path, events):
        """Write synthetic attempts and receipts for report-gate regression checks."""
        (path / 'runtime.json').write_text(json.dumps(dict(judgeConfiguration=self.connection)))
        (path / 'semantic-attempts.jsonl').write_text('\n'.join(json.dumps(e) for e in events))

    def event(self, outcome='accepted', attempt=1, batch_id='doc:0', case=None, review=None):
        """Create the retained event fields emitted by each production pipeline branch."""
        case = self.case if case is None else case
        event = dict(batchID=batch_id, attempt=attempt, outcome=outcome)
        if outcome == 'unsupported_or_duplicate':
            return event
        event.update(question=prompt_text(case), answer=case['expected'], criteria=case['criteriaOverride'])
        if outcome == 'validation_rejected':
            return dict(event, supportingQuotes=[], issue='A supporting quote is missing.')
        event['candidateDigest'] = candidate_digest(case)
        if outcome == 'review_error':
            return dict(event, issue='The provider failed before returning a verdict.')
        if review is None:
            review = copy.deepcopy(self.review)
            review['candidateDigest'] = candidate_digest(case)
            if outcome == 'rejected':
                review['questionChecks'][0]['score'] = 2
                review['questionRawResponse'] = json.dumps(dict(requirements=review['questionChecks']))
                review['checks'], review['rawResponse'] = [], ''
        event['review'] = review
        return event

    def assert_ledger_rejected(self, rows, events):
        """Require a malformed isolated ledger to fail before it can emit passing metrics."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            self.write_run(path, events)
            with self.assertRaises((AssertionError, KeyError)):
                semantic_metrics(path, rows)

    def test_missing_receipt_cannot_surface_and_missing_controls_cannot_qualify(self):
        """Keep unreviewed candidates out of surfaced results and incomplete controls out of qualification."""
        row = dict(documentID='doc', slot=0, candidate=self.case, semanticReview=self.review, outcome='surfaced')
        event = self.event()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            self.write_run(path, [event])
            result = semantic_metrics(path, [row])
            self.assertTrue(result['semantic_review_gate_passed'])
            self.assertFalse(result['semantic_controls_gate_passed'])
            self.write_run(path, [])
            with self.assertRaises((AssertionError, IndexError)): semantic_metrics(path, [row])

    def test_provider_failure_blocks_gate_and_attempts_remain_bounded(self):
        """Treat provider errors as failed admission without permitting unlimited correction attempts."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            self.write_run(path, [self.event('review_error')])
            result = semantic_metrics(path, [dict(documentID='doc', slot=0, outcome='semantic_review_error')])
            self.assertFalse(result['semantic_review_gate_passed'])
            self.assertEqual(result['semantic_review_errors'], 1)
            self.write_run(path, [self.event('rejected', attempt=i) for i in range(1, 5)])
            with self.assertRaises(AssertionError):
                semantic_metrics(path, [dict(documentID='doc', slot=0, outcome='semantic_rejection_or_unsupported')])

    def test_sibling_context_cannot_be_swapped(self):
        """Reject a receipt whose retained source belongs to a different candidate or sibling context."""
        review = dict(self.review, reviewedQuestions=['unrelated-context'])
        row = dict(documentID='doc', slot=0, candidate=self.case, semanticReview=review, outcome='surfaced')
        event = self.event(review=review)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory); self.write_run(path, [event])
            with self.assertRaises(AssertionError): semantic_metrics(path, [row])

    def test_orphan_missing_and_duplicate_batches_cannot_qualify(self):
        """Match every semantic batch to exactly one outer attempt, including omitted drafts."""
        omitted = dict(documentID='doc', slot=0, outcome='semantic_rejection_or_unsupported')
        self.assert_ledger_rejected([omitted], [])
        self.assert_ledger_rejected([], [self.event('unsupported_or_duplicate')])
        self.assert_ledger_rejected([omitted, omitted], [self.event('unsupported_or_duplicate')])

    def test_every_rejected_receipt_is_validated_before_regeneration(self):
        """Reject stale fingerprints, forged verdicts, and wrong judges in earlier rejected drafts."""
        row = dict(documentID='doc', slot=0, candidate=self.case, semanticReview=self.review, outcome='surfaced')
        for mutation in ['fingerprint', 'raw', 'judge', 'verdict', 'history', 'policy']:
            with self.subTest(mutation=mutation):
                rejected = self.event('rejected')
                if mutation == 'fingerprint':
                    rejected['candidateDigest'] = '0' * 64
                elif mutation == 'raw':
                    rejected['review']['questionRawResponse'] = json.dumps(dict(requirements=self.review['questionChecks']))
                elif mutation == 'judge':
                    rejected['review']['connectionDigest'] = 'wrong-endpoint'
                elif mutation == 'verdict':
                    rejected['review'] = self.review
                elif mutation == 'history':
                    rejected['review']['reviewedQuestions'] = ['wrong-sibling']
                else:
                    rejected['review']['policyVersion'] = 'obsolete-policy'
                self.assert_ledger_rejected([row], [rejected, self.event(attempt=2)])

    def test_rejections_and_acceptance_share_current_sibling_history(self):
        """Bind all regeneration receipts to previously surfaced questions in that document."""
        second = copy.deepcopy(self.case)
        second['prompt']['text'] = 'Which document mode disables autosave?'
        review = dict(self.review, candidateDigest=candidate_digest(second),
                      reviewedQuestions=question_digests([prompt_text(self.case)]))
        rejected = self.event('rejected', batch_id='doc:1', case=second)
        rejected['review']['reviewedQuestions'] = review['reviewedQuestions']
        rows = [dict(documentID='doc', slot=0, candidate=self.case, semanticReview=self.review, outcome='surfaced'),
                dict(documentID='doc', slot=1, candidate=second, semanticReview=review, outcome='surfaced')]
        events = [self.event(), rejected, self.event(attempt=2, batch_id='doc:1', case=second, review=review)]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            self.write_run(path, events)
            self.assertTrue(semantic_metrics(path, rows)['semantic_review_gate_passed'])
        rejected['review']['reviewedQuestions'] = []
        self.assert_ledger_rejected(rows, events)

    def test_pipeline_cannot_continue_after_terminal_event(self):
        """Prevent accepted, unsupported, or failed-review events from being followed by another attempt."""
        row = dict(documentID='doc', slot=0, candidate=self.case, semanticReview=self.review, outcome='surfaced')
        for outcome in ['accepted', 'unsupported_or_duplicate', 'review_error']:
            with self.subTest(outcome=outcome):
                self.assert_ledger_rejected([row], [self.event(outcome), self.event(attempt=2)])
        for index in [0, 2, True]:
            with self.subTest(index=index):
                self.assert_ledger_rejected([row], [self.event(attempt=index)])

    def test_outer_omission_outcome_requires_matching_terminal_batch(self):
        """Distinguish exhausted rejection, unsupported input, reviewer errors, and post-review omissions."""
        for outcome, event in [
            ('semantic_rejection_or_unsupported', self.event('rejected')),
            ('semantic_rejection_or_unsupported', self.event()),
            ('semantic_review_error', self.event('unsupported_or_duplicate')),
            ('duplicate', self.event('unsupported_or_duplicate')),
            ('suite_budget_rejection', self.event('unsupported_or_duplicate')),
            ('unknown_outcome', self.event('unsupported_or_duplicate')),
        ]:
            with self.subTest(outcome=outcome, terminal=event['outcome']):
                self.assert_ledger_rejected([dict(documentID='doc', slot=0, outcome=outcome)], [event])
        self.assert_ledger_rejected([dict(documentID='doc', slot=0, outcome='surfaced')], [self.event()])

    def test_valid_omissions_and_partial_generator_failures_remain_reportable(self):
        """Preserve each real pipeline stop and failures before or between semantic attempts."""
        cases = [
            ('semantic_rejection_or_unsupported', [self.event('unsupported_or_duplicate')], None),
            ('semantic_rejection_or_unsupported', [self.event('rejected', attempt=i) for i in range(1, 4)], None),
            ('semantic_rejection_or_unsupported', [self.event('validation_rejected', attempt=i) for i in range(1, 4)], None),
            ('duplicate', [self.event()], self.review),
            ('suite_budget_rejection', [self.event()], self.review),
            ('runtime_failure', [], None),
            ('runtime_failure', [self.event('validation_rejected')], None),
            ('runtime_failure', [self.event('rejected')], None),
        ]
        for outcome, events, review in cases:
            with self.subTest(outcome=outcome, events=len(events)):
                with tempfile.TemporaryDirectory() as directory:
                    path = Path(directory)
                    self.write_run(path, events)
                    row = dict(documentID='doc', slot=0, outcome=outcome,
                               semanticReview=review, issue='The generator stopped.')
                    result = semantic_metrics(path, [row])
                    self.assertTrue(result['semantic_review_gate_passed'])
                    self.assertEqual(result['semantic_attempts'], len(events))

    def test_surfaced_event_retains_the_same_scoring_text(self):
        """Reject accepted-event question, answer, or rubric fields substituted after review."""
        row = dict(documentID='doc', slot=0, candidate=self.case, semanticReview=self.review, outcome='surfaced')
        for field in ['question', 'answer', 'criteria']:
            event = self.event()
            event[field] = ['changed'] if field == 'criteria' else 'changed'
            with self.subTest(field=field):
                self.assert_ledger_rejected([row], [event])

    def test_structural_and_provider_failures_cannot_contain_semantic_verdicts(self):
        """Keep pre-review failures separate from judge verdicts and require their retained reasons."""
        for outcome, outer in [('validation_rejected', 'runtime_failure'), ('review_error', 'semantic_review_error')]:
            event = self.event(outcome)
            row = dict(documentID='doc', slot=0, outcome=outer, issue='Failed')
            event['review'] = self.review
            self.assert_ledger_rejected([row], [event])
            event.pop('review')
            event.pop('issue')
            self.assert_ledger_rejected([row], [event])


if __name__ == '__main__':
    unittest.main()
