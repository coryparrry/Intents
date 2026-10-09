import hashlib
import importlib.util
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

scripts = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(scripts))
spec = importlib.util.spec_from_file_location('mac_sdk_staging', scripts / 'stage_mac_sdk_ownership.py')
sdk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdk)


class MacSDKStagingTests(unittest.TestCase):
    def test_unknown_source_is_refused_before_copying(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root = Path(temporary).resolve(); source = root / 'source'; source.mkdir()
            path = source / 'helper.ts'; path.write_text('changed source')
            with patch.object(sdk, 'EXPECTED', {'helper.ts': hashlib.sha256(b'pinned source').hexdigest()}), patch.object(sdk, 'stage_native') as native:
                with self.assertRaisesRegex(ValueError, 'Pinned SDK source differs'):
                    sdk.stage(source, root / 'output')
                native.assert_not_called(); self.assertFalse((root / 'output').exists())

    def test_copied_source_is_rechecked_before_sdk_mutation(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root = Path(temporary).resolve(); source = root / 'source'; source.mkdir()
            path = source / 'helper.ts'; path.write_text('pinned source')
            expected = {'helper.ts': hashlib.sha256(path.read_bytes()).hexdigest()}
            def changed_copy(input_root, output_root, **options):
                shutil.copytree(input_root, output_root)
                (output_root / 'helper.ts').write_text('raced source')
                return {'baselineRevision': 'unused'}
            with patch.object(sdk, 'EXPECTED', expected), patch.object(sdk.session_patch, 'BASELINE', {}), patch.object(sdk, 'stage_native', side_effect=changed_copy):
                with self.assertRaisesRegex(ValueError, 'Pinned SDK source differs'):
                    sdk.stage(source, root / 'output')
            self.assertEqual(path.read_text(), 'pinned source')
            self.assertFalse((root / 'output/packages').exists())

    def test_alias_patch_paths_are_refused(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root = Path(temporary).resolve(); actual = root / 'actual.ts'; actual.write_text('source')
            alias = root / 'helper.ts'; alias.symlink_to(actual)
            with patch.object(sdk, 'EXPECTED', {'helper.ts': hashlib.sha256(actual.read_bytes()).hexdigest()}):
                with self.assertRaisesRegex(ValueError, 'Pinned SDK source differs'): sdk.verify(root)

    def test_ambiguous_patch_shape_never_writes(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root = Path(temporary).resolve(); path = root / 'helper.ts'; path.write_text('old old')
            with self.assertRaisesRegex(ValueError, 'patch shape differs'): sdk.replace(root, 'helper.ts', 'old', 'new')
            self.assertEqual(path.read_text(), 'old old')


if __name__ == '__main__': unittest.main()
