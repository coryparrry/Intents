from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import patch_owned_mac_daemon as patcher


class OwnedMacDaemonPatchTests(unittest.TestCase):
    def fixture(self):
        pieces = [old for old, _ in patcher.REPLACEMENTS]
        pieces.append(patcher.REPLACEMENTS[-1][0])
        pieces.extend([patcher.STARTUP_BEGIN, 'owned-record recovery\n', patcher.STARTUP_END,
                       patcher.CLAIMS_BEGIN, 'claim reconciliation\n', patcher.CLAIMS_END])
        return '\n'.join(pieces).encode()

    def testConditionalIsolationKeepsRecoveryAndGuardsRequestsAndDrain(self):
        result = patcher.apply(self.fixture()).decode()
        self.assertIn('owned-record recovery', result)
        self.assertIn('claim reconciliation', result)
        self.assertEqual(result.count('    if (!options.intentsOwnedMac) {'), 2)
        self.assertIn('!crypto.timingSafeEqual(supplied, expected)', result)
        self.assertIn("!['open', 'snapshot', 'press'].includes(req.command)", result)
        self.assertIn('!options.intentsOwnedMac.admitRequest(req)', result)
        self.assertIn('inFlightRequestCount !== 0', result)
        self.assertIn('session.appLog || session.audioProbe || session.perfCapture || session.screenRecording', result)
        self.assertIn('await shutdownClaimLedger.releaseClaim(session)', result)
        self.assertIn('sessionStore.delete(session.name)', result)

    def testMissingOrDuplicateSeamRejected(self):
        data = self.fixture()
        for old, _ in patcher.REPLACEMENTS:
            with self.subTest(seam=old):
                with self.assertRaises(ValueError):
                    patcher.apply(data.replace(old.encode(), b'', 1))
                with self.assertRaises(ValueError):
                    patcher.apply(data + old.encode())

    def testRecoveryBlockMarkersMustBeUniqueAndOrdered(self):
        data = self.fixture()
        for begin, end in [(patcher.STARTUP_BEGIN, patcher.STARTUP_END), (patcher.CLAIMS_BEGIN, patcher.CLAIMS_END)]:
            for altered in [data.replace(end.encode(), b''), data + begin.encode(),
                            data.replace(begin.encode(), b'REVERSED').replace(end.encode(), begin.encode()).replace(b'REVERSED', end.encode())]:
                with self.assertRaises(ValueError):
                    patcher.apply(altered)

    def testAuxiliaryHTTPRoutesDeniedBeforeHandlers(self):
        data = (patcher.HTTP_OPTIONS + '}\n' + patcher.HTTP_HANDLER + 'upload-handler\n').encode()
        result = patcher.apply_http(data).decode()
        self.assertLess(result.index('Private Mac route denied'), result.index('upload-handler'))
        self.assertIn("req.method !== 'POST' || req.url !== '/rpc'", result)
        for marker in [patcher.HTTP_OPTIONS, patcher.HTTP_HANDLER]:
            with self.assertRaises(ValueError): patcher.apply_http(data.replace(marker.encode(), b''))
            with self.assertRaises(ValueError): patcher.apply_http(data + marker.encode())


if __name__ == '__main__':
    unittest.main()
