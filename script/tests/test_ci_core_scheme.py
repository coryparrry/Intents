"""Verify the generated scheme retains core coverage and never edits the source."""

import importlib.util
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "ci_core_scheme", ROOT / "script/ci_core_scheme.py"
)
scheme = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scheme)


class CoreSchemeTests(unittest.TestCase):
    def test_real_scheme_excludes_ui_and_preserves_core_and_build_settings(self):
        source = ROOT / scheme.SCHEMES / "FoundationEvals.xcscheme"
        before = source.read_bytes()
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "Core.xcscheme"
            scheme.create_core_scheme(source, output)
            tree = ET.parse(output)
        names = [
            node.get("BlueprintName")
            for node in tree.findall(
                "TestAction/Testables/TestableReference/BuildableReference"
            )
        ]
        self.assertEqual(names, ["FoundationEvalsTests"])
        self.assertEqual(source.read_bytes(), before)
        self.assertEqual(
            ET.tostring(tree.find("BuildAction")),
            ET.tostring(ET.fromstring(before).find("BuildAction")),
        )

    def test_core_scheme_retains_swift_testing_concurrency_limit(self):
        source = ROOT / scheme.SCHEMES / "FoundationEvals.xcscheme"
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "Core.xcscheme"
            scheme.create_core_scheme(source, output)
            test_action = ET.parse(output).find("TestAction")
        # TestAction must use its own environment, not LaunchAction's, so the
        # bounded Swift Testing scheduler also applies to CI build artifacts.
        self.assertEqual(test_action.get("shouldUseLaunchSchemeArgsEnv"), "NO")
        variables = {
            node.get("key"): (node.get("value"), node.get("isEnabled"))
            for node in test_action.findall("EnvironmentVariables/EnvironmentVariable")
        }
        self.assertEqual(
            variables.get("SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"),
            ("4", "YES"),
        )

    def test_missing_ui_or_core_target_fails_instead_of_omitting_tests(self):
        for name in ["FoundationEvalsUITests", "FoundationEvalsTests"]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                source = Path(temporary) / "Input.xcscheme"
                tree = ET.parse(ROOT / scheme.SCHEMES / "FoundationEvals.xcscheme")
                testables = tree.find("TestAction/Testables")
                for test in list(testables):
                    if test.find("BuildableReference").get("BlueprintName") == name:
                        testables.remove(test)
                tree.write(source)
                with self.assertRaises(ValueError):
                    scheme.create_core_scheme(
                        source, Path(temporary) / "Output.xcscheme"
                    )


if __name__ == "__main__":
    unittest.main()
