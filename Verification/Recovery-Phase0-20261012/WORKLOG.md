# Phase 0 recovery worklog

- Scope: runner-release deadline polling, confirmed ownership reset and startup recovery, per-device CoreDevice aliases, separate Intent Lab leases, stable picker tests and responsive selection.
- Delivery branch: `codex/recovery-phase0-20261012`, based on `origin/main` at `4a7b0fc`. The original dirty checkout is preserved. Later-phase execution, codec, telemetry, website and release changes are excluded.
- Independent review: recovery races, live-child protection, manual physical approval, legacy Intent Lab journal recovery, legacy device aliases and runner admission were reviewed. Material findings were fixed and rechecked by the reviewer.
- Local verification: focused Swift tests using Xcode 27.2 beta 2 passed: 262 tests passed, one optional real-device inventory capture skipped, no failures. Includes cancelling an unresolved attempt, resetting ownership and running again; live-child protection; startup recovery; selection responsiveness; legacy Intent Lab recovery.
- Toolchain correction: default Xcode 27.0 cannot load its AppIntentsTesting framework against this Mac's macOS 27.2 framework. Xcode 27.2 beta 2 loads successfully; no global toolchain settings changed.
- Signing correction: UI builds use the existing project Developer ID identity, manual signing, secure timestamps and `ENABLE_DEBUG_DYLIB=NO`. Earlier runners built with Xcode 27.0 were killed before test startup; no security settings changed or tests disabled.
- In progress: signed Xcode 27.2 UI build and ten-repeat picker tests; real-panel cancellation and Reset confirmation cancellation follow. Local UI acceptance and green CI on main remain pending.
- Logs and result bundles are task scratch artifacts; no new qualification or evidence schema introduced.
