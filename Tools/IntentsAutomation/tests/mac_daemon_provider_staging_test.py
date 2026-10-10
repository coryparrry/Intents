import io
import json
import os
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import stage_mac_daemon_provider as stage


class MacDaemonProviderStagingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir='/private/tmp')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.source = self.root / 'baseline'
        self.candidate = self.root / 'candidate'
        self.archive = self.root / 'archive.tar.gz'
        self.checkpoint = self.root / 'checkpoint.json'
        self.inputs = {
            stage.RUNTIME: (stage.OPTIONS + '};\nfunction compose() {\n' + stage.PROVIDERS + '\n    },\n}\n').encode(),
            'tsdown.config.ts': ('const config = { entry: {\n' + stage.BUILD_ENTRY + '\n}};\n').encode(),
            'package.json': b'{"exports":{".":{"import":"./dist/src/index.js"}}}',
            'src/backend.ts': b'export type BackendSnapshotResult = {\n};',
            'src/daemon/server/http-server.ts': b'HTTP server fixture',
        }
        self.inputs['src/daemon/session-selector.ts'] = b"if (flags.udid && (!isIosFamily(device) || flags.udid !== device.id)) {"
        self.inputs['src/daemon/session-lifecycle/internal/session-open.ts'] = b'fixture'
        for index in range(15):
            self.inputs[stage.baseline.PREFIX + f'Sources/Original{index}.swift'] = b'original'
        sdk = {stage.RUNTIME: self.inputs[stage.RUNTIME],
               stage.LIFECYCLE: b"binding.device.platform !== 'macos'\ninput.macBundlePath, input.execution.signal)",
               stage.OWNERSHIP_TEST: (stage.TEMPLATES / 'intents-mac-sdk-ownership.test.ts').read_bytes(),
               'intents-mac-vitest.config.ts': b"include:['src/intents-mac-sdk-ownership.test.ts',",
               stage.OPEN_PREPARE: b"device.platform !== 'macos'"}
        sdk.update({f'src/patch{index}.ts': b'reviewed SDK' for index in range(31)})
        native_patches = dict(list((name, data) for name, data in self.inputs.items() if stage.baseline.native_input(name))[:9])
        record = {
            'sdkPatchedSourceSHA256': {name: stage.baseline.digest(data) for name, data in sdk.items()},
            'nativePatchedSourceSHA256': {name: stage.baseline.digest(data) for name, data in native_patches.items()},
        }
        for name, data in {**self.inputs, **sdk}.items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.checkpoint.write_text(json.dumps(record))
        self.write_archive()
        native = {name: data for name, data in self.inputs.items() if stage.baseline.native_input(name)}
        native.update({name: b'recomputed gate' for name in stage.gate.ADDITIONS.values()})
        # The baseline and gate validators have separate regression suites.
        self.start_patch(stage.gate, 'expected_inputs', return_value=(native, {'startupGateLockSHA256': stage.gate.LOCK_SHA256}))
        # Recovery-boundary seam validation has its own suite; this fixture isolates reconstruction.
        self.start_patch(stage.owned_daemon, 'apply', side_effect=lambda data: data)
        self.start_patch(stage.owned_daemon, 'apply_http', side_effect=lambda data: data)
        self.start_patch(stage.owned_daemon, 'apply_open_prepare', side_effect=lambda data: data)
        self.start_patch(stage.owned_daemon, 'apply_session_open', side_effect=lambda data: data)
        self.start_patch(stage.baseline, 'ARCHIVE_SHA256', stage.baseline.digest(self.archive.read_bytes()))
        self.start_patch(stage.baseline, 'CHECKPOINT_SHA256', stage.baseline.digest(self.checkpoint.read_bytes()))

    def start_patch(self, owner, name, *args, **kwargs):
        stub = patch.object(owner, name, *args, **kwargs)
        stub.start()
        self.addCleanup(stub.stop)

    def write_archive(self):
        with tarfile.open(self.archive, 'w:gz') as bundle:
            for name, data in self.inputs.items():
                member = tarfile.TarInfo('callstack-agent-device-' + stage.baseline.REVISION[:7] + '/' + name)
                member.size = len(data)
                bundle.addfile(member, io.BytesIO(data))

    def stage(self):
        return stage.stage(self.candidate, self.source, self.archive, self.checkpoint)

    def verify(self):
        return stage.verify(self.candidate, self.source, self.archive, self.checkpoint)

    def testCompositionExportAndDisabledBoundary(self):
        receipt = self.stage()
        self.assertEqual(self.verify(), receipt)
        runtime = (self.candidate / stage.RUNTIME).read_text()
        self.assertIn("PlatformProviderResolvers['appleToolProvider']", runtime)
        self.assertIn('...(options.appleToolProvider ? { appleToolProvider: options.appleToolProvider } : {})', runtime)
        self.assertIn('appleRunnerProvider: providerRuntimeProviders.appleRunnerProvider', runtime)
        lifecycle = (self.candidate / stage.LIFECYCLE).read_text()
        self.assertIn("binding.device.platform !== 'apple' || binding.device.appleOs !== 'macos'", lifecycle)
        self.assertIn('input.macBundlePath, binding.signal)', lifecycle)
        entry = (self.candidate / stage.ENTRY).read_text()
        self.assertIn("from '../platform-runtime/request-providers.ts'", entry)
        package = json.loads((self.candidate / 'package.json').read_bytes())
        self.assertTrue(package['private'])
        self.assertEqual(package['exports']['./intents-daemon']['import'], './dist/src/intents-daemon.js')
        for key in ['customerRuntimeEnabled', 'hardwareQualified', 'signed', 'daemonStarted', 'helperInvoked', 'uiInteracted']:
            self.assertIs(receipt[key], False)
        self.assertEqual(receipt['helperABI'], 'startup-gate-v1')
        for name, data in self.inputs.items():
            self.assertEqual((self.source / name).read_bytes(), data)

    def testExistingDestinationNeverOverwritten(self):
        self.stage()
        before = (self.candidate / stage.RECEIPT).read_bytes()
        with self.assertRaises(FileExistsError):
            self.stage()
        self.assertEqual(before, (self.candidate / stage.RECEIPT).read_bytes())

    def testUnreviewedBaselineExtrasAreNotCopied(self):
        extra = self.source / 'src/unreviewed.ts'
        extra.write_bytes(b'unsafe extension')
        self.stage()
        self.assertFalse((self.candidate / 'src/unreviewed.ts').exists())

    def testChangedReviewedSourceCreatesNoCandidate(self):
        (self.source / 'src/patch0.ts').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'Reviewed SDK source bytes'):
            self.stage()
        self.assertFalse(self.candidate.exists())

    def testMissingAndDuplicateSeamsCreateNoCandidate(self):
        for seam in [stage.OPTIONS, stage.PROVIDERS, stage.BUILD_ENTRY]:
            with self.subTest(seam=seam):
                for replacement in ['', seam + seam]:
                    original = stage.replace_once
                    def replace_seam(data, old, new):
                        if old == seam:
                            data = data.replace(seam.encode(), replacement.encode())
                        return original(data, old, new)
                    with patch.object(stage, 'replace_once', side_effect=replace_seam):
                        with self.assertRaisesRegex(ValueError, 'composition seam'):
                            self.stage()
                        self.assertFalse(self.candidate.exists())

    def testForgedReceiptCannotBlessChangedSource(self):
        receipt = self.stage()
        (self.candidate / stage.RUNTIME).write_bytes(b'changed')
        receipt['sourceInputsSHA256'][stage.RUNTIME] = stage.baseline.digest(b'changed')
        (self.candidate / stage.RECEIPT).write_bytes(stage.receipt_bytes(receipt))
        with self.assertRaisesRegex(ValueError, 'source bytes'):
            self.verify()

    def testAdditionalInputAndBoundaryAlterationsRejected(self):
        self.stage()
        for name in ['extra.json', stage.baseline.PREFIX + 'Package@swift-6.0.swift']:
            path = self.candidate / name
            path.write_bytes(b'extra')
            with self.assertRaisesRegex(ValueError, 'input set'):
                self.verify()
            path.unlink()
        receipt = self.verify()
        receipt['daemonStarted'] = True
        (self.candidate / stage.RECEIPT).write_bytes(stage.receipt_bytes(receipt))
        with self.assertRaisesRegex(ValueError, 'receipt differs'):
            self.verify()

    def testSymlinkAndHardlinkInputsRejected(self):
        self.stage()
        path = self.candidate / stage.ENTRY
        other = self.root / 'other'
        other.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(other)
        with self.assertRaises(ValueError):
            self.verify()
        path.unlink()
        os.link(other, path)
        with self.assertRaises(ValueError):
            self.verify()

    def testChangedTemplateOrLockCreatesNoCandidate(self):
        templates = self.root / 'templates'
        shutil.copytree(stage.TEMPLATES, templates)
        with patch.object(stage, 'TEMPLATES', templates):
            (templates / 'intents-daemon.ts').write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'daemon entry'):
                self.stage()
            self.assertFalse(self.candidate.exists())
            (templates / 'native-daemon-provider-lock.json').write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'provider lock'):
                self.stage()
            self.assertFalse(self.candidate.exists())


if __name__ == '__main__':
    unittest.main()
