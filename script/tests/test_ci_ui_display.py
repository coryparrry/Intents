import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ci_ui_display', ROOT / 'script/ci_ui_display.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


def mode(width, height, identifier=1, scale=1):
    return dict(width=width, height=height, id=identifier,
                pixelWidth=width * scale, pixelHeight=height * scale)


class UIDisplayTests(unittest.TestCase):
    def test_retina_backing_pixels_do_not_count_as_desktop_space(self):
        self.assertIsNone(helper.select_mode([mode(1024, 768, scale=2)]))

    def test_both_desktop_dimensions_are_required(self):
        self.assertIsNone(helper.select_mode([mode(1920, 900), mode(1400, 1200)]))
        self.assertFalse(helper.adequate(dict(width=1600, height=999)))

    def test_smallest_adequate_mode_is_selected_deterministically(self):
        modes = [mode(1920, 1080, 3), mode(1600, 1200, 2), mode(1600, 1000, 7)]
        self.assertEqual(helper.select_mode(modes), modes[2])
        self.assertEqual(helper.select_mode(list(reversed(modes))), modes[2])

    def test_already_adequate_desktop_is_not_changed(self):
        display = Mock()
        display.probe.return_value = dict(width=1920, height=1080, modes=[])
        self.assertEqual(helper.prepare_display(display)['method'], 'already adequate')
        display.apply.assert_not_called()

    def test_mode_change_must_produce_measured_adequate_bounds(self):
        display = Mock()
        display.probe.side_effect = [dict(width=1024, height=768, modes=[mode(1600, 1000, 7)]),
                                     dict(width=1600, height=1000, modes=[])]
        self.assertEqual(helper.prepare_display(display)['method'], 'CoreGraphics')
        display.apply.assert_called_once_with(mode(1600, 1000, 7))

    def test_in_process_success_with_reverted_bounds_after_exit_is_not_a_pass(self):
        display = Mock()
        display.probe.return_value = dict(width=1024, height=768, modes=[mode(1600, 1000)])
        display.apply.return_value = dict(width=1600, height=1000, modes=[])
        tool = Mock()
        tool.is_file.return_value = False
        with self.assertRaisesRegex(RuntimeError, 'No supported display change'):
            helper.prepare_display(display, tool=tool)

    def test_missing_supported_mode_fails_without_running_an_installer(self):
        display, run, tool = Mock(), Mock(), Mock()
        display.probe.return_value = dict(width=1024, height=768, modes=[])
        tool.is_file.return_value = False
        with self.assertRaises(RuntimeError):
            helper.prepare_display(display, tool=tool, run=run)
        display.apply.assert_not_called()
        run.assert_not_called()

    @patch.object(helper.os, 'access', return_value=True)
    def test_bundled_vmware_fallback_is_remeasured_after_settling(self, access):
        display, run, sleep = Mock(), Mock(), Mock()
        display.probe.side_effect = [dict(width=1024, height=768, modes=[]), dict(width=1600, height=1000, modes=[])]
        run.return_value.returncode = 0
        tool = Path('/bundled/vmware-resolutionSet')
        with patch.object(Path, 'is_file', return_value=True):
            result = helper.prepare_display(display, tool=tool, run=run, sleep=sleep)
        self.assertEqual(result['method'], 'bundled VMware tool')
        sleep.assert_called_once_with(2)
        self.assertEqual(run.call_args.args[0], [str(tool), '1600', '1000'])
        self.assertEqual(run.call_args.kwargs['timeout'], 30)

    @patch.object(helper.os, 'access', return_value=True)
    def test_failed_bundled_tool_is_not_reported_as_success(self, access):
        display, run = Mock(), Mock()
        display.probe.return_value = dict(width=1024, height=768, modes=[])
        run.return_value.returncode = 1
        run.return_value.stderr = 'unsupported'
        with patch.object(Path, 'is_file', return_value=True):
            with self.assertRaisesRegex(RuntimeError, 'Bundled display tool failed'):
                helper.prepare_display(display, tool=Path('/bundled/tool'), run=run)


    @patch.object(helper.os, 'access', return_value=True)
    def test_successful_bundled_tool_with_undersized_bounds_is_not_a_pass(self, access):
        display, run = Mock(), Mock()
        display.probe.return_value = dict(width=1024, height=768, modes=[])
        run.return_value.returncode = 0
        with patch.object(Path, 'is_file', return_value=True):
            with self.assertRaisesRegex(RuntimeError, 'No supported display change'):
                helper.prepare_display(display, tool=Path('/bundled/tool'), run=run, sleep=Mock())

    @patch.object(helper.os, 'access', return_value=True)
    def test_rejected_public_mode_can_use_verified_bundled_fallback(self, access):
        display, run = Mock(), Mock()
        display.probe.side_effect = [dict(width=1024, height=768, modes=[mode(1600, 1000)]),
                                     dict(width=1600, height=1000, modes=[])]
        display.apply.side_effect = RuntimeError('unsupported mode')
        run.return_value.returncode = 0
        with patch.object(Path, 'is_file', return_value=True):
            result = helper.prepare_display(display, tool=Path('/bundled/tool'), run=run, sleep=Mock())
        self.assertEqual(result['method'], 'bundled VMware tool')

    @patch.object(helper.sys, 'platform', 'darwin')
    def test_local_display_mutation_is_rejected_before_native_access(self):
        with patch.dict(helper.os.environ, {}, clear=True), patch.object(helper.sys, 'argv', ['display']), patch.object(helper, 'NativeDisplay') as native:
            with self.assertRaises(SystemExit) as error:
                helper.main()
        self.assertEqual(error.exception.code, 2)
        native.assert_not_called()


if __name__ == '__main__':
    unittest.main()
