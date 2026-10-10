import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

CHECK = Path(__file__).resolve().parent / 'private_mac_runtime_import_test.mjs'
ADAPTER_CHECK = Path(__file__).resolve().parent / 'private_mac_sdk_adapter_test.mjs'
CONNECTOR = Path(__file__).resolve().parents[1] / 'dist/src/macOwnedSDKTransport.js'
NODE = os.environ.get('INTENTS_NODE') or shutil.which('node')
CLIENT = 'export function createAgentDeviceClient() { return {}; }\n'


@unittest.skipUnless(NODE, 'requires Node; automation_test.sh --scope sidecar provides the pinned runtime')
class PrivateMacRuntimeImportCheckTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir='/private/tmp'); self.addCleanup(self.directory.cleanup)
        self.runtime = Path(self.directory.name).resolve() / 'runtime'
        self.receipt = {'artifactVariant': 'private-owned-mac-source', 'customerRuntimeEnabled': False, 'hardwareQualified': False,
                        'helperRelativePath': 'helpers/agent-device-macos-helper'}

    def stage(self, modules, receipt=None):
        package = self.runtime / 'agent-device'
        exports = {}
        for name, (relative, source) in modules.items():
            path = package / relative; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(source)
            exports[name] = {'import': './' + relative}
        (package / 'package.json').write_text(json.dumps({'name': 'agent-device', 'type': 'module', 'exports': exports}))
        (self.runtime / 'intents-private-runtime.json').write_text(json.dumps(receipt or self.receipt))

    def check(self, helper=None):
        environment = {key: value for key, value in os.environ.items() if key != 'AGENT_DEVICE_MACOS_HELPER_BIN'}
        environment['AGENT_DEVICE_MACOS_HELPER_BIN'] = helper or str(self.runtime / self.receipt['helperRelativePath'])
        return subprocess.run([NODE, str(CHECK), str(self.runtime)], env=environment, capture_output=True, text=True, timeout=60)

    def assertRejected(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)

    def assertRejectedAt(self, result, statement):
        line = CHECK.read_text().splitlines().index(statement) + 1
        self.assertRejected(result, CHECK.name + ':' + str(line) + ':')

    def test_inert_runtime_exports_are_accepted(self):
        self.stage({'.': ('dist/src/index.js', CLIENT), './contracts': ('dist/src/contracts.js', 'export const version = 1;\n')})
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['exports'], ['.', './contracts'])
        self.assertEqual((report['processAttempts'], report['networkAttempts']), (0, 0))
        self.assertFalse(report['customerRuntimeEnabled']); self.assertFalse(report['helperInvoked'])

    def test_process_activation_on_import_is_rejected(self):
        spawn = "import {spawnSync} from 'node:child_process';\nspawnSync('/usr/bin/true');\n" + CLIENT
        self.stage({'.': ('dist/src/index.js', spawn)})
        self.assertRejected(self.check(), 'Export import attempted process activation')

    def test_swallowed_process_activation_is_still_counted(self):
        spawn = "import * as child from 'node:child_process';\ntry { child.execFile('/usr/bin/true'); } catch {}\n" + CLIENT
        self.stage({'.': ('dist/src/index.js', spawn)})
        self.assertRejectedAt(self.check(), 'assert.equal(processAttempts, 0);')

    def test_network_activation_on_import_is_rejected(self):
        self.stage({'.': ('dist/src/index.js', CLIENT), './telemetry': ('dist/src/telemetry.js', "try { fetch('https://example.invalid'); } catch {}\n")})
        self.assertRejectedAt(self.check(), 'assert.equal(networkAttempts, 0);')

    def test_runtime_boundary_and_layout_drift_is_rejected(self):
        for field, value in [('customerRuntimeEnabled', True), ('hardwareQualified', True), ('artifactVariant', 'customer')]:
            with self.subTest(field):
                self.stage({'.': ('dist/src/index.js', CLIENT)}, {**self.receipt, field: value})
                self.assertRejected(self.check(), 'AssertionError')
        self.stage({'.': ('dist/src/index.js', CLIENT)})
        self.assertRejected(self.check(helper='/usr/local/bin/agent-device-macos-helper'), 'AssertionError')
        self.stage({'.': ('src/index.js', CLIENT)})
        self.assertRejected(self.check(), 'AssertionError')
        self.stage({'.': ('dist/src/index.js', 'export const notAClient = true;\n')})
        self.assertRejected(self.check(), 'AssertionError')


