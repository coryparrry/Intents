# Verification

## Failing baseline

- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest script.tests.test_ci_routes.MatrixTests.test_full_ui_selection_runs_lifecycle_and_traces_on_separate_desktops` failed as intended before the router edit: both suite owners were `runs+traces`.
- The existing Settings test at the unchanged base completed ten repetitions, with one failure at the original Request policy visibility assertion. Its accessibility snapshot put the button below the form after the fixed scroll. [Hosted picker stability baseline](https://github.com/coryparrry/Intents/actions/runs/45406968289/job/138492131834).

## Candidate routing and static checks

- `python3 -m unittest script.tests.test_ci_routes script.tests.test_ci_workflow` passed 84 tests, including the preserved fail-first case.
- `python3 script/ci_run_tests.py python` passed 397 tests across all 29 selected general Python modules and 13 tests across both selected macOS modules.
- `npm ci --prefix Tools/DocstringCoverage --ignore-scripts --no-audit --no-fund`, `python3 script/docstring_coverage.py --minimum 85` (2826/2826), `python3 script/changed_function_docs.py --base origin/main` (5/5), and the two documentation-tool test modules (37 tests) passed.
- ShellCheck, pinned Actionlint, Python example compilation, website syntax and inline style checks, all 40 website tests and diff whitespace checks passed.
- The complete routing result selected full coverage. The four jobs are `native-intents` (548 estimated seconds), `review+runs` (902), `suite-editor` (655) and `traces` (545). All eight full UI suite selectors occur once.

## Runtime and delivery

- `xcodebuild build-for-testing` succeeded on Xcode 27.3 with the maintained FoundationEvals scheme and CI-style ad-hoc signing. The maintained native test runner passed 1074 cases with zero failures.
- The local Settings invocation ended before any UI case executed because macOS cancelled XCTest authentication. The maintainer explicitly waived local UI execution for the pre-push gate and directed verification through GitHub. Current-head ordinary CI and the ten-iteration hosted stability job remain required.
- Reused the [same-base hosted portable and production results](https://github.com/coryparrry/Intents/actions/runs/45406968289/job/138492131832) for pre-push validation. The portable and production source, tests, package locks, runner commands and selection are unchanged. Both steps passed on the hosted Xcode runner and will run again for the candidate.
- The original main push CI was retried once on a fresh runner because the same commit finished the affected shard in nightly. The rerun is independent of candidate proof.
- Candidate GitHub verification and maintainer merge approval are pending.
