# Mac App Intent rewrite validation

21 October 2026. Local evidence for the replacement; this does not qualify a release or arbitrary apps.

The old Intent Lab/scenario/automation implementation, Siri/device runners, adapters and evidence tooling are removed. General AI evaluation, developer-feature evaluation and MCP remain. The independent completion review found no active legacy runner, tool or import remnants; historical release notes and negative regression assertions remain.

## Native execution

Environment: macOS 27.2, Xcode 27.2 beta 2, Apple silicon. The sample uses ordinary production AppIntent definitions and AppShortcutsProvider, with no Intents adapter or fixture-only registration hook.

An uninstalled app initially failed with Apple's metadata error 400. Normal installation/opening allowed native execution. The replacement requires LaunchServices to resolve the selected app and a matching signing team.

The temporary build workspace disappeared during the original implementation. Source was reconstructed directly into the attached Git worktree and all results below were obtained on that reconstructed source. Earlier temporary-workspace results are not used as final qualification.

The final CLI passed seven native cases across four discovered actions. Coverage included an escaped String, Boolean/integer inputs, Double input/output, enum cases/default and an execution-only smoke check. The frozen sample manifest SHA-256 is `78cf1b42f65a8a81228afbb8ffb089fcf66ad84f8c3b6e7803d6608c2a8d3dc8`.

The final result summary confirmed `Passed`, seven passed of seven total, zero failures, zero skips and zero expected failures. A wrong expected value produced an actual XCTest assertion failure and CLI exit 1. In-flight SIGINT cancellation returned exit 1 in 5.37 seconds and left no owned runner processes.

The rebuilt Intents app was also driven through its actual interface: choose the installed sample, select `ReadSampleStatus`, enable comparison, enter expected JSON `"ready"`, provide Xcode/signing settings, and run. The screen showed **Test passed**; its result summary independently confirmed one passed test with no skips or failures. The screenshot was inspected and the app was closed afterward.

## Final checks

| Check | Result | Retained local evidence |
|---|---|---|
| Root Swift package | 96 passed: 17 core, 5 CLI, 45 portable, 29 developer SDK | `.validation/full-package-final-inventory-tests.log` |
| Full Mac app and test-target build | Passed | `.validation/ui-labelled-build.log` |
| App unit tests | 650 passed, zero failed/skipped | `.validation/app-unit-final.xcresult`, `app-unit-final-summary.json` |
| Python tooling | 292 passed; focused 103 also passed, overlapping | `.validation/tooling-all-reconstructed.log`, `tooling-focused-reconstructed.log` |
| Compiled CLI authentication/update-signature tests | 13 passed | `.validation/compiled-python-tests.log` |
| Website tests | 27 passed; three JS syntax checks and inline-style check passed | `.validation/website-node-reconstructed.log` |
| Website browser inspection | Desktop/mobile screenshots inspected; zero errors or horizontal overflow | `.validation/website-browser-result.json`, `website-*.png` |
| GitHub workflow lint | actionlint 1.7.12 passed | `.validation/actionlint.log` |
| Native production-intent execution | 7/7, plus wrong-expectation and cancellation controls | `.validation/native-positive.json`, `native-control-results.json`, `native-runs/` |
| Actual desktop interface to native execution | 1/1 with explicit returned-value assertion | `.validation/gui-native-result.json`, `gui-native-test-summary.json`, `native-ui-pass.png` |
| Desktop UI XCTest regressions | 2/2 passed together, zero failures/skips | `.validation/ui-labelled.xcresult`, `ui-labelled-summary.json`, `ui-labelled-pass.png` |
| Generic review UI regressions | 4/4 passed with the bundled fixture | `.validation/ui-review.xcresult` |
| Independent source review and whitespace checks | No unresolved findings; `git diff --check` passed | Review checkpoint and Git diff |

The repository-designated manual CoreAI resource test was excluded by the existing native test policy. The 650 result is the selected automated app-unit suite.

Both previously blocked desktop UI methods now pass together in a clean development-signed build: `MacIntentTestingUITests/testMacIntentTestingShowsInstalledAppAndExplicitCaseControls` and `WorkspacePolishUITests/testSettingsTabsKeepTheirPrimaryControlsAccessible`. The original unsigned products and incremental re-signing attempts failed during macOS startup; clean products ran the actual methods. CI now builds locally signed products and uses a new cache namespace rather than restoring the old unsigned artifacts. The custom UI runner includes the SDK application-identifier expression.

Runtime UI testing also found unnamed controls in the grouped form and a static-text label/value mismatch. The app now assigns explicit accessibility names to the comparison switch and signing fields; the test queries the switch type, accepts the same instructional copy through either accessibility attribute, and captures only the app window. The passing screenshot was inspected. No system security settings were changed.

PR #151's initial workflow/script and terminal-gate failures came from missing release-note override markers in the PR description. A valid matching entry was added, and the metadata and workflow/script jobs passed afterward. The follow-up also restores the generic evaluation review fixture as a bundled UI-test resource, removes the retired Intent Lab simplification test and timing entries, and removes its stale MCP help reference. The four surviving review UI cases passed using the compiled bundle. Combined workflow, UI-descriptor, resource/selector, MCP and release-note regressions passed 133/133; actionlint passed. Hosted checks on subsequent PR heads remain a separate completion gate.

Representative rerun commands (use the selected Xcode through `DEVELOPER_DIR` and set `MAC_TEST_IDENTITY`/`MAC_TEST_TEAM` to an existing development signing identity/team):

```sh
swift test --jobs 2 --scratch-path .validation/swift-build
xcodebuild build-for-testing -project FoundationEvals/FoundationEvals.xcodeproj \
  -scheme FoundationEvals -destination platform=macOS \
  -derivedDataPath .validation/ui-clean-build CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY="$MAC_TEST_IDENTITY" DEVELOPMENT_TEAM="$MAC_TEST_TEAM" \
  CODE_SIGN_STYLE=Manual -jobs 2
CI_TEST_SELECTION='["FoundationEvalsUITests/MacIntentTestingUITests/testMacIntentTestingShowsInstalledAppAndExplicitCaseControls","FoundationEvalsUITests/WorkspacePolishUITests/testSettingsTabsKeepTheirPrimaryControlsAccessible"]' python3 script/ci_native_tests.py \
  --products "$PWD/.validation/ui-clean-build/Build/Products" \
  --result "$PWD/.validation/desktop-ui-rerun.xcresult"
python3 -m unittest script.tests.test_update_signature script.tests.test_foundation_evals_cli
node --test website/tests/*.test.mjs
```

For the 292 Python cases, load `script/tests/test_*.py` except modules in `script.ci_routes.MACOS_TESTS`; the two compiled modules are run separately above. The complete source-only workflow and native CLI invocation are in [setup](Mac-App-Intent-tests.md).

Validation artifacts are local, ignored files. They are not shipped in the product or committed as test fixtures.

## Limits

Metadata discovery is best effort and compiler-schema dependent. Required inputs and semantic expectations are explicit contracts; unsupported types fail. Smoke checks do not compare returned values or app state. Native Mac results do not validate iOS-only code, Siri understanding, microphone recognition or Apple Intelligence routing. No universal 100% app/type compatibility is claimed.

See [setup](Mac-App-Intent-tests.md) and [the sample](../../examples/MacIntentSample/README.md).
