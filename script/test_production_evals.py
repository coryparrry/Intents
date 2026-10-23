#!/usr/bin/env python3
"""Real-process CLI protocol checks. Run after swift build --product intents-evals."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path('.build/debug/intents-evals').resolve()
root = Path(tempfile.mkdtemp(prefix='intents-production-cli-'))
store = root / 'store'
assertions = 0


def check(condition, message):
    global assertions
    assert condition, message
    assertions += 1


def call(command, *arguments, expected=0):
    result = subprocess.run([str(binary), command, '--storage', str(store), *map(str, arguments)], capture_output=True, text=True, timeout=30)
    check(result.returncode == expected, f'{command}: exit {result.returncode}, expected {expected}; {result.stderr}')
    return json.loads(result.stdout) if result.stdout.strip() else None


def check_worker_limit_case(name, first_count, cost_cap=None, explicit_job=False):
    counter = root / f'{name}-calls.jsonl'
    program = root / f'{name}-worker.py'
    program.write_text('#!/usr/bin/python3\nimport json,sys\n'
                       'request=json.load(sys.stdin)\n'
                       f'with open({str(counter)!r}, "a") as output:\n'
                       ' output.write(json.dumps({"jobID":request["jobID"],"slot":request["slot"]})+"\\n")\n'
                       'print(json.dumps({"requestID":request["requestID"],"outcome":"passed",'
                       '"output":"fixture","latencyMilliseconds":0,"cost":1,"retryable":False}))\n')
    program.chmod(0o700)

    def dataset(label, count):
        path = root / f'{name}-{label}.jsonl'
        path.write_text(''.join(json.dumps({'id': str(i), 'prompt': 'fixture'}) + '\n' for i in range(count)))
        return call('import', '--file', path, '--name', f'{name}-{label}', '--version', '1')['revision']

    first_dataset, second_dataset = dataset('first', first_count), dataset('second', 2)
    cap = ('--max-cost', cost_cap, '--cost-per-attempt', 1) if cost_cap is not None else ()
    first = call('job', '--dataset', first_dataset, '--name', f'{name}-first', '--executor', program,
                 '--safety', 'inference', *cap)
    second = call('job', '--dataset', second_dataset, '--name', f'{name}-second', '--executor', program,
                  '--safety', 'inference')
    check(first['createdAt'] < second['createdAt'], f'{name}: fixture job order is deterministic')
    selection = ('--job', first['id']) if explicit_job else ()
    call('worker', '--worker-id', 'cli-fixture', '--executor', program, '--descriptor', descriptor,
         '--limit', 2, *selection, expected=30 if explicit_job else 0)
    completed = [len(call('results', '--job', job['id'])) for job in (first, second)]
    expected = [1, 0] if explicit_job else [0, 2] if cost_cap is not None and cost_cap < 1 else [1, 1]
    check(completed == expected, f'{name}: committed {completed}, expected {expected} under --limit 2')
    calls = len(counter.read_text().splitlines()) if counter.exists() else 0
    check(calls == sum(expected), f'{name}: executor calls {calls}, expected {sum(expected)}')


try:
    data = root / 'examples.jsonl'
    data.write_text('\n'.join(json.dumps({'id': str(i), 'sourceID': str(i), 'prompt': 'input', 'expected': 'output', 'capturedOutput': 'original', 'metadata': {'locale': 'en_GB'}}) for i in range(6)) + '\n')
    dataset = call('import', '--file', data, '--name', 'CLI fixture', '--version', 'v1')
    call('import', '--file', data, '--name', 'Production', '--version', 'v1', '--production-data', expected=30)
    call('datasets', '--unknown-option', 'x', expected=30)
    call('job', '--dataset', dataset['revision'], '--name', 'Ambiguous', '--native', '--captured', expected=30)
    programs = []
    for index in range(2):
        program = root / f'worker-{index}.py'
        program.write_text('''#!/usr/bin/python3
import json,sys,time
time.sleep(0.15)
r=json.load(sys.stdin)
print(json.dumps({"requestID":r["requestID"],"outcome":"passed","output":"output-%s","latencyMilliseconds":10,"cost":0,"retryable":False}))
''' % index)
        program.chmod(0o700)
        programs.append(program)
    descriptor = root / 'worker.json'
    descriptor.write_text(json.dumps({'id': 'cli-fixture', 'name': 'CLI fixture', 'platform': 'macOS', 'operatingSystem': 'fixture', 'hardware': 'fixture', 'locale': 'en_GB', 'model': 'fixture', 'lastSeen': 0}))
    first = call('job', '--dataset', dataset['revision'], '--name', 'First', '--executor', programs[0], '--safety', 'inference')
    second = call('job', '--dataset', dataset['revision'], '--name', 'Second', '--executor', programs[1], '--safety', 'inference')
    call('worker', '--worker-id', 'cli-fixture', '--executor', programs[0], '--descriptor', descriptor, '--limit', 2)
    check(call('report', '--job', first['id'], expected=20)['completed'] == 2, 'bounded worker saved two responses')
    check(call('report', '--job', second['id'], expected=20)['completed'] == 0, 'foreign executable job remains untouched')
    call('pause', '--job', first['id'])
    call('worker', '--worker-id', 'cli-fixture', '--executor', programs[0], '--descriptor', descriptor)
    check(call('report', '--job', first['id'], expected=20)['completed'] == 2, 'paused job unchanged')
    call('resume', '--job', first['id'])
    call('worker', '--worker-id', 'cli-fixture', '--executor', programs[0], '--descriptor', descriptor)
    check(call('report', '--job', first['id'])['completed'] == 6, 'resume completes remaining responses')
    call('worker', '--worker-id', 'cli-fixture', '--executor', programs[1], '--descriptor', descriptor, '--job', second['id'])
    check(call('report', '--job', second['id'])['exitCode'] == 0, 'second worker executes its own job')
    ready = call('report', '--job', first['id'])
    approval_args = ('--job', first['id'], '--revision', first['revision'], '--evidence', ready['evidenceRevision'], '--note', 'Reviewed exact CLI evidence')
    call('approve-baseline', *approval_args, expected=30)
    approved = call('approve-baseline', *approval_args, '--confirm')
    check(call('report', '--job', first['id'])['baselineApproval']['id'] == approved['id'], 'CLI approval binds saved evidence')
    call('pause', '--job', first['id'])
    call('resume', '--job', first['id'])
    call('approve-baseline', *approval_args, '--confirm', expected=30)
    check(call('report', '--job', first['id']).get('baselineApproval') is None, 'pause/resume invalidates old approval')
    captured = call('job', '--dataset', dataset['revision'], '--name', 'Original outputs', '--captured')
    call('worker', '--worker-id', 'capture-import', '--captured', '--job', captured['id'])
    record = call('results', '--job', captured['id'], '--limit', 1)[0]
    check(record['response']['output'] == 'original', 'captured output was not regenerated')
    call('review', '--job', captured['id'], '--slot', 0, '--reviewer', 'A', '--verdict', 'passed', '--note', 'Verified prompt and reference')
    call('review', '--job', captured['id'], '--slot', 0, '--reviewer', 'B', '--verdict', 'failed', '--note', 'Disagreement')
    check(call('report', '--job', captured['id'], expected=20)['counts']['uncertain'] == 1, 'disagreement blocks qualification')
    call('assign', '--job', captured['id'], '--slot', 0, '--reviewer', 'A', '--assignee', 'C', '--note', 'Adjudicate')
    call('adjudicate', '--job', captured['id'], '--slot', 0, '--reviewer', 'C', '--verdict', 'passed', '--note', 'Verified rubric')
    export = root / 'evidence'
    call('export', '--job', captured['id'], '--output', export)
    check((export / 'Dataset' / 'examples.jsonl').exists(), 'export includes dataset')
    check(len(list((export / 'Reviews').glob('*.jsonl'))) == 1, 'export includes complete review audit')
    sleeper = root / 'sleep.py'
    sleeper.write_text('#!/usr/bin/python3\nimport time\ntime.sleep(10)\n')
    sleeper.chmod(0o700)
    uncertain = call('job', '--dataset', dataset['revision'], '--name', 'Timeout', '--executor', sleeper, '--timeout', 0.1, '--attempts', 1)
    call('worker', '--worker-id', 'cli-fixture', '--executor', sleeper, '--descriptor', descriptor, '--job', uncertain['id'], '--limit', 1)
    check(call('report', '--job', uncertain['id'], expected=20)['counts']['uncertain'] == 1, 'custom actions default to side-effect uncertainty')
    check_worker_limit_case('healthy-cross-job-limit', first_count=1)
    check_worker_limit_case('failure-before-progress', first_count=2, cost_cap=0.5)
    check_worker_limit_case('explicit-job-error', first_count=2, cost_cap=1, explicit_job=True)
    check_worker_limit_case('partial-budget-failure', first_count=2, cost_cap=1)
    print(f'CLI integration: {assertions} assertions passed; real custom worker processes, bounded resume, backend isolation, capture/review, export and timeout.')
except Exception:
    print(f'Failure evidence retained in {root}', file=sys.stderr)
    raise
else:
    shutil.rmtree(root)
