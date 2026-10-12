# Phase 0 recovery worklog

- Scope: runner-release deadline polling, confirmed ownership reset and startup recovery, per-device CoreDevice aliases, separate Intent Lab leases, stable picker tests and responsive selection.
- Delivery branch: `codex/recovery-phase0-20261012`, based on `origin/main` at `4a7b0fc`. The original dirty checkout is preserved. Later-phase execution, codec, telemetry, website and release changes are excluded.
- Independent review: recovery races, live-child protection, manual physical approval, legacy Intent Lab journal recovery, legacy device aliases and runner admission were reviewed. Material findings were fixed and rechecked by the reviewer.
- Local verification: focused Swift tests using Xcode 27.2 beta 2 passed: 262 tests passed, one optional real-device inventory capture skipped, no failures. Includes cancelling an unresolved attempt, resetting ownership and running again; live-child protection; startup recovery; selection responsiveness; legacy Intent Lab recovery.
- Toolchain correction: default Xcode 27.0 cannot load its AppIntentsTesting framework against this Mac's macOS 27.2 framework. Xcode 27.2 beta 2 loads successfully; no global toolchain settings changed.
- Signing correction: UI builds use the existing project Developer ID identity, manual signing, secure timestamps and `ENABLE_DEBUG_DYLIB=NO`. Earlier runners built with Xcode 27.0 were killed before test startup; no security settings changed or tests disabled.
- In progress: signed Xcode 27.2 UI build and ten-repeat picker tests; real-panel cancellation and Reset confirmation cancellation follow. Local UI acceptance and green CI on main remain pending.
- Logs and result bundles are task scratch artifacts; no new qualification or evidence schema introduced.

## Final review fixes

Review inventory at the initial PR head: five current inline threads, no other standalone findings. Four findings were verified and fixed: all active unresolved report blockers, busy-state inventory retry, programmatic configuration/catalog invalidation, and unrelated same-process reservation protection. The claimed cross-window reproduction was not established because app windows share one store; the API reservation risk was verified. Startup simulator shutdown was not required: the plan assigns shutdown to confirmed reset and explicitly permits automatic dead-owner reconciliation.

Finished requests retain their actual run IDs and targets; comparison records use their real before/after approvals. Saved evidence is preserved. Independent review of the final fixes found no material issues.

Final focused test run: core XCTest 113 passed and one optional capture skipped; Swift Testing 23 passed. Native tests had one synthetic shutdown fixture failure because it omitted the newly required finished-request scope. The fixture now explicitly identifies that request and checks that its exact report, target and reservation survive shutdown failure. All 10 recovery tests passed on recheck; other native tests passed in the focused run. Hosted CI's synthetic Siri and asynchronous MCP fixture assumptions were also corrected without relaxing assertions.

Final Developer ID signed build is in progress with Xcode 27.2 beta 2. Actual hosted-view tests, Reset/panel cancellation and picker 10/10 remain pending. PR: https://github.com/coryparrry/Intents/pull/134. Phase 0 acceptance is not yet complete.
