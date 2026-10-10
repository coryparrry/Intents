import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("ci_skip_guard", Path(__file__).resolve().parents[1] / "ci_skip_guard.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def case(suite: str, test: str, outcome: str) -> str:
    return f"Test Case '-[IntentsAutomationCoreTests.{suite} {test}]' {outcome} (0.001 seconds).\n"


class SkipGuardTests(unittest.TestCase):
    def test_passing_suite_has_no_problems(self):
        output = case("A", "testOne", "passed") + case("B", "testTwo", "failed")
        self.assertEqual(guard.evaluate(output, ["A", "B"], set()), [])

    def test_unexpected_skip_is_reported(self):
        output = case("A", "testOne", "passed") + case("A", "testTwo", "skipped")
        self.assertEqual(guard.evaluate(output, ["A"], set()), ["Unexpected skip: A/testTwo"])

    def test_allowed_skip_is_ignored(self):
        output = case("A", "testOne", "skipped") + case("A", "testTwo", "passed")
        self.assertEqual(guard.evaluate(output, ["A"], {"A/testOne"}), [])

    def test_suite_without_tests_is_reported(self):
        output = case("Other", "testOne", "skipped")
        self.assertEqual(guard.evaluate(output, ["A"], set()), ["No tests ran for A"])

    def test_unselected_suites_are_ignored(self):
        output = case("A", "testOne", "passed") + case("Other", "testTwo", "skipped")
        self.assertEqual(guard.evaluate(output, ["A"], set()), [])


if __name__ == "__main__":
    unittest.main()
