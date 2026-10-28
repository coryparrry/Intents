import hashlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_validation import (
    PRODUCTION_QUALIFICATION_STEP,
    REQUIRED_CHECKS,
    validate_app_metadata,
    validate_checks,
    verify_checksum,
)


class ReleaseValidationTests(unittest.TestCase):
    def test_all_required_jobs_must_succeed(self):
        """Source release gates require successful workers and production qualification."""
        jobs = [{"name": name, "conclusion": "success", "steps": [
            {"name": PRODUCTION_QUALIFICATION_STEP, "conclusion": "success"},
        ]} for name in REQUIRED_CHECKS]
        validate_checks(jobs)
        for conclusion in ("failure", "cancelled", "skipped", "neutral", None):
            with self.subTest(conclusion=conclusion), self.assertRaises(ValueError):
                validate_checks([dict(job, conclusion=conclusion) for job in jobs])

    def test_missing_skipped_or_failed_production_qualification_cannot_authorize_release(self):
        """Legacy successful runs and unexecuted qualification cannot approve an installer."""
        for conclusion in (None, "failure", "cancelled", "skipped", "neutral"):
            with self.subTest(conclusion=conclusion):
                jobs = [{"name": name, "conclusion": "success"} for name in REQUIRED_CHECKS]
                regression = next(job for job in jobs if job["name"] == "Portable regression tests")
                if conclusion is not None:
                    regression["steps"] = [{"name": PRODUCTION_QUALIFICATION_STEP, "conclusion": conclusion}]
                with self.assertRaisesRegex(ValueError, "production recovery"):
                    validate_checks(jobs)

    def test_legacy_compile_only_ci_cannot_authorize_release(self):
        with self.assertRaises(ValueError):
            validate_checks(
                [{"name": "Compile app and tests", "conclusion": "success"}]
            )

    def test_signed_metadata_must_match_both_tag_version_and_commit(self):
        commit = "a" * 40
        info = {
            "CFBundleDisplayName": "Intents",
            "CFBundleName": "Intents",
            "CFBundleShortVersionString": "1.2.3",
            "FoundationEvalsSourceCommit": commit,
        }
        validate_app_metadata(info, "1.2.3", commit)
        for display_name in (None, "", "Foundation Evals"):
            with self.subTest(display_name=display_name), self.assertRaises(ValueError):
                validate_app_metadata(
                    dict(info, CFBundleDisplayName=display_name), "1.2.3", commit
                )
        for bundle_name in (None, "", "FoundationEvals"):
            with self.subTest(bundle_name=bundle_name), self.assertRaises(ValueError):
                validate_app_metadata(
                    dict(info, CFBundleName=bundle_name), "1.2.3", commit
                )
        with self.assertRaises(ValueError):
            validate_app_metadata(info, "1.2.4", commit)
        for source in (None, "", "b" * 40):
            with self.subTest(source=source), self.assertRaises(ValueError):
                validate_app_metadata(
                    dict(info, FoundationEvalsSourceCommit=source), "1.2.3", commit
                )

    def test_installer_integrity_and_filename_are_both_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            filename = "Intents-1.2.3-macOS-arm64.dmg"
            installer = directory / filename
            installer.write_bytes(b"signed installer fixture")
            digest = hashlib.sha256(installer.read_bytes()).hexdigest()
            checksum = directory / "SHA256SUMS.txt"
            checksum.write_text(f"{digest}  {filename}\n")
            self.assertEqual(verify_checksum(directory, filename), digest)
            installer.write_bytes(b"modified installer")
            with self.assertRaises(ValueError):
                verify_checksum(directory, filename)
            for name in ("../" + filename, "another.dmg", filename + "\nextra entry"):
                checksum.write_text(f"{digest}  {name}\n")
                with self.subTest(name=name), self.assertRaises(ValueError):
                    verify_checksum(directory, filename)


if __name__ == "__main__":
    unittest.main()
