# Phase 5: prepared Mac automation

Prepared Mac source apps use the generated XCUITest host for typed App Intents,
entity queries, and deterministic UI steps. The Intents app and CLI share this
route. Installed Mac apps without a prepared source host and Mac fresh-record
authoring remain unavailable.

The app binds review and confirmation to the current local Mac login session.
The test controller terminates its application on success and thrown failures;
Intents independently checks that the exact prepared subject and runner exited.
An incomplete inventory or a remaining process leaves the run unresolved. Cleanup
does not signal a process merely because it has the expected executable path.

Run the reproducible native contract on an interactive Mac:

```sh
python3 script/automation_mac_e2e.py --xcode /Applications/Xcode.app --jobs 2
```

It stages a disposable fixture outside the repository, compares exact codec
outputs, runs UI → intent → query, checks a wrong assertion, verifies another
attempt can run, and exercises the Phase 6 source comparison. Raw logs and reports
remain outside Git. The existing CI acceptance job runs this contract after its
simulator checks and uploads both evidence directories.

Local implementation, regression tests, and independent review do not establish
live Mac workflow acceptance. See the final validation status below.

## Validation

- Xcode 27.2 local focused regression run: 219 Swift tests passed across native
  stores, core, and CLI. Related harness and routing checks: 139 Python tests passed.
- The Intents app built successfully and passed signature verification.
- The live CLI prepared the Mac fixture, then XCTest failed before test execution:
  `Timed out while enabling automation mode.` The attempt reported an
  infrastructure failure, verified resource release, and left no active campaign.
- The built app opened, but the native UI-control connection closed during
  navigation to App automation. The app remained running; no screen or workflow
  acceptance is claimed from that inspection.
- Native workflow execution, the opt-in app UI test, and hosted CI remain pending.
  macOS requires the user to authorize Automation Mode before the live tests.
