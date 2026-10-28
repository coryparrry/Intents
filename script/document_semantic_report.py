"""Fail-closed evidence checks for per-draft semantic admission."""
import hashlib
import json
import math
from collections import defaultdict


def prompt_text(case):
    """Read question text from current or versioned archived prompt representations."""
    value = case['prompt']
    return value['text'] if isinstance(value, dict) else value


def candidate_digest(case):
    """Reproduce the canonical scoring-input digest without including the previous acceptance receipt."""
    evidence = {k: v for k, v in case['documentEvidence'].items() if k != 'reviewedDigest'}
    payload = dict(prompt=prompt_text(case), expected=case['expected'],
                   criteria=case['criteriaOverride'], evidence=evidence)
    # Match CanonicalJSON's compact sorted JSONEncoder output, including escaped slashes.
    encoded = json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(',', ':')).replace('/', '\\/')
    return hashlib.sha256(encoded.encode()).hexdigest()


def question_digests(questions):
    """Return sorted unique SHA-256 fingerprints for the exact prior-question history."""
    return sorted({hashlib.sha256(q.encode()).hexdigest() for q in questions})


def connection_digest(connection):
    """Reproduce the judge endpoint and capability fingerprint used to bind review receipts."""
    capabilities = connection['capabilities']
    fields = [connection['kind'], connection['baseURL'], connection['modelID'],
              '\x1f'.join(connection.get('providerOrder', [])),
              'structured' if capabilities.get('structuredOutputs') else 'unstructured',
              'multimodal' if capabilities.get('multimodal') else 'text', connection['generationPolicy']]
    framed = '|'.join(f"{len(value.encode())}:{value}" for value in fields)
    return hashlib.sha256(framed.encode()).hexdigest()


def validate_review(review, case, connection, required_acceptance=True):
    """Require matching policy, candidate, judge, raw verdicts, and complete per-requirement acceptance evidence."""
    return validate_receipt(review, candidate_digest(case), connection, required_acceptance)


def integer_number(value, allow_integral_floats):
    """Accept exact integers and optionally finite integral raw numbers, while excluding booleans."""
    return type(value) is int or (allow_integral_floats and type(value) is float
                                 and math.isfinite(value) and value.is_integer())


def validate_checks(checks, count, allow_integral_floats=False):
    """Require complete numeric checks and explanatory text without approximating Swift grapheme counts."""
    assert isinstance(checks, list) and len(checks) == count, 'Incomplete semantic verdict'
    assert all(isinstance(c, dict) and integer_number(c.get('criterionIndex'), allow_integral_floats)
               and integer_number(c.get('score'), allow_integral_floats) and 1 <= c['score'] <= 4
               and isinstance(c.get('rationale'), str) and c['rationale'].strip()
               for c in checks), 'Invalid semantic checks'
    checks = sorted(checks, key=lambda c: c['criterionIndex'])
    assert [c['criterionIndex'] for c in checks] == list(range(1, count + 1)), 'Incomplete semantic verdict'
    return checks


def raw_checks(raw, count):
    """Decode bounded raw verdicts, preserving integral decimal compatibility without Boolean equality."""
    assert isinstance(raw, str) and len(raw.encode('utf-8')) <= 32_768, 'Oversized semantic verdict'
    return validate_checks(json.loads(raw)['requirements'], count, allow_integral_floats=True)


def validate_receipt(review, digest, connection, required_acceptance=True):
    """Validate a receipt against a retained candidate fingerprint and the exact judge verdicts.

    Historical rejected-attempt records retain the fingerprint but not complete candidate
    evidence. Their receipt can be checked against that fingerprint; only a retained full
    candidate, through validate_review, permits recomputing its scoring-input digest.
    """
    assert isinstance(digest, str) and len(digest) == 64 and all(c in '0123456789abcdef' for c in digest), 'Invalid candidate fingerprint'
    assert review['policyVersion'] == 'document-semantic-v6', 'Wrong semantic policy'
    assert review['candidateDigest'] == digest, 'Stale semantic receipt'
    assert review['connectionID'].lower() == connection['id'].lower(), 'Wrong semantic connection'
    assert review['modelID'] == connection['modelID'], 'Wrong semantic model'
    assert review['connectionDigest'] == connection_digest(connection), 'Semantic endpoint or policy changed'
    question_checks = validate_checks(review.get('questionChecks', []), 3)
    assert raw_checks(review['questionRawResponse'], 3) == question_checks, 'Question raw verdict mismatch'
    question_accepted = all(c['score'] == 4 for c in question_checks)
    checks = review['checks']
    assert isinstance(checks, list), 'Invalid semantic checks'
    if not question_accepted:
        assert not checks and not review['rawResponse'], 'Rejected question reached reference review'
        assert not required_acceptance, 'Question-only verdict rejected the draft'
        return False
    checks = validate_checks(checks, 6)
    assert raw_checks(review['rawResponse'], 6) == checks, 'Semantic raw verdict mismatch'
    accepted = all(c['score'] == 4 for c in checks)
    assert accepted == required_acceptance, 'Semantic verdict disagrees with expected outcome'
    return accepted


