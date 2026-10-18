"""Check native shard selection and relocated test-product execution."""

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "ci_native_tests.py"
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("ci_native_tests", SCRIPT)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class NativeShardTests(unittest.TestCase):
    def test_ui_shard_reuses_build_and_disables_shared_desktop_workers(self):
        test = "FoundationEvalsUITests/AppAutomationUITests/testPreparationPickersUseStableIdentifiers"
        with patch.object(runner, "prepare_ui_xctestrun", return_value=Path("full.xctestrun")) as prepare:
            command = runner.test_command(Path("Products"), [test, test], Path("ui.xcresult"))
        prepare.assert_called_once_with(Path("Products"))
        self.assertEqual(command[:2], ["xcodebuild", "test-without-building"])
        self.assertEqual(command.count(f"-only-testing:{test}"), 1)
        self.assertEqual(command[command.index("-parallel-testing-enabled") + 1], "NO")
        self.assertNotIn("-test-iterations", command)

    def test_core_shard_keeps_parallel_execution_and_excludes_ui(self):
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary)
            descriptor = products / "FoundationEvalsCoreCI_macosx27.0-arm64.xctestrun"
            descriptor.touch()
            command = runner.test_command(products, ["FoundationEvalsTests"], Path("core.xcresult"))
        self.assertIn(str(descriptor), command)
        self.assertIn("-only-testing:FoundationEvalsTests", command)
        self.assertEqual(command[command.index("-parallel-testing-enabled") + 1], "YES")

    def test_missing_or_ambiguous_descriptors_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary)
            for names in ([], ["FoundationEvals_macosx27.xctestrun", "FoundationEvalsCoreCI_macosx27.xctestrun"]):
                for name in names:
                    (products / name).touch()
                with self.assertRaisesRegex(ValueError, "exactly one"):
                    runner.test_command(products, ["FoundationEvalsTests"], Path("result"))

    def test_invalid_and_empty_selections_fail_before_descriptor_access(self):
        for selection in ([], None, {}, [None], ["--help"], ["FoundationEvalsUITests/Foo/../../bad"], ["OtherTests"]):
            with self.subTest(selection=selection), patch.object(runner, "prepare_ui_xctestrun") as prepare:
                with self.assertRaises(ValueError):
                    runner.test_command(Path("missing"), selection, Path("result"))
                prepare.assert_not_called()

    def test_repetitions_are_explicit_and_positive(self):
        with patch.object(runner, "prepare_ui_xctestrun", return_value=Path("ui.xctestrun")):
            command = runner.test_command(Path("Products"), ["FoundationEvalsUITests/Foo/testPicker"], Path("result"), 10)
            self.assertEqual(command[command.index("-test-iterations") + 1], "10")
            for iterations in (0, -1, True):
                with self.assertRaises(ValueError):
                    runner.test_command(Path("Products"), ["FoundationEvalsUITests/Foo"], Path("result"), iterations)

    def test_each_selected_class_or_method_must_have_passed(self):
        log = "Test Case '-[FoundationEvalsUITests.Foo testPicker]' passed (1.0 seconds)."
        runner.verify_ui_selection(log, ["FoundationEvalsUITests/Foo", "FoundationEvalsUITests/Foo/testPicker"])
        for test in ("FoundationEvalsUITests/Other", "FoundationEvalsUITests/Foo/testRemoved"):
            with self.assertRaisesRegex(ValueError, "did not pass"):
                runner.verify_ui_selection(log, [test])

    def test_failed_skipped_or_zero_tests_are_not_a_successful_selection(self):
        for outcome in ("failed", "skipped", "started"):
            with self.assertRaises(ValueError):
                runner.verify_ui_selection(f"Test Case '-[Foo testPicker]' {outcome}", ["FoundationEvalsUITests/Foo"])
        with self.assertRaises(ValueError):
            runner.verify_ui_selection("Executed 0 tests", ["FoundationEvalsUITests/Foo"])

    def test_passing_sibling_does_not_hide_a_selected_skipped_method(self):
        log = "\n".join([
            "Test Case '-[FoundationEvalsUITests.Foo testOrdinary]' passed (1.0 seconds).",
            "Test Case '-[FoundationEvalsUITests.Foo testLive]' skipped (0.1 seconds).",
        ])
        for selection in (["FoundationEvalsUITests"], ["FoundationEvalsUITests/Foo"],
                          ["FoundationEvalsUITests/Foo/testLive"]):
            with self.subTest(selection=selection), self.assertRaisesRegex(
                ValueError, "Selected UI test was skipped: FoundationEvalsUITests/Foo/testLive"
            ):
                runner.verify_ui_selection(log, selection)
        runner.verify_ui_selection(log, ["FoundationEvalsUITests/Foo/testOrdinary"])

    def test_native_swift_testing_symbols_are_checked_independently_of_display_names(self):
        document = {"testNodes": [{"children": [{
            "nodeType": "Test Case", "name": "A friendly display name", "result": "Passed",
            "nodeIdentifierURL": "test://com.apple.xcode/Plan/FoundationEvalsTests/FooTests/checkValue",
        }]}]}
        runner.verify_native_selection(document, ["FoundationEvalsTests", "FoundationEvalsTests/FooTests"])
        for missing in ("FoundationEvalsTests/OtherFooTests", "FoundationEvalsTests/FooTestsExtra"):
            with self.assertRaisesRegex(ValueError, "did not pass"):
                runner.verify_native_selection(document, [missing])

    def test_each_native_suite_must_have_a_passing_case(self):
        for result in ("Failed", "Skipped"):
            document = {"testNodes": [{
                "nodeType": "Test Case", "result": result,
                "nodeIdentifierURL": "test://com.apple.xcode/Plan/FoundationEvalsTests/FooTests/checkValue",
            }]}
            with self.assertRaises(ValueError):
                runner.verify_native_selection(document, ["FoundationEvalsTests/FooTests"])
        with self.assertRaises(ValueError):
            runner.verify_native_selection({"testNodes": []}, ["FoundationEvalsTests"])

    def test_malformed_native_results_fail_instead_of_accepting_zero_tests(self):
        for document in ({}, {"testNodes": None}, {"testNodes": [None]}):
            with self.assertRaises(ValueError):
                runner.verify_native_selection(document, ["FoundationEvalsTests"])


if __name__ == "__main__":
    unittest.main()
