# Phase 0 recovery worklog

Scope: runner-release deadline polling, confirmed ownership reset and startup reconciliation, per-device CoreDevice UUID aliases, separate Intent Lab leases, responsive selection and stable picker tests. No later-phase execution or qualification architecture was changed.

Delivery: [PR 134](https://github.com/coryparrry/Intents/pull/134), branch `codex/recovery-phase0-20261012`, based on main at `4a7b0fc`. The original checkout's unrelated dirty work is preserved.

## Recovery and review

Reset protects live runners and unrelated same-process reservations, and only clears ownership for exact finished requests. All unresolved report blockers clear after successful reset; independently completed results and saved evidence remain available. Startup reconciles dead/replaced owners; simulator shutdown belongs to confirmed Reset. Intent Lab's new store can still recover its exact legacy journal reservation.

Independent review covered reset races, live children, physical approval drift, aliases, legacy recovery, asynchronous selection and runner admission. Verified findings were fixed. Actual hosted-view tests cover inventory retry after loading and catalog publication after programmatic configuration. The final review also checks completed-result preservation.

## Local verification

- Matching Xcode 27.2 beta 2 builds the app and UI runner with the existing Developer ID identity, manual signing, secure timestamps and a standalone executable. Deep signature verification passed. No global toolchain or security setting changed.
- `xcodebuild test-without-building ... -only-testing:FoundationEvalsUITests/AppAutomationUITests/testPreparationPickersUseStableIdentifiers -test-iterations 10 -parallel-testing-enabled NO`: **10/10 passed, zero failures**. Log: `/tmp/intents-phase0-final-picker-ten.log`; result: `/tmp/intents-phase0-final-picker-ten.xcresult`. The final screenshot was inspected: destination and simulator selection are readable and stable.
- Signed UI cancellation/form checks: **3/3 passed**, including real file-panel Cancel and ownership Reset confirmation Cancel. Reset screenshots were inspected. Log/result: `/tmp/intents-phase0-final-cancellation`.
- Actual hosted selection view regressions: **2/2 passed**. MCP tests: **12/12 passed**, including the updated fixture awaiting execution cleanup. Log/result: `/tmp/intents-phase0-final-sync-hosted`.
- Cancellation/reset/rerun, live-child protection, startup recovery, per-device alias, Intent Lab legacy recovery and selection regressions passed in scoped Swift checks. One existing optional real-device inventory capture is skipped; no attached-device qualification is claimed.
- Final independent review passed in both checkouts. `swift test --jobs 1 --filter OwnershipRecoveryStoreTests` with matching Xcode: **11 passed, zero failures**, including completed-result preservation. Log: `/tmp/intents-phase0-reset-preservation-swift.log`. Hosted PR checks and CI on the merge into main are tracked through PR 134.

## CI fixture corrections

Hosted CI exposed synthetic physical aliases, an asynchronous selection assertion, a store-constructor fixture mismatch, and a five-second cleanup wait. Fixtures now use their intended readers and await actual tasks; result assertions and shipped tests remain enabled. The latest previous portable regression run passed 1,138 XCTest cases with 41 existing optional skips, plus package Swift Testing suites. Final PR and main CI results are required for acceptance and are recorded in the original plan/worklog after merge.
