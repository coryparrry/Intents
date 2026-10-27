"""Regression checks for documentation on changed functions and its workflow contract."""

import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from script import changed_function_docs as changed
from script import docstring_coverage as coverage


class ChangedFunctionDocumentationTests(unittest.TestCase):
    """Use isolated Git histories to distinguish function edits from unrelated changes."""

    def setUp(self):
        """Create a synthetic repository without touching application data or user Git settings."""
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git('init', '-q')
        self.git('config', 'user.email', 'tests@example.invalid')
        self.git('config', 'user.name', 'Documentation test')

    def git(self, *args):
        """Run checked fixture-only Git commands and return their decoded output."""
        return changed.git(self.root, *args).decode().strip()

    def write(self, path, source):
        """Write one UTF-8 source fixture, creating its relative parent directories."""
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(source)

    def baseline(self, path, source):
        """Commit a fixture and return the immutable comparison commit."""
        self.write(path, source)
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture baseline')
        return self.git('rev-parse', 'HEAD')

    def test_body_only_edits_require_docs_in_every_language(self):
        """Reject undocumented body changes even when signatures and line numbers stay fixed."""
        cases = {
            'sample.swift': ('func load() {\n return 1\n}\n', 'return 1', 'return 2'),
            'sample.py': ('def load():\n    return 1\n', 'return 1', 'return 2'),
            'sample.mjs': ('function load() {\n return 1;\n}\n', 'return 1', 'return 2'),
            'sample.ts': ('const load = (): number => {\n return 1;\n};\n', 'return 1', 'return 2'),
            'sample.sh': ('load() {\n echo 1\n}\n', 'echo 1', 'echo 2'),
        }
        for path, (source, _, _) in cases.items():
            self.write(path, source)
        self.git('add', '.')
        self.git('commit', '-qm', 'multilingual baseline')
        base = self.git('rev-parse', 'HEAD')
        for path, (source, old, new) in cases.items():
            self.write(path, source.replace(old, new))
        result = changed.changed_declarations(self.root, base)
        self.assertEqual({item.path for item in result}, set(cases))
        self.assertTrue(all(not item.documented for item in result))

    def test_line_shifts_and_deleted_functions_do_not_flag_survivors(self):
        """Allow unchanged legacy functions after preceding code is inserted or removed."""
        base = self.baseline('sample.swift', 'func removed() {}\nfunc legacy() { return 1 }\n')
        self.write('sample.swift', '// A file-level change.\n\nfunc legacy() { return 1 }\n')
        self.assertEqual(changed.changed_declarations(self.root, base), [])

    def test_documentation_removal_is_a_function_change(self):
        """Prevent a documentation-only deletion from passing without a body change."""
        base = self.baseline('sample.swift', '/// Read the saved value.\n@MainActor\nfunc load() {}\n')
        self.write('sample.swift', '@MainActor\nfunc load() {}\n')
        result = changed.changed_declarations(self.root, base)
        self.assertEqual([(item.name, item.documented) for item in result], [('load', False)])

    def test_changed_tests_are_included_but_fixtures_are_excluded(self):
        """Require test helpers and test methods to document their purpose without parsing fixtures."""
        base = self.baseline('README.md', 'Synthetic repository.\n')
        self.write('Tests/ExampleTests.swift', 'func checksRecovery() {}\n')
        self.write('script/tests/test_example.py', 'def test_recovery(): pass\n')
        self.write('ui/example.test.mjs', 'function helper() {}\n')
        self.write('examples/fixtures/broken.py', 'This is deliberately not Python.\n')
        self.assertEqual(len(changed.changed_declarations(self.root, base)), 3)
        self.assertIsNone(coverage.source_language('Tests/ExampleTests.swift'))

    def test_documented_changes_and_no_function_changes_pass(self):
        """Keep the changed-function gate independent of the overall percentage denominator."""
        base = self.baseline('sample.py', 'def legacy(): return 1\n')
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(changed.main(['--root', str(self.root), '--base', base]), 0)
        self.write('sample.py', 'def legacy(): return 1\n\ndef fresh():\n    """Return an isolated fixture value."""\n    return 2\n')
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(changed.main(['--root', str(self.root), '--base', base, '--json']), 0)
        self.assertEqual(json.loads(output.getvalue())['changed'], 1)

    def test_nested_functions_overloads_and_duplicate_additions(self):
        """Do not let one unchanged body excuse an undocumented duplicate or nested addition."""
        base = self.baseline('sample.swift', 'func same() {}\n')
        self.write('sample.swift', 'func same() {}\nfunc same() {}\nfunc outer() { func nested() {} }\n')
        self.assertEqual([item.name for item in changed.changed_declarations(self.root, base)],
                         ['same', 'nested', 'outer'])

    def test_protocol_requirements_stop_before_the_next_member(self):
        """Keep bodyless Swift requirements independent from adjacent documented implementations."""
        source = 'protocol P {\n func legacy()\n static func edited()\n}\n'
        base = self.baseline('sample.swift', source)
        self.write('sample.swift', source.replace('edited()', 'edited(value: Int)'))
        self.assertEqual([item.name for item in changed.changed_declarations(self.root, base)], ['edited'])

    def test_invalid_base_and_parse_failures_fail_closed(self):
        """Never turn unavailable comparison evidence or malformed authored code into a pass."""
        base = self.baseline('sample.py', 'def legacy(): pass\n')
        for comparison, source in [('not-a-commit', 'def legacy(): pass\n'), (base, 'def broken(:\n')]:
            self.write('sample.py', source)
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(changed.main(['--root', str(self.root), '--base', comparison]), 2)

    def test_renamed_files_and_documented_shell_body_changes(self):
        """Require comments after a file move and retain shell bodies containing quoted braces."""
        base = self.baseline('old.sh', '# Print the selected value.\nload() {\n echo "}"\n echo 1\n}\n')
        self.git('mv', 'old.sh', 'new.sh')
        self.write('new.sh', '# Print the selected value.\nload() {\n echo "}"\n echo 2\n}\n')
        result = changed.changed_declarations(self.root, base)
        self.assertEqual([(item.path, item.documented) for item in result], [('new.sh', True)])
        self.assertEqual(result[0].end_line, 5)

    def test_shell_literals_cannot_truncate_a_changed_body(self):
        """Keep braces in arguments and case patterns inside the complete function span."""
        source = 'load() {\n echo }\n case "$x" in\n [}]) echo one ;;\n esac\n echo before\n}\n'
        base = self.baseline('sample.sh', source)
        self.write('sample.sh', source.replace('echo before', 'echo after'))
        result = changed.changed_declarations(self.root, base)
        self.assertEqual([(item.name, item.end_line) for item in result], [('load', 7)])

    def test_embedded_script_doc_removal_is_not_hidden_by_source_mapping(self):
        """Reject removed embedded JSDoc even when the containing JavaScript body is unchanged."""
        source = 'const html = `<script>\n/** Read retained state. */\nfunction load() { return 1; }\n</script>`;\n'
        base = self.baseline('sample.mjs', source)
        self.write('sample.mjs', source.replace('/** Read retained state. */', ''))
        result = changed.changed_declarations(self.root, base)
        self.assertEqual([(item.name, item.documented) for item in result], [('load', False)])

    def test_workflow_uses_complete_history_and_immutable_event_refs(self):
        """Keep both coverage gates and their comparison evidence wired into PR and main CI."""
        workflow = (coverage.ROOT / '.github/workflows/docstrings.yml').read_text()
        for required in ['fetch-depth: 0', 'ref: ${{ github.event.pull_request.head.sha || github.sha }}',
                         'script/docstring_coverage.py --minimum 81',
                         'script/changed_function_docs.py --base "$base"',
                         'github.event.pull_request.base.sha', 'github.event.pull_request.head.sha',
                         'github.event.before', 'git merge-base "$PR_BASE_SHA" "$PR_HEAD_SHA"']:
            self.assertIn(required, workflow)


if __name__ == '__main__':
    unittest.main()
