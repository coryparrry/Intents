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

COMMAND_STUB = """import json, os, re, sys
argv = sys.argv[1:]
with open(os.environ['STUB_LOG'], 'a') as log: log.write(json.dumps([LABEL] + argv) + '\\n')
if LABEL == 'uname': print(os.environ.get('STUB_UNAME_M', 'arm64') if '-m' in argv else os.environ.get('STUB_UNAME_S', 'Darwin'))
elif LABEL == 'node': print(os.environ.get('STUB_NODE_VERSION', 'v24.21.0'))
elif LABEL == 'system-node': print('v22.0.0')
failing = os.environ.get('STUB_FAIL')
if failing and re.search(failing, ' '.join([LABEL] + argv)): sys.exit(41)
"""

class StubbedReleaseScriptCase(unittest.TestCase):
    """Runs one copied release script against logging command stubs on PATH."""
    script_name = None
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='intents-automation-release-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        (self.root / 'script').mkdir()
        shutil.copy2(SOURCE / self.script_name, self.root / 'script')
        self.commands = self.root / 'commands'; self.commands.mkdir()
        self.log = self.root / 'commands.jsonl'
        self.environment = {'PATH': str(self.commands) + os.pathsep + '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(self.root),
            'TMPDIR': str(self.root), 'STUB_LOG': str(self.log), 'INTENTS_AUTOMATION_NPM_CACHE': str(self.root / 'npm cache')}
        self.automation = self.root / 'Tools/IntentsAutomation'
        self.private_bin = self.automation / '.runtime/node-v24.21.0-darwin-arm64/bin'
    def command(self, directory, name, label=None):
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / name
        path.write_text('#!' + sys.executable + '\nLABEL = ' + repr(label or name) + '\n' + COMMAND_STUB); path.chmod(0o700)
        return path
    def script_stub(self, name, status=0):
        path = self.root / 'script' / name
        path.write_text('#!/bin/sh\nprintf \'["%s"]\\n\' ' + repr(name) + ' >> ' + repr(str(self.log)) + '\nexit ' + str(status) + '\n')
        path.chmod(0o700)
    def run_script(self, *arguments):
        return subprocess.run(['/bin/bash', str(self.root / 'script' / self.script_name), *map(str, arguments)],
            env=self.environment, capture_output=True, text=True, timeout=30)
    def calls(self, *excluded):
        if not self.log.exists(): return []
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [call for call in calls if call[0] not in excluded]

