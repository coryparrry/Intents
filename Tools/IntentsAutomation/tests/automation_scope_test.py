from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
TESTS = ROOT / 'Tools/IntentsAutomation/tests'
SCRIPT = ROOT / 'script/automation_test.sh'


class AutomationScopeTests(unittest.TestCase):
    def test_every_script_level_suite_is_invoked_by_automation_test(self):
        script = SCRIPT.read_text()
        invoked = set(re.findall(r'Tools/IntentsAutomation/tests/([A-Za-z0-9_]+_test\.(?:py|mjs))', script))
        suites = {path.name for pattern in ['*_test.py', '*_test.mjs'] for path in TESTS.glob(pattern)}
        self.assertEqual(sorted(suites - invoked), [])
        self.assertEqual(sorted(invoked - suites), [])


if __name__ == '__main__': unittest.main()
