#!/usr/bin/env python3
"""Stage the owned Mac helper sources into a fresh package copy and run their XCTest suites.

SwiftPM reports success when a filter matches nothing, so every staged suite must be
discovered with exactly the test methods its source declares, and must all execute.
"""
import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import stage_mac_snapshot_ownership as staging

AUTOMATION = Path(__file__).resolve().parents[1]
OVERLAY = AUTOMATION / 'tests/macos-helper'
TEMPLATES = AUTOMATION / 'patches/mac-ownership'
TARGET = 'AgentDeviceMacOSHelperTests'
SUITES = {'MacOwnedMouseDeliveryTests': TEMPLATES / 'MacOwnedMouseDeliveryTests.swift'}
TEST = re.compile(r'^\s*func (test\w*)\(', re.MULTILINE)
EXECUTED = re.compile(r'^\s*Executed (\d+) tests?, with (\d+) failures?', re.MULTILINE)


def declared(sources):
    expected = {}
    for suite, path in sources.items():
        text = path.read_text()
        if f'final class {suite}: XCTestCase' not in text:
            raise ValueError(f'{path.name} does not declare {suite}')
        names = TEST.findall(text)
        if not names or len(names) != len(set(names)):
            raise ValueError(f'{path.name} declares no tests or duplicate tests')
        expected[suite] = set(names)
    return expected


def discovered(catalog):
    found = {}
    for line in catalog.splitlines():
        match = re.fullmatch(r'(\w+)\.(\w+)/(\w+)', line.strip())
        if match and match[1] == TARGET:
            found.setdefault(match[2], set()).add(match[3])
    return found


def require_discovery(expected, found):
    for suite, names in expected.items():
        if found.get(suite) != names:
            missing = sorted(names - found.get(suite, set()))
            extra = sorted(found.get(suite, set()) - names)
            raise ValueError(f'{TARGET}.{suite} discovery differs; missing {missing}, unexpected {extra}')


def require_execution(output, expected):
    total = sum(len(names) for names in expected.values())
    counts = [(int(executed), int(failures)) for executed, failures in EXECUTED.findall(output)]
    if not counts or max(executed for executed, _ in counts) != total:
        raise ValueError(f'Expected {total} executed helper tests; XCTest reported {counts}')
    if any(failures for _, failures in counts):
        raise ValueError('Helper tests reported failures')


def suite_filter(expected):
    return r'^' + re.escape(TARGET) + r'\.(?:' + '|'.join(sorted(expected)) + r')/'


def stage(package, output):
    staging.stage(package, output, application_ownership=True, recipient_input=True)
    tests = output / 'apple/macos-helper/Tests' / TARGET
    sources = dict(SUITES)
    for path in sorted(OVERLAY.glob('*.swift')):
        destination = tests / path.name
        with destination.open('xb') as stream:
            stream.write(path.read_bytes())
        sources[path.stem] = destination
    for suite in SUITES:
        staged = tests / SUITES[suite].name
        if staged.read_bytes() != SUITES[suite].read_bytes():
            raise ValueError(f'Staged {staged.name} differs from its template')
        sources[suite] = staged
    return output / 'apple/macos-helper', sources


def run(package, run_command=subprocess.run):
    with tempfile.TemporaryDirectory(prefix='intents-mac-helper-tests-') as temporary:
        helper, sources = stage(package, Path(temporary).resolve() / 'agent-device')
        expected = declared(sources)
        command = ['swift', 'test', '--package-path', str(helper), '--scratch-path', str(helper.parent / '.build')]
        catalog = run_command([*command, 'list'], check=True, stdout=subprocess.PIPE, text=True).stdout
        require_discovery(expected, discovered(catalog))
        result = run_command([*command, '--filter', suite_filter(expected)],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        sys.stdout.write(result.stdout)
        if result.returncode:
            raise subprocess.CalledProcessError(result.returncode, result.args)
        require_execution(result.stdout, expected)
        return {suite: len(names) for suite, names in sorted(expected.items())}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True, help='Pinned agent-device package root')
    args = parser.parse_args()
    if shutil.which('swift') is None:
        parser.exit(2, 'swift is required to run the Mac helper tests\n')
    try:
        counts = run(args.package.resolve(strict=True))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, 'Mac helper tests failed: ' + str(error) + '\n')
    print('Mac helper tests executed:', ', '.join(f'{suite}={count}' for suite, count in counts.items()))
