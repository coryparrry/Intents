"""Regression coverage for the source-only documentation inventory and CI threshold."""

import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from script import docstring_coverage as coverage


class SwiftCoverageTests(unittest.TestCase):
    """Exercise declaration recognition independently of a Swift compiler or SDK."""

    def test_all_function_forms_and_protocol_requirements(self):
        """Count nested functions, operators, and explicit lifecycle declarations once."""
        source = '''
protocol Service {
    /// Create a service from its persistent key.
    init?(key: String)
    func load() async throws -> String
    subscript(key: String) -> String { get }
}
class Concrete {
    /** Close the connection when the service releases it. */
    deinit {}
    init() { super.init(); let instance = Concrete.init(key: "x") }
    static func == (left: Self, right: Self) -> Bool { true }
    static func <(left: Self, right: Self) -> Bool { false }
    func outer<T>(_ value: T) { func nested() {} }
}
'''
        declarations = coverage.swift_declarations('Service.swift', source)
        self.assertEqual([item.name for item in declarations],
                         ['init', 'load', 'subscript', 'deinit', 'init', '==', '<', 'outer', 'nested'])
        self.assertEqual([item.name for item in declarations if item.documented], ['init', 'deinit'])

    def test_docs_cross_multiline_attributes_and_modifiers(self):
        """Attach docs before annotations without borrowing a previous declaration's docs."""
        source = '''
/// Read the current application state.
@available(
    macOS 26.0,
    message: "Use func misleading() instead"
)
@MainActor
public nonisolated(unsafe) static func read() {}
/** Write the next state. */
@Some.ModuleAttribute(value: (1, 2))
private(set) func write() {}
// Ordinary comments do not document a function.
func bare() {}
///
func blankLineDoc() {}
/** */
func blankBlockDoc() {}
func later() {}
'''
        declarations = coverage.swift_declarations('Annotated.swift', source)
        self.assertEqual([(item.name, item.documented) for item in declarations],
                         [('read', True), ('write', True), ('bare', False),
                          ('blankLineDoc', False), ('blankBlockDoc', False), ('later', False)])

    def test_nested_comments_and_raw_multiline_strings_are_not_code(self):
        """Ignore declaration examples and lifecycle calls in string and comment literals."""
        source = '\n'.join([
            '/* func hidden() {} /* init() {} */ subscript(a: Int) -> Int { 1 } */',
            'let normal = "func quoted() {} \\" not a deinit"',
            'let raw = ##"""',
            'func rawExample() {}',
            '""" is still part of the raw string',
            '/* /// func fakeDoc() */',
            '"""##',
            'let multiline = """',
            'func multilineExample() {}',
            '"""',
            '/// Read a real value.',
            'func real() { _ = Value.init() }',
        ])
        declarations = coverage.swift_declarations('Strings.swift', source)
        self.assertEqual([(item.name, item.documented) for item in declarations], [('real', True)])

    def test_interpolated_strings_regex_and_commented_init_calls(self):
        """Keep nested quoted examples and raw regex patterns out of the declaration census."""
        source = '\n'.join([
            r'let text = "value \(items.map { "func bogus() {}" })"',
            r'let raw = ##"value \##(items.map { #"func rawBogus() {}"# })"##',
            r'let pattern = #/func regexBogus() { init() }/#',
            r'let multilinePattern = ##/',
            r'func multilineRegexBogus() {}',
            r'/##',
            r'let instance = Type. /* an explanatory comment */ init()',
            r'/// Read the current selection.',
            r'func real() {}',
        ])
        self.assertEqual([(item.name, item.documented) for item in coverage.swift_declarations('Mixed.swift', source)],
                         [('real', True)])

    def test_swift_documentation_runs_allow_trailing_blank_markers(self):
        """Require text somewhere in a doc run while ordinary comments and code break it."""
        source = """
/// Read an integer.
///
func read() -> Int { 1 }
///
///
func blank() {}
/** Write the current value. */
///
/** */
func mixed() {}
/// Stale documentation.
// An ordinary comment breaks the documentation run.
func ordinaryBreak() {}
/// Document the preceding declaration.
func preceding() {}
func codeBreak() {}
/** */
///
func mixedBlank() {}
"""
        self.assertEqual({item.name: item.documented for item in coverage.swift_declarations('Runs.swift', source)},
                         {'read': True, 'blank': False, 'mixed': True, 'ordinaryBreak': False,
                          'preceding': True, 'codeBreak': False, 'mixedBlank': False})

    def test_bare_regex_patterns_do_not_invent_functions_or_hide_division(self):
        """Distinguish regex expression starts from division and slash operator definitions."""
        source = '\n'.join([
            r'let pattern = /func bogus\(\)/',
            r'let characterClass = /[/]func alsoBogus\(\)/',
            'let quotient = numerator / denominator',
            'let chained = 12/3/2',
            'let literalDivision = "left" / "right"',
            '/// Divide two values.',
            'func /(left: Value, right: Value) -> Value { left }',
            '/// Read the real value.',
            'func real() {}',
        ])
        self.assertEqual([(item.name, item.documented) for item in coverage.swift_declarations('Regex.swift', source)],
                         [('/', True), ('real', True)])

    def test_unterminated_swift_literals_fail_closed(self):
        """Reject lexical failures instead of returning an incomplete denominator."""
        for source in ['/* func hidden() {}', 'let x = #"unfinished', 'let x = """unfinished', 'let r = #/unfinished']:
            with self.subTest(source=source), self.assertRaises(ValueError):
                coverage.swift_declarations('Bad.swift', source)


