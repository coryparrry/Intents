# Intent: Repair macOS UI CI on main

Change: 2026-11-24-main-ui-ci
Author / originator: Codex, requested by the Intents maintainer
Created: 2026-11-24
Authoritative record: this directory

## Problem

Push CI at 9cc9b1575 timed out while running lifecycle and trace UI tests together. XCTest recorded two per-test timeouts. Nightly passed that shard at the same revision, but the Settings stability check failed one of ten repetitions when Request policy remained outside the visible form after scrolling.

Evidence: [push CI](https://github.com/coryparrry/Intents/actions/runs/45263457645), [passing nightly shard](https://github.com/coryparrry/Intents/actions/runs/45406968289/job/138492131946), [failing stability job](https://github.com/coryparrry/Intents/actions/runs/45406968289/job/138492131834).

## Proposed outcome

Give the affected UI suites independent desktop time and make the Settings test verify that scrolling reaches both policy controls. Preserve the test inventory, failure signal and required checks. Verify the repair through the ordinary PR workflow.

## Constraints and open questions

Keep product behavior and test coverage intact unless evidence identifies an app defect. The exact trigger of the hosted XCTest stalls and the failed scroll remain open. Preserve the timeout limits and require successful candidate execution before claiming recovery. Merge and release remain reserved decisions.

## Acceptance record

See [review](review.md).
