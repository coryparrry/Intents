import contextlib
import hashlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
SCRIPT = ROOT / 'scripts/verify_qualification.py'
spec = importlib.util.spec_from_file_location('qualification', SCRIPT)
qualification = importlib.util.module_from_spec(spec); spec.loader.exec_module(qualification)
DEPENDENCY_DIGEST = hashlib.sha256((ROOT / 'dependencies.lock.json').read_bytes()).hexdigest()
TEMP_ROOT = '/private/tmp' if Path('/private/tmp').is_dir() else None


class VerifyQualificationTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(dir=TEMP_ROOT); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.profile_path = self.root / 'profile.json'
        self.profile = {
            'schemaVersion': 1, 'profileID': 'profile-1', 'targetID': 'target-1',
            'appBundleID': 'com.example.owned', 'productDigest': 'a' * 64,
            'dependencyDigest': DEPENDENCY_DIGEST, 'evidence': [],
        }
        self.add_evidence('evidence/launch.json', gate='launch', executedChecks=2)
        self.add_evidence('evidence/siri.json', gate='siri', executedChecks=3)

    def evidence_result(self, gate, **overrides):
        result = {key: self.profile[key] for key in ('targetID', 'appBundleID', 'productDigest', 'dependencyDigest')}
        result.update(gate=gate, qualified=True, executedChecks=1, evidenceKind='appleExecution')
        result.update(overrides)
        return result

    def add_evidence(self, relative, gate, **overrides):
        file = self.root / relative
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(json.dumps(self.evidence_result(gate, **overrides)))
        self.profile['evidence'].append({'path': relative, 'sha256': hashlib.sha256(file.read_bytes()).hexdigest(), 'gate': gate})

    def rewrite_evidence(self, index, **overrides):
        record = self.profile['evidence'][index]
        file = self.root / record['path']
        result = json.loads(file.read_text()); result.update(overrides)
        file.write_text(json.dumps(result))
        record['sha256'] = hashlib.sha256(file.read_bytes()).hexdigest()

    def verify(self):
        self.profile_path.write_text(json.dumps(self.profile))
        output = io.StringIO()
        with contextlib.redirect_stdout(output): qualification.verify(self.profile_path)
        return json.loads(output.getvalue())

    def assertRejected(self, message):
        with self.assertRaises(ValueError) as context: self.verify()
        self.assertEqual(str(context.exception), message)

    def run_cli(self, *arguments):
        return subprocess.run([sys.executable, str(SCRIPT), *arguments], capture_output=True, text=True)

    def test_valid_profile_reports_integrity_without_granting_route_qualification(self):
        self.assertEqual(self.verify(), {
            'profileID': 'profile-1', 'dependencyDigest': DEPENDENCY_DIGEST, 'executedChecks': 5,
            'integrityChecked': True, 'routeQualification': False,
        })

    def test_extra_or_missing_profile_keys_rejected(self):
        self.profile['routeQualification'] = True
        self.assertRejected('Malformed qualification profile')
        del self.profile['routeQualification']; del self.profile['productDigest']
        self.assertRejected('Malformed qualification profile')

    def test_unsupported_schema_version_rejected(self):
        for version in (0, 2, '1', None):
            self.profile['schemaVersion'] = version
            self.assertRejected('Malformed qualification profile')

    def test_dependency_digest_must_match_current_lock(self):
        self.profile['dependencyDigest'] = 'b' * 64
        self.assertRejected('Dependency identity changed')

    def test_empty_evidence_rejected(self):
        self.profile['evidence'] = []
        self.assertRejected('Zero hardware checks executed')

    def test_malformed_evidence_reference_rejected(self):
        self.profile['evidence'][1]['qualified'] = True
        self.assertRejected('Malformed evidence reference')
        del self.profile['evidence'][1]['qualified']; del self.profile['evidence'][1]['gate']
        self.assertRejected('Malformed evidence reference')

    def test_absolute_and_parent_traversal_paths_rejected(self):
        outside = self.root.parent / (self.root.name + '-outside.json')
        for path in (str(self.root / 'evidence/launch.json'), str(outside), '../outside.json', 'evidence/../evidence/launch.json'):
            self.profile['evidence'][0]['path'] = path
            self.assertRejected('Invalid evidence path')

    def test_symlinked_evidence_file_rejected(self):
        (self.root / 'evidence/alias.json').symlink_to(self.root / 'evidence/launch.json')
        self.profile['evidence'][0]['path'] = 'evidence/alias.json'
        self.assertRejected('Symlink evidence is forbidden')

    def test_symlinked_parent_directory_rejected(self):
        (self.root / 'linked').symlink_to(self.root / 'evidence', target_is_directory=True)
        self.profile['evidence'][0]['path'] = 'linked/launch.json'
        self.assertRejected('Symlink evidence is forbidden')

    def test_symlink_to_evidence_outside_profile_rejected(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as other:
            outside = Path(other) / 'launch.json'
            outside.write_bytes((self.root / 'evidence/launch.json').read_bytes())
            (self.root / 'evidence/launch.json').unlink()
            (self.root / 'evidence/launch.json').symlink_to(outside)
            self.assertRejected('Symlink evidence is forbidden')

    def test_evidence_hash_mismatch_rejected(self):
        self.profile['evidence'][1]['sha256'] = 'c' * 64
        self.assertRejected('Evidence integrity mismatch')

    def test_tampered_evidence_bytes_rejected(self):
        with (self.root / 'evidence/siri.json').open('ab') as file: file.write(b' ')
        self.assertRejected('Evidence integrity mismatch')

    def test_each_identity_field_must_match_profile(self):
        for key in ('targetID', 'appBundleID', 'productDigest', 'dependencyDigest'):
            with self.subTest(key=key):
                self.setUp()
                self.rewrite_evidence(1, **{key: 'other'})
                self.assertRejected('Evidence identity mismatch: ' + key)
                self.setUp()
                record = self.root / self.profile['evidence'][0]['path']
                result = json.loads(record.read_text()); del result[key]; record.write_text(json.dumps(result))
                self.profile['evidence'][0]['sha256'] = hashlib.sha256(record.read_bytes()).hexdigest()
                self.assertRejected('Evidence identity mismatch: ' + key)

    def test_gate_must_match_reference(self):
        self.rewrite_evidence(1, gate='launch')
        self.assertRejected('Gate is not qualified by executed evidence: siri')

    def test_unqualified_evidence_rejected(self):
        for qualified in (False, 'true', 1, None):
            with self.subTest(qualified=qualified):
                self.setUp()
                self.rewrite_evidence(0, qualified=qualified)
                self.assertRejected('Gate is not qualified by executed evidence: launch')

    def test_zero_or_missing_executed_checks_rejected(self):
        self.rewrite_evidence(0, executedChecks=0)
        self.assertRejected('Gate is not qualified by executed evidence: launch')
        self.setUp()
        record = self.root / 'evidence/launch.json'
        result = json.loads(record.read_text()); del result['executedChecks']; record.write_text(json.dumps(result))
        self.profile['evidence'][0]['sha256'] = hashlib.sha256(record.read_bytes()).hexdigest()
        self.assertRejected('Gate is not qualified by executed evidence: launch')

    def test_fake_or_unlabelled_evidence_does_not_qualify_hardware(self):
        self.rewrite_evidence(1, evidenceKind='fake')
        self.assertRejected('Fakes do not qualify hardware')
        self.setUp()
        record = self.root / 'evidence/siri.json'
        result = json.loads(record.read_text()); del result['evidenceKind']; record.write_text(json.dumps(result))
        self.profile['evidence'][1]['sha256'] = hashlib.sha256(record.read_bytes()).hexdigest()
        self.assertRejected('Fakes do not qualify hardware')

    def test_cli_prints_summary_for_valid_profile(self):
        self.profile_path.write_text(json.dumps(self.profile))
        completed = self.run_cli('--profile', str(self.profile_path))
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(completed.stdout)['executedChecks'], 5)
        self.assertFalse(json.loads(completed.stdout)['routeQualification'])

    def test_cli_exits_one_for_rejected_malformed_or_missing_profiles(self):
        self.rewrite_evidence(1, evidenceKind='fake')
        self.profile_path.write_text(json.dumps(self.profile))
        cases = {'Fakes do not qualify hardware': self.profile_path}
        malformed = self.root / 'malformed.json'; malformed.write_text('{')
        cases['Expecting property name'] = malformed
        cases['No such file'] = self.root / 'missing.json'
        partial = self.root / 'partial.json'; partial.write_text(json.dumps(self.profile))
        cases['launch.json'] = partial
        for message, path in cases.items():
            with self.subTest(message=message):
                if path == partial: (self.root / 'evidence/launch.json').unlink()
                completed = self.run_cli('--profile', str(path))
                self.assertEqual(completed.returncode, 1)
                self.assertEqual(completed.stdout, '')
                self.assertIn(message, completed.stderr)

    def test_verify_report_scope_routes_profile_to_verifier(self):
        self.profile['evidence'][0]['sha256'] = 'c' * 64
        self.profile_path.write_text(json.dumps(self.profile))
        script = REPO / 'script/automation_test.sh'
        completed = subprocess.run(['bash', str(script), '--scope', 'verify-report', '--profile', str(self.profile_path)], capture_output=True, text=True)
        self.assertEqual(completed.returncode, 1)
        self.assertIn('Evidence integrity mismatch', completed.stderr)
        completed = subprocess.run(['bash', str(script), '--scope', 'verify-report'], capture_output=True, text=True)
        self.assertEqual(completed.returncode, 2)
        self.assertIn('exact authorised integration profile', completed.stderr)


if __name__ == '__main__':
    unittest.main()