class AutomationPackageTests(StubbedReleaseScriptCase):
    """Runtime staging guards and provenance/patch ordering with stubbed npm and Python helpers."""
    script_name = 'automation_package.sh'
    def setUp(self):
        super().setUp()
        for name in ['uname', 'npm', 'python3']: self.command(self.commands, name)
        self.node = self.private_bin / 'node'
        self.helper = self.automation / '.runtime/helper-bin/agent-device-macos-helper'
        for path in [self.node, self.helper]:
            path.parent.mkdir(parents=True, exist_ok=True); path.write_text('#!/bin/sh\nexit 0\n'); path.chmod(0o700)
        (self.private_bin.parent / 'LICENSE').write_text('node license\n')
        (self.root / 'Integration/AutomationHost').mkdir(parents=True)
        (self.root / 'Integration/AutomationHost/AutomationHost.swift').write_text('// host template\n')
        for name in ['package.json', 'package-lock.json', 'dependencies.lock.json']: (self.automation / name).write_text('{}\n')
        (self.automation / 'provenance').mkdir(); (self.automation / 'provenance/attestation.json').write_text('{}\n')
        (self.automation / 'dist/src').mkdir(parents=True); (self.automation / 'dist/src/index.js').write_text('// sidecar\n')
        self.app = self.root / 'Built Intents.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        self.resources = self.app / 'Contents/Resources/Automation'
    def scripts(self, name): return str(self.automation / 'scripts' / name)
    def assertNothingStaged(self):
        self.assertFalse((self.app / 'Contents/Helpers').exists())
        self.assertEqual(self.calls('uname', 'python3'), [])
    def testInvalidArgumentsExitBeforeAnyCommand(self):
        for arguments in [(), ('--app',), ('--bundle', self.app), ('--app', self.app, 'extra')]:
            with self.subTest(arguments=arguments):
                result = self.run_script(*arguments)
                self.assertEqual(result.returncode, 2); self.assertIn('usage:', result.stderr)
        self.assertEqual(self.calls(), [])
    def testMissingBuiltAppIsRefused(self):
        shutil.rmtree(self.app / 'Contents/MacOS')
        result = self.run_script('--app', self.app)
        self.assertEqual(result.returncode, 2); self.assertIn('Expected a built macOS app', result.stderr)
        self.assertEqual(self.calls(), [])
    def testMissingProvisionedNodeOrHelperIsRefused(self):
        for missing in [self.node, self.helper]:
            with self.subTest(missing=missing.name):
                missing.unlink()
                result = self.run_script('--app', self.app)
                self.assertEqual(result.returncode, 2); self.assertIn('must be provisioned', result.stderr)
                missing.write_text('#!/bin/sh\nexit 0\n'); missing.chmod(0o700)
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.resources.exists())
    def testNonExecutableNodeIsRefused(self):
        self.node.chmod(0o600)
        result = self.run_script('--app', self.app)
        self.assertEqual(result.returncode, 2); self.assertEqual(self.calls(), [])
    def testIntelHostIsRefusedBeforeProvenanceOrStaging(self):
        self.environment['STUB_UNAME_M'] = 'x86_64'
        result = self.run_script('--app', self.app)
        self.assertEqual(result.returncode, 2); self.assertIn('Intel runtime packaging is unqualified', result.stderr)
        self.assertEqual(self.calls(), [['uname', '-m']])
        self.assertFalse(self.resources.exists())
    def testFailedSourceProvenanceStopsBeforeAnyCopy(self):
        self.environment['STUB_FAIL'] = r'verify_dependency_provenance\.py$'
        result = self.run_script('--app', self.app)
        self.assertEqual(result.returncode, 41)
        self.assertEqual(self.calls('uname'), [['python3', self.scripts('verify_dependency_provenance.py')]])
        self.assertFalse(self.resources.exists()); self.assertFalse((self.app / 'Contents/Helpers').exists())
    def testExistingStagedRuntimeIsNeverOverwritten(self):
        self.resources.mkdir(parents=True)
        stale = self.resources / 'stale.js'; stale.write_text('stale runtime\n')
        result = self.run_script('--app', self.app)
        self.assertEqual(result.returncode, 2); self.assertIn('refusing to overwrite', result.stderr)
        self.assertEqual(self.calls('uname'), [['python3', self.scripts('verify_dependency_provenance.py')]])
        self.assertEqual(sorted(path.name for path in self.resources.iterdir()), ['stale.js'])
        self.assertEqual(stale.read_text(), 'stale runtime\n')
        self.assertFalse((self.app / 'Contents/Helpers').exists())
    def testStagingVerifiesThenInstallsPatchesReverifiesAndWritesManifestInOrder(self):
        result = self.run_script('--app', self.app); self.assertEqual(result.returncode, 0, result.stderr)
        resources = str(self.resources)
        self.assertEqual(self.calls('uname'), [
            ['python3', self.scripts('verify_dependency_provenance.py')],
            ['npm', 'ci', '--prefix', resources, '--omit=dev', '--ignore-scripts', '--offline', '--cache', str(self.root / 'npm cache')],
            ['python3', self.scripts('apply_sdk_lifecycle_patch.py'), '--package', resources + '/node_modules/agent-device'],
            ['python3', self.scripts('apply_e2e_action_budget_patch.py'), '--package', resources + '/node_modules/e2e'],
            ['python3', self.scripts('verify_dependency_provenance.py'), '--root', resources],
            ['python3', self.scripts('bundle_manifest.py'), '--app', str(self.app), '--write']])
        helpers = self.app / 'Contents/Helpers'
        self.assertEqual(sorted(path.name for path in helpers.iterdir()), ['IntentsAutomationNode', 'agent-device-macos-helper'])
        self.assertTrue(os.access(helpers / 'IntentsAutomationNode', os.X_OK))
        self.assertEqual((self.resources / 'Notices/Node-LICENSE.txt').read_text(), 'node license\n')
        self.assertTrue((self.resources / 'HostTemplates/AutomationHost.swift').is_file())
        self.assertTrue((self.resources / 'dist/src/index.js').is_file())
        self.assertTrue((self.resources / 'provenance/attestation.json').is_file())
        for name in ['package.json', 'package-lock.json', 'dependencies.lock.json']: self.assertTrue((self.resources / name).is_file())
    def testFailedInstalledProvenanceNeverWritesManifest(self):
        self.environment['STUB_FAIL'] = '--root '
        result = self.run_script('--app', self.app)
        self.assertEqual(result.returncode, 41)
        names = [Path(call[1]).name for call in self.calls('uname', 'npm')]
        self.assertEqual(names[-1], 'verify_dependency_provenance.py')
        self.assertNotIn('bundle_manifest.py', names)
    def testFailedPatchNeverReachesInstalledProvenanceOrManifest(self):
        self.environment['STUB_FAIL'] = r'apply_sdk_lifecycle_patch\.py'
        result = self.run_script('--app', self.app)
        self.assertEqual(result.returncode, 41)
        self.assertEqual([Path(call[1]).name for call in self.calls('uname', 'npm')],
            ['verify_dependency_provenance.py', 'apply_sdk_lifecycle_patch.py'])

