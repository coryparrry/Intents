import importlib.util
import base64
import hashlib
import io
import json
import shutil
import tempfile
import tarfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('provenance', ROOT / 'scripts/verify_dependency_provenance.py')
provenance = importlib.util.module_from_spec(spec); spec.loader.exec_module(provenance)


class DependencyProvenanceTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(dir='/private/tmp'); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        for name in ('package.json', 'package-lock.json', 'dependencies.lock.json'):
            shutil.copy2(ROOT / name, self.root / name)
        shutil.copytree(ROOT / 'provenance', self.root / 'provenance')
        lock = json.loads((self.root / 'dependencies.lock.json').read_text())
        for name, entry in lock['packages'].items():
            for relative in ['package.json', *entry['publicationEvidence']['declarationSHA256']]:
                target = self.root / 'node_modules' / name / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / 'node_modules' / name / relative, target)

    def change(self, path, mutation):
        file = self.root / path; data = json.loads(file.read_text()); mutation(data)
        file.write_text(json.dumps(data))

    def test_matches_reviewed_artifact_declarations_without_inventing_commit_correspondence(self):
        result = provenance.verify(self.root)
        self.assertEqual(result['e2e']['sourceCorrespondence'], 'publishedGitHeadAbsent')
        self.assertEqual(result['agent-device']['sourceCorrespondence'], 'publishedRevisionDiffersFromDesign')
        self.assertFalse(result['e2e']['archiveBytesVerified'])
        self.assertEqual(result['e2e']['declarationsVerified'], 248)

    def test_lock_and_direct_version_drift_rejected(self):
        self.change('package-lock.json', lambda d: d['packages']['node_modules/e2e'].update(integrity='changed'))
        with self.assertRaisesRegex(ValueError, 'locks disagree'): provenance.verify(self.root)
        shutil.copy2(ROOT / 'package-lock.json', self.root / 'package-lock.json')
        self.change('package.json', lambda d: d['dependencies'].update(e2e='^0.17.0'))
        with self.assertRaisesRegex(ValueError, 'exact reviewed pin'): provenance.verify(self.root)

    def test_metadata_and_installed_declaration_drift_rejected(self):
        file = self.root / 'provenance/e2e-0.17.0-npm.json'; original = file.read_bytes(); file.write_bytes(original + b' ')
        with self.assertRaisesRegex(ValueError, 'metadata changed'): provenance.verify(self.root)
        file.write_bytes(original)
        types = self.root / 'node_modules/e2e/dist/engine/index.d.ts'; types.write_text('export {};')
        with self.assertRaisesRegex(ValueError, 'declarations differ'): provenance.verify(self.root)

    def test_published_revision_cannot_be_relabelled_as_design_or_unchanged_runtime(self):
        self.change('dependencies.lock.json', lambda d: d['packages']['agent-device'].update(publishedSourceRevision=d['packages']['agent-device']['referenceSourceRevision']))
        with self.assertRaisesRegex(ValueError, 'revisions'): provenance.verify(self.root)
        shutil.copy2(ROOT / 'dependencies.lock.json', self.root / 'dependencies.lock.json')
        self.change('dependencies.lock.json', lambda d: d['packages']['e2e'].update(runtimeArtifactKind='published-npm'))
        with self.assertRaisesRegex(ValueError, 'Patched runtime'): provenance.verify(self.root)

    def test_aliases_and_missing_required_export_are_rejected(self):
        file = self.root / 'node_modules/e2e/dist/engine/index.d.ts'
        file.unlink(); file.symlink_to(ROOT / 'node_modules/e2e/dist/engine/index.d.ts')
        with self.assertRaisesRegex(ValueError, 'Aliased'): provenance.verify(self.root)
        file.unlink(); shutil.copy2(ROOT / 'node_modules/e2e/dist/engine/index.d.ts', file)
        self.change('node_modules/e2e/package.json', lambda d: d['exports'].pop('./engine'))
        with self.assertRaisesRegex(ValueError, 'identity changed'): provenance.verify(self.root)

    def test_false_correspondence_and_unbounded_inventory_rejected(self):
        self.change('dependencies.lock.json', lambda d: d['packages']['e2e']['publicationEvidence'].update(sourceCorrespondenceDisposition='publishedRevisionMatchesDesign'))
        with self.assertRaisesRegex(ValueError, 'overstated'): provenance.verify(self.root)
        shutil.copy2(ROOT / 'dependencies.lock.json', self.root / 'dependencies.lock.json')
        self.change('dependencies.lock.json', lambda d: d['packages']['e2e']['publicationEvidence'].update(declarationSHA256={}))
        with self.assertRaisesRegex(ValueError, 'bounded'): provenance.verify(self.root)

    def synthetic_archives(self, duplicate=False, omit=False):
        """Synthetic bytes exercise validation branches; not upstream artifact qualification."""
        folder = self.root / 'synthetic-archives'; folder.mkdir(exist_ok=True)
        lock = json.loads((self.root / 'dependencies.lock.json').read_text())
        npm = json.loads((self.root / 'package-lock.json').read_text())
        for name, pin in lock['packages'].items():
            archive = folder / (name + '-' + pin['version'] + '.tgz')
            with tarfile.open(archive, 'w:gz') as tar:
                paths = list(pin['publicationEvidence']['declarationSHA256'])
                if name == 'e2e' and omit: paths.pop()
                if name == 'e2e' and duplicate: paths.append(paths[0])
                for relative in paths:
                    raw = (self.root / 'node_modules' / name / relative).read_bytes()
                    item = tarfile.TarInfo('package/' + relative); item.size = len(raw)
                    tar.addfile(item, io.BytesIO(raw))
            raw = archive.read_bytes()
            pin['integrity'] = 'sha512-' + base64.b64encode(hashlib.sha512(raw).digest()).decode()
            pin['publicationEvidence']['tarballSHA256'] = hashlib.sha256(raw).hexdigest()
            npm['packages']['node_modules/' + name]['integrity'] = pin['integrity']
            metadata_file = self.root / pin['publicationEvidence']['metadataPath']
            metadata = json.loads(metadata_file.read_text()); metadata['dist']['integrity'] = pin['integrity']
            metadata_file.write_text(json.dumps(metadata))
            pin['publicationEvidence']['metadataSHA256'] = hashlib.sha256(metadata_file.read_bytes()).hexdigest()
        (self.root / 'dependencies.lock.json').write_text(json.dumps(lock))
        (self.root / 'package-lock.json').write_text(json.dumps(npm))
        return folder

    def test_optional_archive_mode_checks_bytes_and_inventory(self):
        folder = self.synthetic_archives()
        self.assertTrue(provenance.verify(self.root, folder)['e2e']['archiveBytesVerified'])
        with (folder / 'e2e-0.17.0.tgz').open('ab') as file: file.write(b'changed')
        with self.assertRaisesRegex(ValueError, 'Archive integrity mismatch'): provenance.verify(self.root, folder)

    def test_duplicate_archive_declarations_rejected_after_integrity_check(self):
        folder = self.synthetic_archives(duplicate=True)
        with self.assertRaisesRegex(ValueError, 'Duplicate'): provenance.verify(self.root, folder)

    def test_missing_archive_inventory_cannot_be_replaced_by_valid_sri(self):
        folder = self.synthetic_archives(omit=True)
        with self.assertRaisesRegex(ValueError, 'inventory mismatch'): provenance.verify(self.root, folder)

    def test_changed_module_interpretation_rejected(self):
        self.change('node_modules/e2e/package.json', lambda d: d.update(type='commonjs'))
        with self.assertRaisesRegex(ValueError, 'identity changed'): provenance.verify(self.root)


if __name__ == '__main__':
    unittest.main()
