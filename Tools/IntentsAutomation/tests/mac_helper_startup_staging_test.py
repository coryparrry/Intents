import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import stage_mac_helper_startup_gate as gate


class MacHelperStartupStagingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir='/private/tmp')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.source = self.root / 'baseline'
        self.candidate = self.root / 'candidate'
        self.archive, self.checkpoint = self.root / 'archive', self.root / 'checkpoint'
        self.base = {gate.MAIN: ('func run() {\n' + gate.MARKER + '\n}\n').encode(),
                     gate.baseline.PREFIX + 'Package.swift': b'package',
                     gate.baseline.PREFIX + 'Tests/Original.swift': b'test'}
        for name, messages in gate.TEST_UPDATES.items():
            self.base[name] = ('\n'.join('XCTAssertEqual(message, "' + message + '")' for message in messages)).encode()
        for index in range(10):
            self.base[gate.baseline.PREFIX + f'Sources/Original{index}.swift'] = b'original'
        for name, data in self.base.items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        # Archive/checkpoint guarding has its own nine tests. This fixture isolates the ABI transformation.
        self.original = {'nativeInputsSHA256': {name: gate.baseline.digest(data) for name, data in self.base.items()}}
        stub = patch.object(gate.baseline, 'verify', return_value=self.original)
        stub.start(); self.addCleanup(stub.stop)

    def stage(self):
        return gate.stage(self.candidate, self.source, self.archive, self.checkpoint)

    def verify(self):
        return gate.verify(self.candidate, self.source, self.archive, self.checkpoint)

    def testSeparateDisabledSeventeenInputStageAndRecomputedVerification(self):
        receipt = self.stage()
        self.assertEqual(len(receipt['nativeInputsSHA256']), 17)
        self.assertFalse(receipt['customerRuntimeEnabled'])
        self.assertFalse(receipt['hardwareQualified'])
        self.assertEqual(receipt['helperABI'], 'startup-gate-v1')
        self.assertEqual(self.verify(), receipt)
        main = (self.candidate / gate.MAIN).read_text()
        self.assertLess(main.index('requireAcknowledgement()'), main.index(gate.MARKER))
        self.assertIn('arguments.count == 1', main)
        for name, data in self.base.items():
            self.assertEqual((self.source / name).read_bytes(), data)

    def testNeverOverwritesAnExistingDestination(self):
        self.stage()
        before = (self.candidate / gate.RECEIPT).read_bytes()
        with self.assertRaises(FileExistsError): self.stage()
        self.assertEqual((self.candidate / gate.RECEIPT).read_bytes(), before)

    def testBaselineOrDispatchSeamFailureCreatesNoOutput(self):
        (self.source / gate.MAIN).write_text('changed')
        with self.assertRaises(ValueError): self.stage()
        self.assertFalse(self.candidate.exists())
        self.original['nativeInputsSHA256'][gate.MAIN] = gate.baseline.digest(b'changed')
        with self.assertRaises(ValueError): self.stage()
        self.assertFalse(self.candidate.exists())

    def testForgedReceiptCannotBlessAlteredGate(self):
        receipt = self.stage()
        target = gate.ADDITIONS['MacHelperOwnershipGate.swift']
        (self.candidate / target).write_bytes(b'no gate')
        receipt['nativeInputsSHA256'][target] = gate.baseline.digest(b'no gate')
        (self.candidate / gate.RECEIPT).write_bytes(gate.receipt_bytes(receipt))
        with self.assertRaises(ValueError): self.verify()

    def testUnreviewedInputsAndVersionedManifestRejected(self):
        self.stage()
        for name in ['extra.json', gate.baseline.PREFIX + 'Package@swift-6.0.swift',
                     gate.baseline.PREFIX + 'Sources/Unreviewed.swift']:
            path = self.candidate / name; path.write_bytes(b'extra')
            with self.assertRaises(ValueError): self.verify()
            path.unlink()

    def testSymlinkAndHardlinkInputsRejected(self):
        self.stage()
        path = self.candidate / gate.ADDITIONS['MacHelperOwnershipGate.swift']
        data = path.read_bytes(); path.unlink()
        target = self.root / 'other'; target.write_bytes(data)
        path.symlink_to(target)
        with self.assertRaises(ValueError): self.verify()
        path.unlink(); os.link(target, path)
        with self.assertRaises(ValueError): self.verify()

    def testLockOrTemplateAlterationCreatesNoOutput(self):
        templates = self.root / 'templates'; shutil.copytree(gate.TEMPLATES, templates)
        with patch.object(gate, 'TEMPLATES', templates):
            path = templates / 'MacHelperOwnershipGate.swift'; path.write_bytes(b'changed')
            with self.assertRaises(ValueError): self.stage()
            self.assertFalse(self.candidate.exists())
            lock = templates / 'native-startup-gate-lock.json'
            record = json.loads(lock.read_bytes()); record['customerRuntimeEnabled'] = True
            lock.write_text(json.dumps(record))
            with self.assertRaises(ValueError): self.stage()
            self.assertFalse(self.candidate.exists())

    def testReceiptBoundaryAlterationRejected(self):
        receipt = self.stage(); receipt['helperInvoked'] = True
        (self.candidate / gate.RECEIPT).write_bytes(gate.receipt_bytes(receipt))
        with self.assertRaises(ValueError): self.verify()


if __name__ == '__main__':
    unittest.main()
