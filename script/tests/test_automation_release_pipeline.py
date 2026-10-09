"""Release sequencing contracts; isolated stubs are not Developer-ID qualification."""
from pathlib import Path
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1]

class AutomationSealTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='intents-automation-seal-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        script = self.root / 'script'; script.mkdir()
        shutil.copy2(SOURCE / 'automation_seal_app.sh', script)
        node = self.root / 'Tools/IntentsAutomation/.runtime/node-v24.21.0-darwin-arm64/bin/node'
        node.parent.mkdir(parents=True); node.write_text('#!/bin/sh\nexit 0\n'); node.chmod(0o700)
        self.log = self.root / 'sequence.txt'
        self.app = self.root / 'App with spaces.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        self.environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(self.root), 'TMPDIR': str(self.root)}
    def stub(self, name, status=0):
        path = self.root / 'script' / name
        path.write_text('#!/bin/sh\nprintf "%s\\n" ' + repr(name) + ' >> ' + repr(str(self.log)) + '\nexit ' + str(status) + '\n')
        path.chmod(0o700)
    def run_seal(self, identity='-'):
        return subprocess.run(['/bin/bash', str(self.root / 'script/automation_seal_app.sh'), '--app', str(self.app),
            '--identity', identity], env=self.environment, capture_output=True, text=True, timeout=30)
    def testFailedStagingNeverReachesSigningOrVerification(self):
        self.stub('automation_package.sh', 42)
        self.stub('automation_sign_runtime.sh'); self.stub('automation_verify_bundle.sh')
        result = self.run_seal()
        self.assertEqual(result.returncode, 42)
        self.assertEqual(self.log.read_text().splitlines(), ['automation_package.sh'])
    def testFailedNestedSigningNeverSealsOrVerifiesOuterApp(self):
        self.stub('automation_package.sh'); self.stub('automation_sign_runtime.sh', 43)
        self.stub('automation_verify_bundle.sh')
        result = self.run_seal()
        self.assertEqual(result.returncode, 43)
        self.assertEqual(self.log.read_text().splitlines(), ['automation_package.sh', 'automation_sign_runtime.sh'])
    @unittest.skipUnless(sys.platform == 'darwin', 'Native signing sequencing requires macOS')
    def testOuterSealPreservesExistingEntitlementsAndVerifiesLast(self):
        self.stub('automation_package.sh'); self.stub('automation_sign_runtime.sh'); self.stub('automation_verify_bundle.sh')
        executable = self.app / 'Contents/MacOS/TestExecutable'
        shutil.copyfile('/usr/bin/true', executable); executable.chmod(0o700)
        with (self.app / 'Contents/Info.plist').open('wb') as output:
            plistlib.dump({'CFBundleExecutable': 'TestExecutable', 'CFBundleIdentifier': 'example.Intents.ReleaseTest',
                'CFBundlePackageType': 'APPL'}, output)
        entitlements = self.root / 'app-entitlements.plist'
        with entitlements.open('wb') as output: plistlib.dump({'com.apple.security.network.client': True}, output)
        signed = subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), str(self.app)],
            env=self.environment, capture_output=True, text=True, timeout=30)
        self.assertEqual(signed.returncode, 0, signed.stderr)
        result = self.run_seal(); self.assertEqual(result.returncode, 0, result.stderr)
        actual = subprocess.run(['/usr/bin/codesign', '--display', '--entitlements', '-', '--xml', str(self.app)], env=self.environment,
            capture_output=True, timeout=30)
        self.assertEqual(actual.returncode, 0, actual.stderr)
        self.assertEqual(plistlib.loads(actual.stdout), {'com.apple.security.network.client': True})
        self.assertEqual(self.log.read_text().splitlines(), ['automation_package.sh', 'automation_sign_runtime.sh', 'automation_verify_bundle.sh'])

class AutomationBuildToolchainTests(unittest.TestCase):
    """Selected-toolchain routing with isolated command stubs, not an SDK build."""
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='intents-automation-toolchain-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        script = self.root / 'script'; script.mkdir()
        shutil.copy2(SOURCE / 'automation_build.sh', script)
        package = self.root / 'Tools/IntentsAutomation'
        (package / 'node_modules').mkdir(parents=True)
        (package / 'scripts').mkdir()
        for name in ['apply_sdk_lifecycle_patch.py', 'apply_e2e_action_budget_patch.py']:
            (package / 'scripts' / name).write_text('pass\n')
        (self.root / 'Integration/AutomationHost').mkdir(parents=True)
        (self.root / 'Integration/AutomationHost/Fixture.swift').write_text('// fixture\n')
        commands = self.root / 'commands'; commands.mkdir()
        helper = self.root / 'helper-output'; helper.mkdir()
        (helper / 'agent-device-macos-helper').write_text('fixture')
        self.arguments = self.root / 'swiftc-arguments.json'
        self.developer = self.root / 'Selected Xcode/Contents/Developer'
        self.environment = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ['PATH'],
            DEVELOPER_DIR=str(self.developer), TOOLCHAIN_ARGUMENTS=str(self.arguments), TOOLCHAIN_HELPER=str(helper))
        stub = '''import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
if name == 'uname': print('Darwin')
elif name == 'xcode-select': print('/global/old-xcode/Contents/Developer')
elif name == 'xcrun':
    if '--show-sdk-platform-path' in sys.argv:
        if os.environ.get('TOOLCHAIN_MISSING_PLATFORM'): sys.exit(97)
        print(os.environ['DEVELOPER_DIR'] + '/Platforms/iPhoneSimulator.platform')
    else: print(os.environ['DEVELOPER_DIR'] + '/Selected.sdk')
elif name == 'swiftc': Path(os.environ['TOOLCHAIN_ARGUMENTS']).write_text(json.dumps(sys.argv[1:]))
elif name == 'swift' and '--show-bin-path' in sys.argv: print(os.environ['TOOLCHAIN_HELPER'])
'''
        for name in ['uname', 'xcode-select', 'xcrun', 'swift', 'swiftc', 'npm']:
            path = commands / name
            path.write_text('#!' + sys.executable + '\n' + stub); path.chmod(0o700)
    def run_build(self):
        return subprocess.run(['/bin/bash', str(self.root / 'script/automation_build.sh')], env=self.environment,
            capture_output=True, text=True, timeout=30)
    def testFrameworkAndSDKUseTheSelectedDeveloperDirectory(self):
        result = self.run_build(); self.assertEqual(result.returncode, 0, result.stderr)
        arguments = json.loads(self.arguments.read_text())
        self.assertEqual(arguments[arguments.index('-sdk') + 1], str(self.developer / 'Selected.sdk'))
        self.assertEqual(arguments[arguments.index('-F') + 1],
            str(self.developer / 'Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks'))
    def testMissingSelectedPlatformStopsBeforeTypecheck(self):
        self.environment['TOOLCHAIN_MISSING_PLATFORM'] = '1'
        result = self.run_build(); self.assertEqual(result.returncode, 97, result.stderr)
        self.assertFalse(self.arguments.exists())

if __name__ == '__main__': unittest.main()
