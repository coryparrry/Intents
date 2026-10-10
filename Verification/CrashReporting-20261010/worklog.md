# Automatic native crash reporting — 10 October 2026

## Goal
Add opt-in PostHog automatic crashes and native stacks to Intents on macOS, without uploading private app content. Preserve anonymous identity, existing telemetry, unrelated dirty work, and development exclusions. No release publication requested.

## Design and findings
- Pinned SDK 3.71.4 supports fatal Mach/signal/NSException reports on the next launch.
- SDK native hooks remain installed for the process lifetime. Opt-out must purge the app-specific pending store and revoke crash-time consent epochs; stale reports must never upload after re-enable.
- Crash snapshots must carry the original build/session/epoch. Do not relabel a prior crash with the reporting build.
- Preserve bounded addresses and Mach-O UUIDs for symbolication; replace messages and unknown types, strip paths, functions, breadcrumbs, arbitrary nested fields and private properties.
- Native symbols must match the exact shipping archive. Prepare validation/upload guidance; do not treat local symbols as proof of live symbolication.

## Work underway
- Source: opt-in production capture, strict native payload reconstruction, original crash context, pending-store purge and consent epochs implemented. Consent copy, manifest and telemetry docs updated.
- Review: independent Sol 6.1 source review found no material defect; runtime capture and symbolication remain to verify.
- Verification: background privacy/consent tests passed on first run; two integration assertions exposed an obsolete expectation and test URLProtocol stream handling. Corrections underway. Isolated SDK fixture confirms actual next-launch processing; outgoing body recording needs stream support.
- PostHog: project error tracking already enabled. Added and tested fatal crashes by original build on the existing dashboard (insight 6465993, tile 7314622); no eligible production data. No synthetic production events sent.
- Native fixture: actual SIGABRT capture and next-launch processing passed; no private sentinel in outgoing payload; opt-out wrote no pending report; re-enable refreshed context. Captured UUID matched local dSYM and resolved Fixture.main(). Fixture stores removed.
- UI: actual Debug Privacy top/bottom screenshots inspected; full disclosure wraps and remains reachable, development sharing disabled. Temporary app closed.
- Final review found a concrete backlog risk: deep crashes could exceed the final upload bound when batched together. Diagnostic batches now contain one event. Added actual SDK backlog checks; final 50 tests in eight suites passed. Independent follow-up review found no material defect.
- Release: initial unsigned arm64 Release build passed, packaged manifest matched source and native dSYM UUID matched. Final rebuild after the backlog fix hit disk exhaustion, with compiler IO failure. Removed only generated SDK/module/fixture symbol caches from this task’s temporary directories, recovering 2 GiB. Bounded arm64-only Release rebuild passed; final packaged manifest matches source and executable/dSYM UUIDs match. Source and test evidence preserved.
- Remaining qualification: signed shipping release, store disclosure reconciliation, exact archive symbol upload and real PostHog symbolication. No shipping/commit/push authorized or performed.
