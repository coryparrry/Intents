"""Fail-closed evidence checks for per-draft semantic admission."""
import hashlib
import json
from collections import defaultdict


def prompt_text(case):
    value = case['prompt']
    return value['text'] if isinstance(value, dict) else value


def candidate_digest(case):
    evidence = {k: v for k, v in case['documentEvidence'].items() if k != 'reviewedDigest'}
    payload = dict(prompt=prompt_text(case), expected=case['expected'],
                   criteria=case['criteriaOverride'], evidence=evidence)
    # Match CanonicalJSON's compact sorted JSONEncoder output, including escaped slashes.
    encoded = json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(',', ':')).replace('/', '\\/')
    return hashlib.sha256(encoded.encode()).hexdigest()


def question_digests(questions):
    return sorted({hashlib.sha256(q.encode()).hexdigest() for q in questions})


def connection_digest(connection):
    capabilities = connection['capabilities']
    fields = [connection['kind'], connection['baseURL'], connection['modelID'],
              '\x1f'.join(connection.get('providerOrder', [])),
              'structured' if capabilities.get('structuredOutputs') else 'unstructured',
              'multimodal' if capabilities.get('multimodal') else 'text', connection['generationPolicy']]
    framed = '|'.join(f"{len(value.encode())}:{value}" for value in fields)
    return hashlib.sha256(framed.encode()).hexdigest()


def validate_review(review, case, connection, required_acceptance=True):
    assert review['policyVersion'] == 'document-semantic-v5', 'Wrong semantic policy'
    assert review['candidateDigest'] == candidate_digest(case), 'Stale semantic receipt'
    assert review['connectionID'].lower() == connection['id'].lower(), 'Wrong semantic connection'
    assert review['modelID'] == connection['modelID'], 'Wrong semantic model'
    assert review['connectionDigest'] == connection_digest(connection), 'Semantic endpoint or policy changed'
    checks = sorted(review['checks'], key=lambda c: c['criterionIndex'])
    assert len(checks) == 6 and [c['criterionIndex'] for c in checks] == list(range(1, 7)), 'Incomplete semantic verdict'
    assert all(type(c['score']) is int and 1 <= c['score'] <= 4 and c['rationale'].strip() for c in checks), 'Invalid semantic checks'
    raw = json.loads(review['rawResponse'])
    assert sorted(raw['requirements'], key=lambda c: c['criterionIndex']) == checks, 'Semantic raw verdict mismatch'
    accepted = all(c['score'] == 4 for c in checks)
    assert accepted == required_acceptance, 'Semantic verdict disagrees with expected outcome'
    return accepted


def semantic_metrics(run, attempts, controls_path=None):
    result = dict(semantic_review_required=True, semantic_review_gate_passed=False,
                  semantic_controls_gate_passed=False)
    connection = json.loads((run / 'runtime.json').read_text())['judgeConfiguration']
    events = [json.loads(line) for line in (run / 'semantic-attempts.jsonl').read_text().splitlines() if line.strip()]
    batches = defaultdict(list)
    for event in events:
        batches[event['batchID']].append(event)
    for batch in batches.values():
        assert [e['attempt'] for e in batch] == list(range(1, len(batch) + 1)) and len(batch) <= 3, 'Invalid regeneration ledger'
    previous = defaultdict(list)
    for row in attempts:
        case = row.get('candidate')
        if case is None:
            continue
        review = row['semanticReview']
        validate_review(review, case, connection)
        assert review.get('reviewedQuestions', []) == question_digests(previous[row['documentID']]), 'Wrong sibling review context'
        batch = batches[f"{row['documentID']}:{row['slot']}"]
        assert batch[-1]['outcome'] == 'accepted' and batch[-1]['review'] == review, 'No accepted semantic attempt for surfaced draft'
        assert batch[-1]['candidateDigest'] == review['candidateDigest'], 'Mismatched semantic attempt'
        previous[row['documentID']].append(prompt_text(case))
    error_batches = {e['batchID'] for e in events if e['outcome'] == 'review_error'}
    error_batches.update(f"{r['documentID']}:{r['slot']}" for r in attempts if r['outcome'] == 'semantic_review_error')
    errors = len(error_batches)
    result.update(semantic_attempts=len(events), semantic_rejections=sum(e['outcome'] == 'rejected' for e in events),
                  structural_rejections=sum(e['outcome'] == 'validation_rejected' for e in events),
                  semantic_regenerated_acceptances=sum(b[-1]['outcome'] == 'accepted' and len(b) > 1 for b in batches.values()),
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
            validate_review(row['review'], fixture['candidate'], connection, fixture['accepted'])
        result['semantic_controls_gate_passed'] = (controls_path / 'exit-code.txt').read_text().strip() == '0'
    return result
