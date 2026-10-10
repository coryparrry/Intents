import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('staged_suites', Path(__file__).resolve().parents[1] / 'scripts/run_staged_mac_ownership_tests.py')
suites = importlib.util.module_from_spec(spec)
spec.loader.exec_module(suites)

SUITE = "Test Case '-[AgentDeviceMacOSHelperTests.MacOwnedFillTests {}]' {}"
OWNERSHIP = '/private/tmp/stage/sdk/src/intents-mac-sdk-ownership.test.ts'


def report(statuses, name=OWNERSHIP, total=None):
    return {
        'numTotalTests': len(statuses) if total is None else total,
        'numFailedTests': statuses.count('failed'),
        'testResults': [{'name': name, 'assertionResults': [{'status': status} for status in statuses]}],
    }


class StagedMacOwnershipSuitesTests(unittest.TestCase):
    def test_declared_cases_come_from_the_staged_sources(self):
        swift = (suites.TEMPLATES / 'MacOwnedFillTests.swift').read_text()
        declared = suites.declared_swift_tests(swift)
        self.assertIn('testAncestryIsBoundedToThirtyTwoNodesAndMustReachTheApplication', declared)
        self.assertIn('testFrameReaderRejectsInvalidBoundsBeforeReading', declared)
        self.assertNotIn('frame', declared)
        vitest = (suites.TEMPLATES / 'intents-mac-sdk-ownership.test.ts').read_text()
        self.assertGreater(suites.declared_vitest_tests(vitest), 0)

    def test_swift_output_must_pass_every_declared_case(self):
        declared = {'testA', 'testB'}
        output = '\n'.join([SUITE.format('testA', 'passed (0.001 seconds).'), SUITE.format('testB', 'passed (0.002 seconds).')])
        self.assertEqual(suites.check_swift_output(output, declared), 2)
        for output, message in [
            ('Executed 0 tests, with 0 failures', 'did not run: testA, testB'),
            (SUITE.format('testA', 'passed'), 'did not run: testB'),
            (SUITE.format('testA', 'passed') + '\n' + SUITE.format('testB', 'failed'), 'failed: testB'),
            ("Test Case '-[OtherTests.OtherSuite testA]' passed\n" + SUITE.format('testB', 'passed'), 'did not run: testA'),
        ]:
            with self.assertRaisesRegex(suites.SuiteError, message):
                suites.check_swift_output(output, declared)
        with self.assertRaisesRegex(suites.SuiteError, 'declares zero tests'):
            suites.check_swift_output(SUITE.format('testA', 'passed'), set())

    def test_vitest_report_must_collect_and_pass_the_ownership_file(self):
        self.assertEqual(suites.check_vitest_report(report(['passed', 'passed']), 2), 2)
        for value, declared, message in [
            ({'numTotalTests': 0, 'testResults': []}, 2, 'was not collected'),
            (report(['passed'], name='/private/tmp/stage/sdk/src/other.test.ts'), 1, 'was not collected'),
            (report([]), 1, 'collected zero tests'),
            (report(['skipped', 'skipped']), 2, 'collected zero tests'),
            (report(['passed', 'failed']), 2, 'failed'),
            (report(['passed', 'skipped']), 2, 'failed'),
            (report(['passed']), 2, 'ran 1 of 2'),
            (report(['passed']), 0, 'ran 1 of 0'),
        ]:
            with self.assertRaisesRegex(suites.SuiteError, message):
                suites.check_vitest_report(value, declared)

    def test_extraction_refuses_an_unpinned_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / 'agent-device.tgz'
            archive.write_bytes(b'not the pinned archive')
            with self.assertRaisesRegex(suites.SuiteError, 'hash mismatch'):
                suites.extract(archive, Path(temporary) / 'out')


if __name__ == '__main__':
    unittest.main()