class PythonAndShellCoverageTests(unittest.TestCase):
    """Exercise native Python docstrings and descriptive shell comment blocks."""

    def test_python_nested_async_and_literal_docstrings(self):
        """Require a nonempty first literal expression rather than comments or later strings."""
        source = '''
# A comment is not a Python docstring.
def plain():
    pass
async def documented():
    """Read data from the provider."""
    def nested():
        """Transform one response."""
        pass
def blank():
    "   "
def misplaced():
    value = 1
    "Too late to be a docstring."
'''
        declarations = coverage.python_declarations('tool.py', source)
        self.assertEqual({item.name: item.documented for item in declarations},
                         {'plain': False, 'documented': True, 'nested': True, 'blank': False, 'misplaced': False})
        with self.assertRaises(SyntaxError):
            coverage.python_declarations('bad.py', 'def incomplete(')

    def test_shell_comments_and_heredoc_examples(self):
        """Count named shell functions without counting function examples in heredocs."""
        source = '''#!/bin/sh
bare() { :; }
# Release resources owned by this invocation.
cleanup() { :; }
# Read the command-line switches.

function parse () { :; }
cat <<'EXAMPLE'
# This is only a documentation example.
fake() { :; }
EXAMPLE
#
empty() { :; }
'''
        self.assertEqual([(item.name, item.documented) for item in coverage.shell_declarations('tool.sh', source)],
                         [('bare', False), ('cleanup', True), ('parse', True), ('empty', False)])

    def test_shell_heredoc_mentions_in_quotes_and_multiline_examples(self):
        """Ignore heredoc-looking text and function examples within multiline shell quotes."""
        source = '\n'.join([
            'echo "Use <<EOF for heredocs"',
            'cat <<<EOF',
            '# Read the current environment.',
            'real() { :; }',
            'example="first line',
            'fake() { :; }',
            'last line"',
            "single='first line",
            'alsoFake() { :; }',
            "last line'",
            '# <<NOT_A_HEREDOC is only a comment.',
            'after() { :; }',
        ])
        self.assertEqual([(item.name, item.documented) for item in coverage.shell_declarations('Quoted.sh', source)],
                         [('real', True), ('after', True)])


