import hashlib
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

tests = Path(__file__).resolve().parent
scripts = tests.parent / 'scripts'
sys.path.insert(0, str(scripts)); sys.path.insert(0, str(tests))
import mac_sdk_session_patch as session_patch
import mac_staging_fixtures as fixtures
spec = importlib.util.spec_from_file_location('mac_sdk_staging', scripts / 'stage_mac_sdk_ownership.py')
sdk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdk)

TARGET_IMPORT = "import type { MacApplicationTarget } from '@agent-device/contracts/mac-application-target';\n"
LOCAL_IMPORT = "import type { MacApplicationTarget } from './mac-application-target.ts';\n"


class MacSDKSessionPatchTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir='/private/tmp'); self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()

    def read(self, name):
        return (self.root / name).read_text()

    def test_fixture_covers_every_pinned_session_file(self):
        self.assertEqual(set(fixtures.SESSION_SEAMS), set(session_patch.BASELINE))

    def test_patch_injects_owned_route_guards_and_returns_written_digests(self):
        fixtures.write_session_tree(self.root)
        digests = session_patch.patch(self.root, sdk.replace)
        self.assertEqual(set(digests), set(session_patch.BASELINE))
        for name, digest in digests.items():
            self.assertEqual(hashlib.sha256((self.root / name).read_bytes()).hexdigest(), digest)
        scope = self.read('src/daemon/request-execution-scope.ts')
        self.assertIn("if (existingSession?.applicationTarget && !['open', 'snapshot', 'press'].includes(lockedReq.command)) {", scope)
        self.assertIn("error: {code: 'UNSUPPORTED_OPERATION',", scope)
        self.assertIn('applicationTarget: sessionStore.get(scope.sessionName)?.applicationTarget,', scope)
        session_open = self.read('src/daemon/session-lifecycle/internal/session-open.ts')
        self.assertIn('if (session.applicationTarget && (req.flags?.macBundlePath !== session.applicationTarget.canonicalBundlePath ||\n'
                      '      req.positionals?.[0] !== session.applicationTarget.bundleId)) {', session_open)
        self.assertIn("return invalidOpenArgs('Owned Mac reopen requires the same explicit bundle ID and application path');", session_open)
        self.assertEqual(session_open.count('      macBundlePath: req.flags?.macBundlePath,\n'), 2)
        lifecycle = self.read('packages/platform-apple/src/lifecycle.ts')
        self.assertIn("if (binding.device.platform !== 'macos' || input.surface !== 'frontmost-app' || !input.target ||", lifecycle)
        self.assertIn('input.positionals.length !== 1 || input.positionals[0] !== input.target || input.relaunch ||', lifecycle)
        self.assertIn("throw new AppError('INVALID_ARGS', 'Owned Mac open requires one literal bundle ID, its path and app surface');", lifecycle)
        self.assertLess(lifecycle.index("throw new AppError('INVALID_ARGS'"), lifecycle.index('runMacOsOwnedApplicationOpen(input.target'))
        prepare = self.read('src/daemon/session-lifecycle/internal/session-open-prepare.ts')
        self.assertIn("return invalidOpenArgs('Owned Mac selection requires a Mac app surface and literal bundle ID');", prepare)
        self.assertIn("catch { return invalidOpenArgs('Invalid exact Mac application selection'); }", prepare)
        capture = self.read('src/daemon/snapshot-capture.ts')
        self.assertEqual(capture.count('      applicationTarget: session?.applicationTarget,'), 2)
        self.assertIn('const deferred = params.session?.applicationTarget ? undefined : await resolveDeferredInteractionOutcome({', capture)
        self.assertIn('const fallbackScreenshot = session?.applicationTarget ? undefined : await captureSparseFallbackScreenshot({',
                      self.read('src/daemon/snapshot-runtime.ts'))
        self.assertIn("'applicationTarget',", self.read('src/daemon/response-views.ts'))

    def test_type_imports_are_prepended_exactly_once(self):
        fixtures.write_session_tree(self.root)
        session_patch.patch(self.root, sdk.replace)
        for name in ['src/daemon/session-state.ts', 'src/core/dispatch-context.ts', 'src/daemon/snapshot-capture.ts',
                     'src/commands/capture/runtime/snapshot.ts', 'src/daemon/session-lifecycle/internal/session-open-surface.ts']:
            text = self.read(name)
            self.assertTrue(text.startswith(TARGET_IMPORT), name); self.assertEqual(text.count(TARGET_IMPORT), 1, name)
        for name in ['packages/contracts/src/client-app.ts', 'packages/contracts/src/client-capture.ts',
                     'packages/contracts/src/application-lifecycle-runtime.ts', 'packages/contracts/src/snapshot-types.ts']:
            text = self.read(name)
            self.assertTrue(text.startswith(LOCAL_IMPORT), name); self.assertEqual(text.count(LOCAL_IMPORT), 1, name)
        self.assertTrue(self.read('src/agent-device-client.ts').startswith(
            "import {parseMacApplicationTarget} from '@agent-device/contracts/mac-application-target';\n"))

    def test_missing_seam_is_refused(self):
        fixtures.write_session_tree(self.root, {'src/daemon/request-execution-scope.ts': fixtures.session_source(
            ['          surface: sessionStore.get(scope.sessionName)?.surface,'])})
        with self.assertRaisesRegex(ValueError, 'patch shape differs: src/daemon/request-execution-scope.ts'):
            session_patch.patch(self.root, sdk.replace)
        self.assertNotIn('UNSUPPORTED_OPERATION', self.read('src/daemon/request-execution-scope.ts'))

    def test_doubled_seam_is_refused(self):
        seams = fixtures.SESSION_SEAMS['packages/platform-apple/src/lifecycle.ts'] * 2
        fixtures.write_session_tree(self.root, {'packages/platform-apple/src/lifecycle.ts': fixtures.session_source(seams)})
        with self.assertRaisesRegex(ValueError, 'patch shape differs: packages/platform-apple/src/lifecycle.ts'):
            session_patch.patch(self.root, sdk.replace)
        self.assertNotIn('INVALID_ARGS', self.read('packages/platform-apple/src/lifecycle.ts'))

    def test_single_occurrence_of_counted_seam_is_refused(self):
        name = 'src/daemon/session-lifecycle/internal/session-open.ts'
        fixtures.write_session_tree(self.root, {name: fixtures.session_source(fixtures.SESSION_SEAMS[name][:2])})
        with self.assertRaisesRegex(ValueError, 'patch shape differs: ' + name):
            session_patch.patch(self.root, sdk.replace)

    def test_reapplying_to_patched_source_is_refused(self):
        fixtures.write_session_tree(self.root)
        session_patch.patch(self.root, sdk.replace)
        with self.assertRaisesRegex(ValueError, 'patch shape differs'):
            session_patch.patch(self.root, sdk.replace)

    def test_verify_accepts_pinned_tree_and_refuses_drift_and_aliases(self):
        digests = fixtures.write_session_tree(self.root)
        with patch.object(session_patch, 'BASELINE', digests):
            session_patch.verify(self.root)
            name = 'src/daemon/request-execution-scope.ts'
            path = self.root / name; original = path.read_bytes()
            path.write_bytes(original + b'// drift\n')
            with self.assertRaisesRegex(ValueError, 'Pinned SDK session source differs: ' + name): session_patch.verify(self.root)
            outside = self.root / 'outside.ts'; outside.write_bytes(original)
            path.unlink(); path.symlink_to(outside)
            with self.assertRaisesRegex(ValueError, 'Pinned SDK session source differs: ' + name): session_patch.verify(self.root)
            self.assertEqual(outside.read_bytes(), original)


if __name__ == '__main__': unittest.main()