# Minimal stand-in for the staged SDK client: maps typed calls onto daemon requests like the frozen client.
SDK_CLIENT = """export function createAgentDeviceClient(options, {transport}) {
  const flags = input => ({platform: input.platform, target: input.target, udid: input.udid});
  const call = async (command, positionals, input, extra = {}) => {
    const response = await transport({session: input.session ?? options.session, command, positionals, flags: {...flags(input), ...extra}});
    if (!response.ok) throw new Error('Synthetic SDK command failed: ' + command);
    return response.data;
  };
  return {
    apps: {open: async input => {
      const data = await call('open', [input.app], input, {macBundlePath: input.macBundlePath, surface: input.surface, relaunch: input.relaunch});
      return {...data, session: input.session, identifiers: {deviceId: data.id, session: input.session}};
    }},
    capture: {snapshot: async input => {
      const data = await call('snapshot', [], input, {depth: input.depth, raw: input.raw, forceFull: input.forceFull});
      return {...data, identifiers: {session: input.session, appId: data.appBundleId, appBundleId: data.appBundleId}};
    }},
    interactions: {press: input => call('press', [String(input.x), String(input.y)], input)},
  };
}
"""


@unittest.skipUnless(NODE and CONNECTOR.is_file(), 'requires Node and the built connector; automation_test.sh --scope sidecar builds both')
class PrivateMacSDKAdapterCheckTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir='/private/tmp'); self.addCleanup(self.directory.cleanup)
        self.runtime = Path(self.directory.name).resolve() / 'runtime'
        self.files = {'agent-device/package.json': json.dumps({'name': 'agent-device', 'type': 'module', 'exports': {'.': {'import': './dist/src/index.js'}}}),
                      'agent-device/dist/src/index.js': SDK_CLIENT,
                      'helpers/agent-device-macos-helper': '#!/bin/sh\nexit 64\n'}
        self.receipt = {'artifactVariant': 'private-owned-mac-source', 'customerRuntimeEnabled': False, 'hardwareQualified': False,
                        'helperRelativePath': 'helpers/agent-device-macos-helper'}

    def stage(self, files=None, receipt=None):
        files = files or self.files
        for relative, text in files.items():
            path = self.runtime / relative; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(text)
        digests = {relative: hashlib.sha256(text.encode()).hexdigest() for relative, text in files.items()}
        data = json.dumps(receipt or {**self.receipt, 'files': digests}, sort_keys=True).encode()
        (self.runtime / 'intents-private-runtime.json').write_bytes(data)
        return hashlib.sha256(data).hexdigest(), len(files)

    def check(self, receipt_sha256, count):
        environment = {**os.environ, 'AGENT_DEVICE_MACOS_HELPER_BIN': str(self.runtime / self.receipt['helperRelativePath'])}
        return subprocess.run([NODE, str(ADAPTER_CHECK), str(self.runtime), receipt_sha256, str(count)],
                              env=environment, capture_output=True, text=True, timeout=60)

    def assertRejected(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('ERR_ASSERTION', result.stderr)

    def test_owned_sdk_flow_runs_against_fixture_runtime(self):
        result = self.check(*self.stage())
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['sdkCommands'], ['open', 'snapshot', 'snapshot', 'press'])
        self.assertEqual((report['processAttempts'], report['fetchAttempts']), (0, 0))
        self.assertEqual(report['artifactVariant'], 'private-owned-mac-source')
        self.assertFalse(report['customerRuntimeEnabled']); self.assertFalse(report['hardwareQualified']); self.assertFalse(report['helperInvoked'])

    def test_receipt_pin_and_file_inventory_drift_are_rejected(self):
        digest, count = self.stage()
        self.assertRejected(self.check('0' * 64, count))
        self.assertRejected(self.check(digest, count + 1))
        (self.runtime / 'agent-device/extra.js').write_text('export {};\n')
        self.assertRejected(self.check(digest, count))

    def test_tampered_symlinked_or_hardlinked_runtime_files_are_rejected(self):
        digest, count = self.stage()
        client = self.runtime / 'agent-device/dist/src/index.js'
        client.write_text(SDK_CLIENT + '\n')
        self.assertRejected(self.check(digest, count))
        client.write_text(SDK_CLIENT)
        helper = self.runtime / self.receipt['helperRelativePath']
        outside = Path(self.directory.name) / 'outside-helper'; outside.write_bytes(helper.read_bytes())
        helper.unlink(); helper.symlink_to(outside)
        self.assertRejected(self.check(digest, count))
        helper.unlink(); os.link(outside, helper)
        self.assertRejected(self.check(digest, count))

    def test_enabled_runtime_boundary_is_rejected(self):
        for field in ['customerRuntimeEnabled', 'hardwareQualified']:
            with self.subTest(field):
                digests = {relative: hashlib.sha256(text.encode()).hexdigest() for relative, text in self.files.items()}
                self.assertRejected(self.check(*self.stage(receipt={**self.receipt, field: True, 'files': digests})))

    def test_process_activation_by_sdk_client_is_rejected(self):
        spawning = "import * as child from 'node:child_process';\n" + SDK_CLIENT.replace(
            "const response = await", "try { child.spawnSync('/usr/bin/true'); } catch {}\n    const response = await", 1)
        files = {**self.files, 'agent-device/dist/src/index.js': spawning}
        self.assertRejected(self.check(*self.stage(files)))


if __name__ == '__main__': unittest.main()
