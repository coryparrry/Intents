from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
TESTS = ROOT / 'Tools/IntentsAutomation/tests'
SCRIPT = ROOT / 'script/automation_test.sh'
SUITE = re.compile(r'Tools/IntentsAutomation/tests/([A-Za-z0-9_]+_test\.(?:py|mjs))')


def invoked_suites(script):
    commands = (line.split('#', 1)[0] for line in script.splitlines())
    return {name for command in commands for name in SUITE.findall(command)}


class AutomationScopeTests(unittest.TestCase):
    def test_every_script_level_suite_is_invoked_by_automation_test(self):
        invoked = invoked_suites(SCRIPT.read_text())
        suites = {path.name for pattern in ['*_test.py', '*_test.mjs'] for path in TESTS.glob(pattern)}
        self.assertEqual(sorted(suites - invoked), [])
        self.assertEqual(sorted(invoked - suites), [])

    def test_commented_out_suites_do_not_count_as_invoked(self):
        script = ('    python3 Tools/IntentsAutomation/tests/a_test.py\n'
                  '    # python3 Tools/IntentsAutomation/tests/b_test.py\n'
                  '    true  # Tools/IntentsAutomation/tests/c_test.mjs\n')
        self.assertEqual(invoked_suites(script), {'a_test.py'})


if __name__ == '__main__': unittest.main()
