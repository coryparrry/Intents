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