def validate_batch(batch, row, connection, existing_questions):
    """Reconcile one bounded pipeline history with its outer generation outcome.

    Generator failures can occur before recording an event or after an earlier
    rejection. Such partial runtime-failure batches remain visible without being
    misclassified as semantic rejection, acceptance, or reviewer failure.
    """
    assert len(batch) <= 3 and all(type(e['attempt']) is int for e in batch), 'Invalid regeneration ledger'
    assert [e['attempt'] for e in batch] == list(range(1, len(batch) + 1)), 'Invalid regeneration ledger'
    continuation = {'rejected', 'validation_rejected'}
    terminal = {'accepted', 'unsupported_or_duplicate', 'review_error'}
    for index, event in enumerate(batch):
        outcome = event['outcome']
        assert outcome in continuation | terminal, 'Unknown semantic attempt outcome'
        assert index == len(batch) - 1 or outcome in continuation, 'Semantic attempt continued after termination'
        if outcome == 'unsupported_or_duplicate':
            assert all(event.get(field) is None for field in ['question', 'answer', 'criteria', 'candidateDigest', 'review']), 'Unsupported attempt retained a candidate'
            continue
        assert isinstance(event.get('question'), str) and isinstance(event.get('answer'), str), 'Missing semantic candidate text'
        assert isinstance(event.get('criteria'), list) and all(isinstance(c, str) for c in event['criteria']), 'Missing semantic candidate criteria'
        if outcome == 'validation_rejected':
            assert isinstance(event.get('supportingQuotes'), list) and all(isinstance(q, str) for q in event['supportingQuotes']), 'Missing rejected supporting quotes'
            assert event.get('candidateDigest') is None and event.get('review') is None, 'Structurally rejected attempt reached semantic review'
        elif outcome == 'review_error':
            digest = event.get('candidateDigest')
            assert isinstance(digest, str) and len(digest) == 64 and all(c in '0123456789abcdef' for c in digest), 'Invalid candidate fingerprint'
            assert event.get('review') is None, 'Failed reviewer retained a verdict'
        else:
            review = event['review']
            validate_receipt(review, event['candidateDigest'], connection, outcome == 'accepted')
            assert review.get('reviewedQuestions', []) == question_digests(existing_questions), 'Wrong sibling review context'
        if outcome in {'validation_rejected', 'review_error'}:
            assert isinstance(event.get('issue'), str) and event['issue'].strip(), 'Missing semantic failure reason'
    outcome = row['outcome']
    case = row.get('candidate')
    review = row.get('semanticReview')
    assert (case is not None) == (outcome == 'surfaced'), 'Candidate and generation outcome disagree'
    last = batch[-1]['outcome'] if batch else None
    if outcome in {'surfaced', 'duplicate', 'suite_budget_rejection'}:
        assert last == 'accepted' and batch[-1]['review'] == review, 'No accepted semantic attempt for generation outcome'
        if case is not None:
            validate_review(review, case, connection)
            event = batch[-1]
            assert event['question'] == prompt_text(case) and event['answer'] == case['expected'] and event['criteria'] == case['criteriaOverride'], 'Semantic attempt candidate differs from surfaced draft'
    else:
        assert review is None, 'Unapproved generation outcome retained a verdict'
        if outcome == 'semantic_rejection_or_unsupported':
            assert last == 'unsupported_or_duplicate' or (len(batch) == 3 and last in continuation), 'Incomplete semantic rejection batch'
        elif outcome == 'semantic_review_error':
            assert last == 'review_error', 'Missing semantic reviewer failure'
        elif outcome == 'runtime_failure':
            assert isinstance(row.get('issue'), str) and row['issue'].strip(), 'Missing generation failure reason'
        else:
            raise AssertionError('Unknown generation outcome')