class AutomationPrepareRuntimeTests(StubbedReleaseScriptCase):
    """Builder host and pinned private Node guards with stubbed provisioning, Node and npm."""
    script_name = 'automation_prepare_runtime.sh'
    def setUp(self):
        super().setUp()
        for name in ['uname', 'python3']: self.command(self.commands, name)
        self.command(self.commands, 'node', 'system-node'); self.command(self.commands, 'npm', 'system-npm')
        self.command(self.private_bin, 'node'); self.command(self.private_bin, 'npm')
        self.script_stub('automation_build.sh')
    def testArgumentsAreRejected(self):
        result = self.run_script('--fast')
        self.assertEqual(result.returncode, 2); self.assertIn('usage:', result.stderr)
        self.assertEqual(self.calls(), [])
    def testUnqualifiedHostsExitBeforeProvisioning(self):
        for system, machine in [('Linux', 'arm64'), ('Darwin', 'x86_64'), ('Linux', 'x86_64')]:
            with self.subTest(system=system, machine=machine):
                self.log.unlink(missing_ok=True)
                self.environment.update(STUB_UNAME_S=system, STUB_UNAME_M=machine)
                result = self.run_script()
                self.assertEqual(result.returncode, 2); self.assertIn('Only the arm64 macOS runtime builder', result.stderr)
                self.assertEqual(self.calls('uname'), [])
    def testFailedProvisioningStopsBeforeNodeOrNpm(self):
        self.environment['STUB_FAIL'] = r'provision_runtime\.py'
        result = self.run_script()
        self.assertEqual(result.returncode, 41)
        self.assertEqual([call[0] for call in self.calls('uname')], ['python3'])
    def testPinnedNodeVersionMismatchStopsBeforeNpm(self):
        self.environment['STUB_NODE_VERSION'] = 'v24.20.0'
        result = self.run_script()
        self.assertEqual(result.returncode, 2); self.assertIn('Pinned private Node version mismatch', result.stderr)
        self.assertEqual(self.calls('uname'), [
            ['python3', str(self.automation / 'scripts/provision_runtime.py')], ['node', '--version']])
    def testPrivateRuntimeTakesPrecedenceThenInstallsAndBuilds(self):
        result = self.run_script(); self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls('uname'), [
            ['python3', str(self.automation / 'scripts/provision_runtime.py')],
            ['node', '--version'],
            ['npm', 'ci', '--prefix', str(self.automation), '--ignore-scripts', '--no-audit', '--no-fund', '--cache', str(self.root / 'npm cache')],
            ['automation_build.sh']])
    def testFailedInstallNeverBuilds(self):
        self.environment['STUB_FAIL'] = '^npm ci'
        result = self.run_script()
        self.assertEqual(result.returncode, 41)
        self.assertEqual([call[0] for call in self.calls('uname')], ['python3', 'node', 'npm'])

