# Telemetry PR worklog

- Scope: repair usage telemetry and automatic privacy-filtered native crashes; exclude development and every updated app build on this Mac. Open a PR; do not publish a release.
- Earlier source qualification: 50 focused tests passed, native crash/relaunch/opt-out fixture passed, arm64 Release build and matching local dSYM UUID passed. These checks used the original dirty checkout, not the PR snapshot.
- Preserve unrelated local work; prepare an isolated branch from current main.
- Add a host-local preference shared by Intents builds, independent of saved consent. Also disable legacy consent preferences here and purge pending app crash reports.
- Live production crash ingestion cannot be exercised on the excluded Mac. Never manufacture production activity. Track exact PR build, symbol upload, and hosted verification evidence separately.

- Current-main adaptation: preserved native-worker/MCP read-only behavior and unrelated automation/UI logic. Reviewer caught missing Settings re-enable observation; restored it plus initial key-window observation. Transferred actual-run automation regression test.
- First PR test run exposed catalog recovery recorded as successful after main changed its notice handling; fixed the diagnostic failure flag. Rerun passed 52 tests in 8 suites. Archive helper regression tests passed 6/6; shell syntax passed.
- Existing EU Intents credential and one Developer ID identity discovered; official PostHog CLI 0.18.10 installed temporarily. Prepare a signed PR candidate only; no release distribution.

- Native PR build Privacy UI inspected at top and bottom: both switches and Retry are disabled, local-policy copy is readable, temporary app closed. No simulator used.

- Signed arm64 candidate archive succeeded at source 81b6b414673bae9f3aa4efd2a2d32bb04db09f47, version 1.0, build 2026101001. Signature verified; packaged privacy manifest lint passed. No installer, tag, release publication or distribution.
- Actual archive validation exposed codesign -dv omitted Authority metadata; helper now uses -dvvv and its six regression tests were rerun successfully. No app source changed after archive.
- Exact app/dSYM UUID: 369C06FB-C5A2-3A45-8D1F-E990F7424825 (arm64). PostHog upload exited 0; symbol set 01a1261e-aabe-0000-b989-361aef550662 has an uploaded file, matching release version/build and no failure reason.
- Downloaded the symbol file from PostHog: SHA-256 equals the exact archive DWARF. atos resolves TelemetryController.appBecameActive() at TelemetryController.swift:166. No source files were included.
- Saved native fatal insight 6465993 still returns No data recorded. Symbols are qualified; hosted live crash delivery/readable UI frames remain unverified on an eligible machine. This Mac remains excluded and no production crash/event was manufactured.
