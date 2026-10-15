"""Local Run sequencing with isolated tools; native signing needs separate qualification."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SOURCE = Path(__file__).resolve().parents[1] / 'build_and_run.sh'
IDENTITY = hashlib.sha1(b'Developer ID Application fixture').hexdigest().upper()
TEAM_ID = 'ABCDE12345'
IDENTITY_NAME = 'Developer ID Application: Fixture (' + TEAM_ID + ')'


class LocalAppBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='intents-local-run-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / 'Source with spaces'
        self.root.mkdir()
        scripts = self.root / 'script'
        scripts.mkdir()
        commands = self.root / 'commands'
        commands.mkdir()
        # Production keeps absolute system-tool paths. Redirect only the copied
        # fixture so tests never sign or launch an app on the developer's Mac.
        source = SOURCE.read_text()
        for name in ['codesign', 'security', 'shasum', 'open', 'log']:
            source = source.replace('/usr/bin/' + name, '"' + str(commands / name) + '"')
        (scripts / SOURCE.name).write_text(source)
        shutil.copy2(SOURCE.with_name('local_app_build.py'), scripts)
        self.log = self.root / 'calls.jsonl'
        self.app = self.root / 'dist/Intents.app'
        self.app.mkdir(parents=True)
        (self.app / 'previous.marker').write_text('existing usable app')
        self.environment = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ['PATH'],
                                LOCAL_TEST_LOG=str(self.log), LOCAL_TEST_IDENTITY=IDENTITY,
                                LOCAL_TEST_IDENTITY_NAME=IDENTITY_NAME, LOCAL_TEST_TEAM=TEAM_ID)
        self.environment.pop('INTENTS_LOCAL_SIGNING_IDENTITY', None)
        self.environment.pop('INTENTS_MAC_RUNTIME_ARCHIVE', None)
        self.environment.pop('INTENTS_LOCAL_DERIVED_DATA', None)
        self.environment.pop('INTENTS_LOCAL_BUILD_LOCK_FD', None)
        stub = '''import hashlib, json, os, shutil, sys, time
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['LOCAL_TEST_LOG'], 'a') as output:
    output.write(json.dumps([name, args]) + '\\n')
if name == 'pgrep': sys.exit(0 if os.environ.get('LOCAL_TEST_RUNNING') else 1)
elif name == 'python3':
    if Path(args[0]).name == 'local_app_build.py':
        if '--rename-exclusive' in args:
            source, destination = args[-2:]
            publishing = Path(source).name == 'Intents.app' and '.Intents-stage.' in source
            if publishing and os.environ.get('LOCAL_TEST_PUBLISH_STATUS'):
                sys.exit(int(os.environ['LOCAL_TEST_PUBLISH_STATUS']))
            if publishing and os.environ.get('LOCAL_TEST_RACED_DESTINATION'):
                Path(destination).mkdir()
                (Path(destination) / 'raced.marker').write_text('raced-in app')
        os.execv(sys.executable, [sys.executable, *args])
elif name == 'xcodebuild':
    gate_value = os.environ.get('LOCAL_TEST_SEAL_GATE')
    if gate_value:
        gate = Path(gate_value)
        gate.with_suffix('.ready').write_text('build gate entered')
        while gate.exists(): time.sleep(0.02)
    status = int(os.environ.get('LOCAL_TEST_BUILD_STATUS', '0'))
    if status: sys.exit(status)
    app = Path(args[args.index('-derivedDataPath') + 1]) / 'Build/Products/Debug/Intents.app'
    (app / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
    (app / 'Contents/MacOS/FoundationEvals').write_text('fresh executable')
    (app / 'built.marker').write_text('fresh')
elif name == 'codesign':
    if '--extract-certificates' in args: raise AssertionError('Xcode fixture is ad hoc signed')
    elif '--display' in args:
        print('TeamIdentifier=' + os.environ['LOCAL_TEST_TEAM'], file=sys.stderr)
    elif '--verify' in args and '.Intents-stage.' in args[-1]:
        app = Path(args[-1])
        if not (app / 'built.marker').exists(): sys.exit(98)
        sys.exit(int(os.environ.get('LOCAL_TEST_VERIFY_STATUS', '0')))
elif name == 'security':
    if not os.environ.get('LOCAL_TEST_UNAVAILABLE_IDENTITY'):
        identity_name = ('Apple Development: Fixture (' + os.environ['LOCAL_TEST_TEAM'] + ')'
                         if os.environ.get('LOCAL_TEST_DEVELOPMENT_ONLY') else os.environ['LOCAL_TEST_IDENTITY_NAME'])
        print('1) ' + os.environ['LOCAL_TEST_IDENTITY'] + ' "' + identity_name + '"')
        if os.environ.get('LOCAL_TEST_AMBIGUOUS_IDENTITY'):
            print('2) ' + 'B' * 40 + ' "Developer ID Application: Second (' + os.environ['LOCAL_TEST_TEAM'] + ')"')
elif name == 'shasum': print(hashlib.sha1(Path(args[-1]).read_bytes()).hexdigest() + '  ' + args[-1])
elif name == 'ditto': shutil.copytree(args[0], args[1])
elif name in ('open', 'lldb'):
    app = Path(args[-1]) if name == 'open' else Path(args[-1]).parents[2]
    assert (app / 'built.marker').exists()
    assert not (app / 'previous.marker').exists()
    gate_value = os.environ.get('LOCAL_TEST_OPEN_GATE')
    if name == 'open' and gate_value:
        gate = Path(gate_value)
        gate.with_suffix('.ready').write_text('launch gate entered')
        while gate.exists(): time.sleep(0.02)
elif name in ('xattr', 'log'): pass
else: raise AssertionError('Unexpected command: ' + name)
'''
        for name in ['pgrep', 'python3', 'xcodebuild', 'codesign', 'security', 'shasum',
                     'ditto', 'xattr', 'open', 'lldb', 'log', 'swift']:
            path = commands / name
            path.write_text('#!' + sys.executable + '\n' + stub)
            path.chmod(0o700)
    def run_build(self, mode='run'):
        return subprocess.run(['/bin/bash', str(self.root / 'script/build_and_run.sh'), mode],
                              env=self.environment, capture_output=True, text=True, timeout=30)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def assert_old_app_preserved(self):
        self.assertEqual((self.app / 'previous.marker').read_text(), 'existing usable app')
        self.assertFalse((self.app / 'built.marker').exists())
        self.assertNotIn('open', [call[0] for call in self.calls()])
        self.assertEqual(list(self.app.parent.iterdir()), [self.app])



    def testDebugBuildAndLaunchNeedNoNodeRuntimeOrSigningTeam(self):
        self.environment['LOCAL_TEST_UNAVAILABLE_IDENTITY'] = '1'
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        names = [call[0] for call in self.calls()]
        self.assertNotIn('npm', names)
        self.assertNotIn('security', names)
        self.assertNotIn('swift', names)
        build = next(call for call in self.calls() if call[0] == 'xcodebuild')
        self.assertIn('CODE_SIGN_IDENTITY=-', build[1])
        self.assertIn('DEVELOPMENT_TEAM=', build[1])
        self.assertLess(names.index('xcodebuild'), names.index('open'))
        self.assertTrue((self.app / 'built.marker').exists())

    def testFailedBuildPreservesPreviousAppAndNeverOpens(self):
        self.environment['LOCAL_TEST_BUILD_STATUS'] = '42'
        self.assertEqual(self.run_build().returncode, 42)
        self.assert_old_app_preserved()

    def testFailedSignedBundleVerificationNeverPublishesOrOpens(self):
        self.environment['LOCAL_TEST_VERIFY_STATUS'] = '43'
        self.assertEqual(self.run_build().returncode, 43)
        self.assert_old_app_preserved()

    def testFailedPublicationRestoresPreviousAppBeforeCleanup(self):
        self.environment['LOCAL_TEST_PUBLISH_STATUS'] = '45'
        self.assertEqual(self.run_build().returncode, 45)
        self.assert_old_app_preserved()

    def testUnknownModeFailsBeforePreparingOrBuilding(self):
        result = self.run_build('--unknown')
        self.assertEqual(result.returncode, 2)
        self.assertIn('usage:', result.stderr)
        self.assertEqual(self.calls(), [])
        self.assert_old_app_preserved()

    def testRunningAppFailsBeforePreparingOrBuilding(self):
        self.environment['LOCAL_TEST_RUNNING'] = '1'
        self.assertEqual(self.run_build().returncode, 3)
        self.assertEqual([call[0] for call in self.calls()], ['python3', 'python3', 'pgrep'])
        self.assert_old_app_preserved()















    def testRacedDestinationIsNotNestedIntoAndPreviousAppIsRetainedForRecovery(self):
        self.environment['LOCAL_TEST_RACED_DESTINATION'] = '1'
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.app / 'raced.marker').read_text(), 'raced-in app')
        self.assertFalse((self.app / 'Intents.app').exists())
        self.assertIn('Previous app retained for recovery:', result.stderr)
        stages = list(self.app.parent.glob('.Intents-stage.*'))
        self.assertEqual(len(stages), 1)
        self.assertEqual((stages[0] / 'previous.app/previous.marker').read_text(), 'existing usable app')
        self.assertNotIn('open', [call[0] for call in self.calls()])

    def wait_for(self, condition):
        deadline = time.monotonic() + 10
        while not condition():
            if time.monotonic() >= deadline:
                self.fail('Timed out waiting for isolated local build gate')
            time.sleep(0.02)

    def assert_concurrent_invocation_rejected(self, gate_variable):
        gate = self.root / 'owner.gate'
        gate.touch()
        first_environment = dict(self.environment, **{gate_variable: str(gate)})
        first = subprocess.Popen(['/bin/bash', str(self.root / 'script/build_and_run.sh'), 'run'],
                                 env=first_environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, start_new_session=True)
        second = None
        try:
            self.wait_for(lambda: gate.with_suffix('.ready').exists() or first.poll() is not None)
            if first.poll() is not None:
                output, error = first.communicate()
                self.fail(f'First build failed before gate: {output} {error}')
            second = subprocess.Popen(['/bin/bash', str(self.root / 'script/build_and_run.sh'), 'run'],
                                      env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                      text=True, start_new_session=True)
            second_output, second_error = second.communicate(timeout=5)
            self.assertEqual(second.returncode, 3, second_output + second_error)
            self.assertIn('Another local app build is running.', second_error)
            self.assertIsNone(first.poll())
            names = [call[0] for call in self.calls()]
            self.assertEqual(names.count('node'), 0)
            self.assertEqual(names.count('npm'), 0)
            self.assertEqual(names.count('xcodebuild'), 1)
            self.assertEqual(names.count('open'), 1 if gate_variable == 'LOCAL_TEST_OPEN_GATE' else 0)
            gate.unlink()
            first_output, first_error = first.communicate(timeout=30)
            self.assertEqual(first.returncode, 0, first_output + first_error)
            self.assertTrue((self.app / 'built.marker').exists())
            self.assertFalse((self.app / 'Intents.app').exists())
            self.assertEqual([call[0] for call in self.calls()].count('xcodebuild'), 1)
            self.assertEqual([call[0] for call in self.calls()].count('open'), 1)
        finally:
            gate.unlink(missing_ok=True)
            for process in [first, second]:
                if process is not None:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.communicate(timeout=5)

    def testConcurrentInvocationIsRejectedBeforeAnySharedPreparation(self):
        self.assert_concurrent_invocation_rejected('LOCAL_TEST_SEAL_GATE')

    def testConcurrentInvocationCannotReplaceAppBetweenPublicationAndLaunch(self):
        self.assert_concurrent_invocation_rejected('LOCAL_TEST_OPEN_GATE')

    def testKilledKernelLockOwnerDoesNotLeaveAStaleLock(self):
        script = self.root / 'script/build_and_run.sh'
        ready = self.root / 'lock-owner.ready'
        code = f'import time; from pathlib import Path; Path({str(ready)!r}).touch(); time.sleep(30)'
        script.write_text('exec ' + shlex.quote(sys.executable) + ' -c ' + shlex.quote(code) + '\n')
        helper = self.root / 'script/local_app_build.py'
        first = subprocess.Popen([sys.executable, str(helper), '--run', str(script)], env=self.environment,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.wait_for(lambda: ready.exists() or first.poll() is not None)
            self.assertIsNone(first.poll())
            first.kill()
            first.communicate(timeout=5)
            script.write_text('exit 0\n')
            following = subprocess.run([sys.executable, str(helper), '--run', str(script)],
                                       env=self.environment, capture_output=True, text=True, timeout=5)
            self.assertEqual(following.returncode, 0, following.stderr)
        finally:
            if first.poll() is None:
                first.kill()
            first.communicate(timeout=5)


    def testDebugLaunchUsesTheVerifiedBundledExecutable(self):
        result = self.run_build('--debug')
        self.assertEqual(result.returncode, 0, result.stderr)
        debugger = next(call for call in self.calls() if call[0] == 'lldb')
        self.assertEqual(debugger[1], ['--', str(self.app / 'Contents/MacOS/FoundationEvals')])
        self.assertNotIn('open', [call[0] for call in self.calls()])

    def testBuildOnlyPublishesVerifiedAppWithoutLaunching(self):
        result = self.run_build('--build-only')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.app / 'built.marker').exists())
        self.assertIn('Built and verified:', result.stdout)
        self.assertNotIn('open', [call[0] for call in self.calls()])
        self.assertNotIn('lldb', [call[0] for call in self.calls()])

    def testDerivedDataOverrideIsRebuiltAndPreserved(self):
        derived_data = self.root / 'Existing Derived Data'
        derived_data.mkdir()
        marker = derived_data / 'preserved.marker'
        marker.write_text('existing cache')
        self.environment['INTENTS_LOCAL_DERIVED_DATA'] = str(derived_data)
        result = self.run_build('--build-only')
        self.assertEqual(result.returncode, 0, result.stderr)
        build = next(call for call in self.calls() if call[0] == 'xcodebuild')
        self.assertEqual(build[1][build[1].index('-derivedDataPath') + 1], str(derived_data))
        self.assertEqual(marker.read_text(), 'existing cache')
        self.assertTrue((derived_data / 'Build/Products/Debug/Intents.app/built.marker').exists())

    def testRelativeDerivedDataOverrideFailsBeforeBuild(self):
        self.environment['INTENTS_LOCAL_DERIVED_DATA'] = 'relative/cache'
        result = self.run_build('--build-only')
        self.assertEqual(result.returncode, 2)
        self.assertIn('absolute directory', result.stderr)
        self.assertEqual(self.calls(), [])
        self.assert_old_app_preserved()


if __name__ == '__main__':
    unittest.main()