class AutomationSignRuntimeTests(StubbedReleaseScriptCase):
    """Nested signing targets and entitlement placement with a stubbed codesign."""
    script_name = 'automation_sign_runtime.sh'
    identity = 'Developer ID Application: Example (TEAM123)'
    def setUp(self):
        super().setUp()
        for name in ['codesign', 'python3']: self.command(self.commands, name)
        self.app = self.root / 'Staged Intents.app'
        self.manifest = self.app / 'Contents/Resources/Automation/runtime-manifest.json'
        self.manifest.parent.mkdir(parents=True); self.manifest.write_text('{}\n')
    def testInvalidArgumentsExitBeforeSigning(self):
        for arguments in [(), ('--app', self.app), ('--app', self.app, '--identity'), ('--identity', 'x', '--app', self.app)]:
            with self.subTest(arguments=arguments):
                result = self.run_script(*arguments)
                self.assertEqual(result.returncode, 2); self.assertIn('usage:', result.stderr)
        self.assertEqual(self.calls(), [])
    def testUnstagedRuntimeIsNeverSigned(self):
        self.manifest.unlink()
        result = self.run_script('--app', self.app, '--identity', self.identity)
        self.assertEqual(result.returncode, 2); self.assertIn('Runtime must be staged first', result.stderr)
        self.assertEqual(self.calls(), [])
    def testOnlyNodeReceivesEntitlementsAndManifestIsRewrittenLast(self):
        result = self.run_script('--app', self.app, '--identity', self.identity)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        signing, manifest = calls[:-1], calls[-1]
        self.assertEqual([call[0] for call in signing], ['codesign'] * 4)
        self.assertEqual([call[-1] for call in signing], [
            str(self.app / 'Contents/Resources/Automation/node_modules/fsevents/fsevents.node'),
            str(self.app / 'Contents/Resources/Automation/node_modules/@esbuild/darwin-arm64/bin/esbuild'),
            str(self.app / 'Contents/Helpers/agent-device-macos-helper'),
            str(self.app / 'Contents/Helpers/IntentsAutomationNode')])
        entitlements = str(self.root / 'Integration/AutomationRuntime/Node.entitlements')
        for call in signing:
            with self.subTest(target=Path(call[-1]).name):
                self.assertEqual(call[1:5], ['--force', '--options', 'runtime', '--timestamp'])
                self.assertEqual(call[call.index('--sign') + 1], self.identity)
                if call[-1].endswith('/IntentsAutomationNode'):
                    self.assertEqual(call[call.index('--entitlements') + 1], entitlements)
                else:
                    self.assertNotIn('--entitlements', call)
        self.assertEqual(manifest, ['python3', str(self.root / 'Tools/IntentsAutomation/scripts/bundle_manifest.py'),
            '--app', str(self.app), '--write'])
    def testFailedNestedSignatureStopsSigningAndManifestRewrite(self):
        self.environment['STUB_FAIL'] = 'agent-device-macos-helper$'
        result = self.run_script('--app', self.app, '--identity', self.identity)
        self.assertEqual(result.returncode, 41)
        self.assertEqual([Path(call[-1]).name for call in self.calls()], ['fsevents.node', 'esbuild', 'agent-device-macos-helper'])
    def testNodeEntitlementsGrantOnlyJIT(self):
        with (SOURCE.parent / 'Integration/AutomationRuntime/Node.entitlements').open('rb') as source:
            self.assertEqual(plistlib.load(source), {'com.apple.security.cs.allow-jit': True})

if __name__ == '__main__': unittest.main()
