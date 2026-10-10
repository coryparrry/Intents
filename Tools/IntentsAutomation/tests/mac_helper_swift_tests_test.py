import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('mac_helper_tests', SCRIPTS / 'run_mac_helper_tests.py')
runner = importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)


class MacHelperSwiftTestsTests(unittest.TestCase):
    def fixture(self, root):
        source = root / 'agent-device'; source.mkdir()
        (source / 'package.json').write_text(json.dumps({'name': 'agent-device', 'version': '0.21.20'}))
        for directory in ['Sources/AgentDeviceMacOSHelper', 'Tests/AgentDeviceMacOSHelperTests']:
            (source / 'apple/macos-helper' / directory).mkdir(parents=True)
        names = list(runner.staging.EXPECTED)
        (source / names[0]).write_text('    switch command {\n    switch action {\n    case "frontmost":\n' + '      return SuccessEnvelope(data: try captureSnapshotResponse(surface: surface, bundleId: bundleId))\n' * 2 + '  static func handlePress(arguments: [String]) throws -> any Encodable {\n    try pressAtPosition(request)\n  }\n  static func handleScreenshot(arguments: [String]) throws -> any Encodable {\n')
        (source / names[1]).write_text('  let backend = "macos-helper"\nfunc captureSnapshotResponse(surface: String, bundleId: String? = nil) throws -> SnapshotResponse {\n  let result: SnapshotBuildResult\n  switch surface {\nprivate func snapshotFrontmostApp() throws -> SnapshotBuildResult {\n  let app = try resolveTargetApplication(bundleId: nil, surface: "frontmost-app")\n')
        return source, {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in names}

    def expected(self):
        sources = dict(runner.SUITES)
        sources.update({path.stem: path for path in runner.OVERLAY.glob('*.swift')})
        return runner.declared(sources)

    def catalog(self, expected):
        lines = ['AgentDeviceMacOSInputTests.MouseClickScheduleTests/testDefaultHold',
                 'AgentDeviceMacOSHelperTests.ScreenshotResponseTests/testEncodes']
        lines += [f'AgentDeviceMacOSHelperTests.{suite}/{name}' for suite, names in expected.items() for name in sorted(names)]
        return '\n'.join(lines) + '\n'

    def execute(self, catalog, output, returncode=0):
        calls, staged = [], {}
        def swift(command, **_):
            calls.append(command)
            helper = Path(command[command.index('--package-path') + 1])
            staged.update({path.name: path.read_bytes() for path in (helper / 'Tests/AgentDeviceMacOSHelperTests').glob('*.swift')})
            if command[-1] == 'list':
                return SimpleNamespace(stdout=catalog)
            return SimpleNamespace(returncode=returncode, stdout=output, args=command)
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            source, digests = self.fixture(Path(temporary).resolve())
            with patch.object(runner.staging, 'EXPECTED', digests), patch('sys.stdout'):
                try:
                    return runner.run(source, swift), calls, staged
                finally:
                    self.assertEqual(sorted(path.name for path in Path(temporary).iterdir()), ['agent-device'])
                    self.assertEqual(hashlib.sha256((source / next(iter(digests))).read_bytes()).hexdigest(), next(iter(digests.values())))

    def test_staged_suites_must_be_discovered_and_fully_executed(self):
        expected = self.expected(); total = sum(map(len, expected.values()))
        self.assertGreaterEqual(expected['MacOwnedMouseDeliveryCleanupTests'], {
            'testCancellationDuringInterClickDelaySendsNoFurtherDown',
            'testReleaseTargetLossOnNormalReleaseIsNotSubmittedAndNotUncertain',
            'testPrepareFailurePartwayThroughScheduleSendsNothing'})
        output = f'Executed 9 tests, with 0 failures (0 unexpected)\nExecuted {total} tests, with 0 failures (0 unexpected)\n'
        counts, calls, staged = self.execute(self.catalog(expected), output)
        self.assertEqual(counts, {suite: len(names) for suite, names in expected.items()})
        self.assertEqual(len(calls), 2); self.assertEqual(calls[0][:2], ['swift', 'test']); self.assertEqual(calls[0][-1], 'list')
        pattern = calls[1][calls[1].index('--filter') + 1]
        self.assertRegex('AgentDeviceMacOSHelperTests.MacOwnedMouseDeliveryTests/testX', pattern)
        self.assertRegex('AgentDeviceMacOSHelperTests.MacOwnedMouseDeliveryCleanupTests/testX', pattern)
        self.assertNotRegex('AgentDeviceMacOSHelperTests.ScreenshotResponseTests/testX', pattern)
        self.assertNotRegex('OtherTests.MacOwnedMouseDeliveryTests/testX', pattern)
        for name in ['MacOwnedMouseDeliveryTests.swift', 'MacOwnedMouseDeliveryCleanupTests.swift']:
            origin = runner.TEMPLATES if name in [path.name for path in runner.SUITES.values()] else runner.OVERLAY
            self.assertEqual(staged[name], (origin / name).read_bytes())

    def test_missing_or_renamed_tests_fail_before_running(self):
        expected = self.expected()
        catalogs = [self.catalog({}), self.catalog(expected).replace('/testPrepareFailurePartway', '/testRenamedPartway'),
                    self.catalog(expected).replace('AgentDeviceMacOSHelperTests.MacOwnedMouseDeliveryTests/', 'OtherTests.MacOwnedMouseDeliveryTests/')]
        for catalog in catalogs:
            calls = []
            def swift(command, **_):
                calls.append(command); return SimpleNamespace(stdout=catalog)
            with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
                source, digests = self.fixture(Path(temporary).resolve())
                with patch.object(runner.staging, 'EXPECTED', digests):
                    with self.assertRaisesRegex(ValueError, 'discovery differs'):
                        runner.run(source, swift)
            self.assertEqual(len(calls), 1)

    def test_zero_partial_or_failed_execution_is_rejected(self):
        expected = self.expected(); total = sum(map(len, expected.values()))
        for output in ['', 'Executed 0 tests, with 0 failures (0 unexpected)\n',
                       f'Executed {total - 1} tests, with 0 failures (0 unexpected)\n',
                       f'Executed {total} tests, with 1 failure (0 unexpected)\n']:
            with self.assertRaises(ValueError):
                self.execute(self.catalog(expected), output)
        with self.assertRaises(subprocess.CalledProcessError):
            self.execute(self.catalog(expected), f'Executed {total} tests, with 1 failure\n', returncode=1)

    def test_suite_declarations_must_match_their_class(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            path = Path(temporary) / 'Suite.swift'
            path.write_text('final class Other: XCTestCase {\n  func testA() {}\n}\n')
            with self.assertRaises(ValueError): runner.declared({'Suite': path})
            path.write_text('final class Suite: XCTestCase {\n  func helper() {}\n}\n')
            with self.assertRaises(ValueError): runner.declared({'Suite': path})
            path.write_text('final class Suite: XCTestCase {\n  func testA() {}\n  func testB() throws {}\n}\n')
            self.assertEqual(runner.declared({'Suite': path}), {'Suite': {'testA', 'testB'}})


if __name__ == '__main__':
    unittest.main()