def validate_acceptance_controls(run, controls_path, connection):
    """Verify every frozen historical control and its original question history, including the rejection stage."""
    contract = json.loads((controls_path / 'acceptance-control-contract.json').read_text())
    assert contract == json.loads((run / 'acceptance-control-contract.json').read_text()), 'Frozen acceptance controls changed'
    fixtures = contract['controls']
    rows = [json.loads(line) for line in (controls_path / 'acceptance-controls.jsonl').read_text().splitlines() if line.strip()]
    assert len(rows) == len(fixtures) == 10, 'Incomplete historical acceptance controls'
    assert len({r['id'] for r in rows}) == len(rows), 'Duplicate acceptance controls'
    for fixture, row in zip(fixtures, rows):
        assert row['id'] == fixture['id'] and row['correct'] and row['expectedAcceptance'] == fixture['accepted'], 'Wrong acceptance-control result'
        case = row['candidate']
        source = contract['sources'][fixture['sourceID']]
        evidence = case['documentEvidence']
        assert prompt_text(case) == fixture['question'] and case['expected'] == fixture['reference'], 'Acceptance candidate changed'
        assert evidence['passages'] == source['passages'] and evidence['sourceDigest'] == source['fileDigest'], 'Acceptance source changed'
        assert [dict(passageID=c['passageID'], quote=c['quote']) for c in evidence['citations']] == fixture['citations'], 'Acceptance citations changed'
        assert row['review'].get('reviewedQuestions', []) == question_digests(fixture['existingQuestions']), 'Acceptance sibling context changed'
        validate_review(row['review'], case, connection, fixture['accepted'])
        if not fixture['accepted']:
            assert any(c['score'] < 4 for c in row['review']['questionChecks']), 'Historical negative passed question review'
            assert not row['review']['checks'] and not row['review']['rawResponse'], 'Historical negative reached reference review'


def semantic_metrics(run, attempts, controls_path=None):
    """Validate review receipts and control evidence before reporting whether semantic admission qualified."""
    result = dict(semantic_review_required=True, semantic_review_gate_passed=False,
                  semantic_controls_gate_passed=False)
    connection = json.loads((run / 'runtime.json').read_text())['judgeConfiguration']
    events = [json.loads(line) for line in (run / 'semantic-attempts.jsonl').read_text().splitlines() if line.strip()]
    batches = defaultdict(list)
    for event in events:
        batches[event['batchID']].append(event)
    identities = [f"{row['documentID']}:{row['slot']}" for row in attempts]
    assert len(set(identities)) == len(identities), 'Duplicate generation attempts'
    assert set(batches) <= set(identities), 'Orphan semantic batch'
    previous = defaultdict(list)
    for row in attempts:
        batch = batches[f"{row['documentID']}:{row['slot']}"]
        validate_batch(batch, row, connection, previous[row['documentID']])
        if case := row.get('candidate'):
            previous[row['documentID']].append(prompt_text(case))
    error_batches = {e['batchID'] for e in events if e['outcome'] == 'review_error'}
    error_batches.update(f"{r['documentID']}:{r['slot']}" for r in attempts if r['outcome'] == 'semantic_review_error')
    errors = len(error_batches)
    result.update(semantic_attempts=len(events), semantic_rejections=sum(e['outcome'] == 'rejected' for e in events),
                  structural_rejections=sum(e['outcome'] == 'validation_rejected' for e in events),
                  semantic_regenerated_acceptances=sum(bool(b) and b[-1]['outcome'] == 'accepted' and len(b) > 1 for b in batches.values()),
                  semantic_review_errors=errors, semantic_review_gate_passed=errors == 0)
    if controls_path:
        for name in ['runtime.json', 'judge-source-hashes.json']:
            assert json.loads((run / name).read_text()) == json.loads((controls_path / name).read_text()), 'Semantic control identity mismatch'
        assert (run / 'semantic-reviewer.swift').read_bytes() == (controls_path / 'semantic-reviewer.swift').read_bytes(), 'Semantic policy source mismatch'
        fixtures = json.loads((controls_path / 'input.json').read_text())
        assert fixtures == json.loads((run / 'semantic-control-contract.json').read_text()), 'Frozen semantic controls changed'
        rows = [json.loads(line) for line in (controls_path / 'semantic-controls.jsonl').read_text().splitlines() if line.strip()]
        assert len(rows) == len(fixtures) == 22, 'Incomplete frozen semantic controls'
        assert len({r['id'] for r in rows}) == len(rows), 'Duplicate semantic controls'
        for fixture, row in zip(fixtures, rows):
            assert row['id'] == fixture['id'] and row['correct'] and row['expectedAcceptance'] == fixture['accepted']
            assert row['review'].get('reviewedQuestions', []) == [], 'Semantic control sibling context changed'
            validate_review(row['review'], fixture['candidate'], connection, fixture['accepted'])
        validate_acceptance_controls(run, controls_path, connection)
        result['semantic_controls_gate_passed'] = (controls_path / 'exit-code.txt').read_text().strip() == '0'
    return result
