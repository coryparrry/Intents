#!/usr/bin/env python3
"""Stage the disabled Mac ownership experiment from the pinned archive and run its staged suites."""
import argparse
import hashlib
import json
import platform
import re
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import stage_mac_helper_startup_gate as gate  # noqa: E402
import stage_mac_owned_fill as fill  # noqa: E402
import stage_mac_owned_scroll as scroll  # noqa: E402
import stage_mac_sdk_ownership as sdk  # noqa: E402
import verify_private_mac_source as base  # noqa: E402

TEMPLATES = SCRIPTS.parent / 'patches/mac-ownership'
CHECKPOINT = SCRIPTS.parents[2] / 'Verification/Automation/mac-sdk-ownership-source-1.json'
ARCHIVE_URL = f'https://codeload.github.com/callstack/agent-device/legacy.tar.gz/{base.REVISION}'
PNPM = 'pnpm@11.17.0'
SWIFT_SUITE = 'MacOwnedFillTests'
VITEST_FILE = 'src/intents-mac-sdk-ownership.test.ts'


class SuiteError(Exception):
    pass


def declared_swift_tests(source):
    return set(re.findall(r'^\s*func (test\w+)\(', source, re.MULTILINE))


def declared_vitest_tests(source):
    return len(re.findall(r'^\s*(?:it|test)\(', source, re.MULTILINE))


def check_swift_output(output, declared):
    case = r"Test Case '-\[\S+\." + SWIFT_SUITE + r" (test\w+)\]' (passed|failed)"
    results = re.findall(case, output)
    failed = sorted({name for name, status in results if status == 'failed'})
    passed = {name for name, status in results if status == 'passed'}
    if not declared:
        raise SuiteError(f'{SWIFT_SUITE} declares zero tests')
    if failed:
        raise SuiteError(f'{SWIFT_SUITE} failed: {", ".join(failed)}')
    missing = sorted(declared - passed)
    if missing:
        raise SuiteError(f'{SWIFT_SUITE} did not run: {", ".join(missing)}')
    return len(passed)


def check_vitest_report(report, declared):
    files = [entry for entry in report.get('testResults', []) if entry.get('name', '').endswith('/' + VITEST_FILE)]
    if len(files) != 1:
        raise SuiteError(f'{VITEST_FILE} was not collected')
    assertions = files[0].get('assertionResults', [])
    passed = [result for result in assertions if result.get('status') == 'passed']
    if report.get('numTotalTests', 0) == 0 or not passed:
        raise SuiteError('staged Vitest suite collected zero tests')
    if report.get('numFailedTests', 0) or len(passed) != len(assertions):
        raise SuiteError('staged Vitest suite failed')
    if declared == 0 or len(passed) < declared:
        raise SuiteError(f'{VITEST_FILE} ran {len(passed)} of {declared} declared tests')
    return report['numTotalTests']


def fetch_archive(path):
    with urllib.request.urlopen(ARCHIVE_URL, timeout=120) as response:
        path.write_bytes(response.read(100 * 1024 * 1024))


def extract(archive, destination):
    if hashlib.sha256(archive.read_bytes()).hexdigest() != base.ARCHIVE_SHA256:
        raise SuiteError('pinned agent-device archive hash mismatch')
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            if not (member.isfile() or member.isdir() or member.issym()) or member.name.startswith('/') or '..' in Path(member.name).parts:
                raise SuiteError('unsafe pinned archive member')
        tar.extractall(destination)
    roots = [path for path in destination.iterdir() if path.is_dir()]
    if len(roots) != 1:
        raise SuiteError('pinned archive must contain one source root')
    return roots[0]


def stage(archive, work):
    source = extract(archive, work / 'archive')
    sdk.stage(source, work / 'sdk')
    base.verify(work / 'sdk', archive, CHECKPOINT)
    gate.stage(work / 'gate', work / 'sdk', archive, CHECKPOINT)
    scroll.stage(work / 'gate', work / 'scroll')
    fill.stage(work / 'scroll', work / 'fill')
    return work / 'sdk', work / 'fill' / 'apple/macos-helper'


def run(command, cwd, log):
    print('+', ' '.join(command), flush=True)
    result = subprocess.run(command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    log.write_text(result.stdout)
    sys.stdout.write(result.stdout)
    if result.returncode:
        raise SuiteError(f'{command[0]} exited {result.returncode}')
    return result.stdout


def run_swift(helper, work):
    declared = declared_swift_tests((TEMPLATES / f'{SWIFT_SUITE}.swift').read_text())
    output = run(['swift', 'test', '--package-path', str(helper), '--filter', SWIFT_SUITE], work, work / 'swift-test.log')
    return check_swift_output(output, declared)


def run_vitest(sdk_root, work):
    report = work / 'vitest-report.json'
    pnpm = ['npx', '--yes', PNPM]
    run(pnpm + ['install', '--frozen-lockfile', '--ignore-scripts'], sdk_root, work / 'pnpm-install.log')
    run(pnpm + ['exec', 'vitest', 'run', '--config', 'intents-mac-vitest.config.ts',
                '--reporter=default', '--reporter=json', f'--outputFile.json={report}'], sdk_root, work / 'vitest.log')
    declared = declared_vitest_tests((TEMPLATES / 'intents-mac-sdk-ownership.test.ts').read_text())
    return check_vitest_report(json.loads(report.read_text()), declared)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, help='pinned agent-device archive; downloaded when omitted')
    parser.add_argument('--suite', choices=['all', 'swift', 'vitest'], default='all')
    args = parser.parse_args()
    if args.suite != 'vitest' and platform.system() != 'Darwin':
        parser.error('the staged Swift helper suite requires macOS')
    try:
        with tempfile.TemporaryDirectory(prefix='intents-mac-ownership-suites-') as temporary:
            work = Path(temporary).resolve()
            archive = args.archive.resolve() if args.archive else work / 'agent-device.tgz'
            if not args.archive:
                fetch_archive(archive)
            sdk_root, helper = stage(archive, work)
            if args.suite in ('all', 'vitest'):
                print(f'staged Vitest tests passed: {run_vitest(sdk_root, work)}')
            if args.suite in ('all', 'swift'):
                print(f'staged {SWIFT_SUITE} cases passed: {run_swift(helper, work)}')
    except (SuiteError, ValueError, OSError) as error:
        print(f'staged Mac ownership suites failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
