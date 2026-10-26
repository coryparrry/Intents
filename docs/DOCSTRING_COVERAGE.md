# Function documentation coverage

Run the source-only gate from the repository root:

```sh
npm ci --prefix Tools/DocstringCoverage --ignore-scripts --no-audit --no-fund
python3 -m unittest script.tests.test_docstring_coverage
python3 script/docstring_coverage.py --minimum 81
```

The dedicated `Function documentation (81%)` GitHub Actions job runs these checks on every pull request and push to `main`. The general workflow-check job also installs the pinned parsers before running its selected Python tests. A percentage below 81 fails using the unrounded value. An empty declaration inventory fails a requested threshold, including `--minimum 0`. Inventory, file decoding, Python parsing, Babel parsing, and Swift lexical errors fail the command; files with errors are never silently dropped.

For an actionable list or machine-readable report:

```sh
python3 script/docstring_coverage.py --missing Sources/MacIntentTesting
python3 script/docstring_coverage.py --json --missing > /tmp/missing-docstrings.json
python3 script/docstring_coverage.py --minimum 81 --path script --path website
```

Positional paths and repeated `--path` options select repository-relative files or whole directory prefixes. All selected declarations contribute to the summary even when `--missing` restricts the listed results. JSON includes exact totals, percentages by language, and declaration paths, lines, names, kinds, and documentation flags. `--root` can inspect another Git checkout with the same methodology.

## Denominator

The inventory comes from `git ls-files --cached --others --exclude-standard`: existing tracked files and nonignored untracked files. Git-tracked authored files remain included even inside an otherwise ignored directory such as `website/dist`. Supported source includes Swift (including `Package.swift` and the extensionless `script/foundation-evals`), Python, JavaScript/JSX/MJS/CJS, TypeScript/TSX, and shell scripts.

Production includes `Sources/MacIntentTesting`, the native-test CLI, examples, automation and release scripts, `script/test_production_evals.py`, the plugin's adapted `native/AppEngine` sources, and the authored website scripts. Files inside test, fixture, build, dependency, vendor, or asset directories are excluded, as are conventional test/spec filenames, `*.generated.swift`, and `*.min.js`. Generated `ui/app.html` and other HTML bundles are outside the source inventory. The source of the interface remains included.

Counted declarations are:

- **Swift:** named functions and operators, explicit initializers, deinitializers, and subscripts, including nested declarations and protocol requirements. A lexer skips nested comments, normal/raw/multiline strings (including interpolation), and extended or expression-position bare-slash regex literals. Initializer calls such as `Type.init()` are omitted. This inventory does not require an Apple SDK or compile application code.
- **Python:** every AST function or async function definition, including methods and nested definitions.
- **JavaScript and TypeScript:** named function declarations/expressions, named object/class methods and constructors, assigned arrow/function expressions (variables, properties, and assignments), and declared function/method contracts. Anonymous callbacks passed directly to another function and function type annotations are excluded. Static `<script>` contents in HTML template literals, including the preview host, are parsed and counted with their original source line numbers. HTML parsing preserves tag boundaries, quoted attributes, and comments. Dynamic template interpolation is excluded from this embedded-script rule. Babel and parse5 are pinned in `Tools/DocstringCoverage/package-lock.json`; no global parser installation is used.
- **Shell:** named function definitions. Function examples within heredocs or quoted strings are skipped; quoted heredoc-like text does not suppress subsequent functions.

Implicit constructors, Swift computed properties/accessors, and anonymous closures are outside the denominator. All functions count equally; the percentage measures presence, not semantic quality or importance.

## Numerator and writing guidance

Swift requires a nonempty `///` or `/** ... */` comment immediately preceding the declaration or its modifiers/attributes. Multiline attributes are supported. Python requires a nonempty literal docstring as the first function-body statement. JavaScript/TypeScript requires nonempty JSDoc (`/** ... */`) on the function or its immediate assignment, declaration, property, or export wrapper. Shell accepts a preceding descriptive `#` comment block. Blank markers and ordinary Swift/JavaScript comments do not count.

Describe the function's purpose and meaningful behavior. For important boundaries, document inputs, returned values, side effects, failure conditions, and relevant lifecycle or concurrency rules. Explain the intent without simply repeating the function name. Review quality separately from this numeric gate; increasing a percentage cannot prove that a comment is accurate.

The frozen pre-change baseline at commit `3b9c30b45` was **74 of 2,752 declarations (2.69%)**. Its 2,069 Swift declarations also matched an independent SwiftSyntax inventory. The regression suite locks declaration recognition, documentation attachment, scope exclusions, parser failures, and threshold behavior.