class JavaScriptCoverageTests(unittest.TestCase):
    """Use the pinned production parser to cover JS, TS, and embedded preview scripts."""

    def parse(self, source, name='sample.mjs'):
        """Parse one temporary source through the same batched helper used by CI."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / name).write_text(source)
            return coverage.javascript_declarations(root, [name])

    def test_named_functions_exports_assigned_arrows_and_class_methods(self):
        """Count assigned expressions and methods while omitting anonymous call callbacks."""
        declarations = self.parse('''
/** Read the current state. */
export function load() {}
/** Transform one state. */
export const transform = (value) => value;
// This ordinary comment does not count.
const undocumented = function named() {};
const object = {
  /** Read one field. */ read() {},
  /** Set one field. */ write: value => value,
};
class Service {
  /** Retain the configuration. */ constructor() {}
  /** Resolve the current state. */ async resolve() {}
  /** Handle a private response. */ #handle() {}
  /** Handle a queued response. */ queued = () => {};
  get state() { return null; }
}
/** Replace the pending callback. */
object.changed = function () {};
items.map(value => value);
items.map(function callback(value) { return value; });
/** Return the default provider. */
export default function () {}
''')
        names = {item.name: item.documented for item in declarations}
        self.assertEqual(names, {'load': True, 'transform': True, 'undocumented': False, 'read': True,
                                 'write': True, 'constructor': True, 'resolve': True, '#handle': True,
                                 'queued': True, 'state': False, 'object.changed': True, 'callback': False,
                                 'default': True})

    def test_typescript_methods_declarations_and_jsx_arrows(self):
        """Retain authored type contracts and JSX components while using TS syntax."""
        declarations = self.parse('''
/** Resolve the current context. */
export declare function context<T>(value: T): Promise<T>;
interface Service {
  /** Read the stored value. */ read(key: string): string;
  missing(): void;
}
/** Render the selected case. */
export const Case = (props: { title: string }) => <div>{props.title}</div>;
''', 'sample.tsx')
        self.assertEqual({item.name: item.documented for item in declarations},
                         {'context': True, 'read': True, 'missing': False, 'Case': True})

    def test_blank_jsdoc_and_literal_examples_do_not_count(self):
        """Ignore blank markers, ordinary comments, strings, and regex examples."""
        declarations = self.parse('''
const text = "function falseExample() {}";
const pattern = /function hidden\\(\\)/;
/* Ordinary text. */ function ordinary() {}
/** */ function empty() {}
/*** */ function stars() {}
/** Real documentation. */ function real() {}
''')
        self.assertEqual({item.name: item.documented for item in declarations},
                         {'ordinary': False, 'empty': False, 'stars': False, 'real': True})

    def test_static_template_script_is_included_at_original_line(self):
        """Include preview host functions with source positions and their own JSDoc."""
        declarations = self.parse('''const host = `<html>
<script>
/** Return the frame context. */
function context() {}
const callback = () => {};
</script></html>`;
''')
        self.assertEqual([(item.name, item.line, item.documented) for item in declarations],
                         [('context', 4, True), ('callback', 5, False)])

    def test_cooked_template_scripts_preserve_original_lines(self):
        """Decode escaped backticks and newlines without moving declaration source locations."""
        declarations = self.parse(r'''const host = `<script>function label() { return \`label\`; }</script>`;''')
        self.assertEqual([(item.name, item.line) for item in declarations], [('label', 1)])
        declarations = self.parse(r'''const host = `<script>\nfunction first() {}\nfunction second() {}</script>`;''')
        self.assertEqual([(item.name, item.line) for item in declarations], [('first', 1), ('second', 1)])
        source = 'const host = `<script>\\\nfunction continued() {}\nfunction later() {}</script>`;'
        declarations = self.parse(source)
        self.assertEqual([(item.name, item.line) for item in declarations], [('continued', 2), ('later', 3)])

    def test_consecutive_typescript_wrappers_keep_assigned_functions(self):
        """Walk all assertion and satisfies wrappers to recover bindings and wrapper JSDoc."""
        declarations = self.parse('''
/** Read the current value. */
export const read = ((() => 1) as () => number) satisfies () => number;
/** Read a nullable value. */
export const nonnull = (((() => 1) as () => number)!) satisfies () => number;
''', 'wrapped.ts')
        self.assertEqual({item.name: item.documented for item in declarations}, {'read': True, 'nonnull': True})

    def test_parse_failure_including_embedded_script_fails_closed(self):
        """Do not silently omit a source file when Babel rejects its syntax."""
        for source in ['function incomplete(', 'const html = `<script>function broken(</script>`;']:
            with self.subTest(source=source), self.assertRaises(ValueError):
                self.parse(source)


class InventoryAndGateTests(unittest.TestCase):
    """Lock source exclusions, Git inventory behavior, and threshold semantics."""

    def test_scope_keeps_production_even_when_names_contain_testing(self):
        """Exclude fixtures and generated outputs without excluding real CLI or adapted source."""
        included = ['Package.swift', 'Sources/MacIntentTesting/Runner.swift',
                    'Sources/MacIntentTestingCLI/NativeTestsMain.swift',
                    'plugins/apple-foundation-evals/native/AppEngine/EvaluationRunner.swift',
                    'website/dist/app.js', 'examples/order_tool_server.py',
                    'script/test_production_evals.py', 'script/foundation-evals']
        excluded = ['Tests/Thing.swift', 'FoundationEvals/FoundationEvalsTests/Model.swift',
                    'examples/fixtures/case.py', 'script/tests/test_runner.py', 'ui/app.html',
                    'website/dist/vendor/gsap.min.js', 'node_modules/package/index.js',
                    'Sources/Model.generated.swift', 'ui/case.test.js', 'assets/demo.js']
        for path in included:
            with self.subTest(path=path):
                self.assertIsNotNone(coverage.source_language(path))
        for path in excluded:
            with self.subTest(path=path):
                self.assertIsNone(coverage.source_language(path))

    def test_git_inventory_untracked_ignored_and_path_filters(self):
        """Include nonignored work in progress, omit ignored files, and filter by full prefix."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / '.gitignore').write_text('ignored.py\n')
            (root / 'tracked.py').write_text('def tracked(): pass\n')
            subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
            (root / 'new.py').write_text('def new(): pass\n')
            (root / 'ignored.py').write_text('def ignored(): pass\n')
            self.assertEqual(coverage.git_sources(root, []), [('new.py', 'Python'), ('tracked.py', 'Python')])
            self.assertEqual(coverage.git_sources(root, ['./new.py']), [('new.py', 'Python')])
            self.assertEqual(coverage.git_sources(root, ['track']), [])

    def test_threshold_uses_unrounded_percentage_and_rejects_empty_inventory(self):
        """Require at least 81 percent exactly and prevent empty filters from passing a gate."""
        declarations = [coverage.Declaration('x.py', line, 'f', 'def', 'Python', line < 81)
                        for line in range(100)]
        for count, minimum, expected in [(100, '81', 0), (99, '82', 1), (0, '0', 1)]:
            with self.subTest(count=count, minimum=minimum), patch.object(coverage, 'measure', return_value=declarations[:count]), \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(coverage.main(['--json', '--minimum', minimum]), expected)
                report = json.loads(output.getvalue())
                self.assertEqual(report['total'], count)
                self.assertIn('languages', report)

    def test_missing_output_and_parser_failure_exit(self):
        """Keep counts complete when filtering missing output and propagate parser failures."""
        declarations = [coverage.Declaration('x.py', 1, 'covered', 'def', 'Python', True),
                        coverage.Declaration('x.py', 4, 'missing', 'def', 'Python', False)]
        with patch.object(coverage, 'measure', return_value=declarations), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(coverage.main(['--json', '--missing']), 0)
            report = json.loads(output.getvalue())
            self.assertEqual(report['total'], 2)
            self.assertEqual([item['name'] for item in report['declarations']], ['missing'])
        with patch.object(coverage, 'measure', side_effect=ValueError('bad syntax')), \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(coverage.main(['--minimum', '81']), 2)
            self.assertIn('bad syntax', errors.getvalue())


if __name__ == '__main__':
    unittest.main()
