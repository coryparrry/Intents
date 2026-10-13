"""Release app packaging must be independent of the removed UI sidecar."""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AutomationReleasePipelineTests(unittest.TestCase):
    def test_release_keeps_app_signing_and_notarization_without_ui_runtime(self):
        release = (ROOT / 'script/release.sh').read_text()
        for required in ['xcodebuild archive', 'xcodebuild -exportArchive',
                         'codesign --verify --strict --deep', 'notarytool submit',
                         'stapler staple', 'verify_installer.sh']:
            self.assertIn(required, release)
        for removed in ['automation_', 'INTENTS_MAC_RUNTIME', 'Tools/IntentsAutomation', 'npm']:
            self.assertNotIn(removed, release)

    def test_installer_ci_has_no_sidecar_artifact_requirement(self):
        workflow = (ROOT / '.github/workflows/package-installer.yml').read_text()
        self.assertIn('Build, sign, notarize, and verify installer', workflow)
        self.assertNotIn('INTENTS_MAC_RUNTIME', workflow)
        self.assertNotIn('automation_fetch_runtime', workflow)

    def test_debug_build_does_not_require_team_or_sidecar(self):
        build = (ROOT / 'script/build_and_run.sh').read_text()
        for removed in ['Tools/IntentsAutomation', 'automation_seal_app', 'verify-runtime',
                        'INTENTS_MAC_RUNTIME', 'DEVELOPMENT_TEAM=$', 'Developer ID']:
            self.assertNotIn(removed, build)
        self.assertIn('CODE_SIGN_IDENTITY=-', build)

    def test_legacy_sidecar_distribution_files_are_absent(self):
        self.assertFalse((ROOT / 'Tools/IntentsAutomation').exists())
        self.assertEqual(list((ROOT / 'script').glob('automation_*.sh')), [])
        self.assertFalse((ROOT / '.github/workflows/automation.yml').exists())


if __name__ == '__main__':
    unittest.main()
