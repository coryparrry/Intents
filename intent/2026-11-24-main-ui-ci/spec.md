# Requirements and design: Repair macOS UI CI on main

Change: 2026-11-24-main-ui-ci
Accepted input: [intent](intent.md) at 42742c8e1cef989352a283db94e283c29fbb4c8f1673ffa61fbd92b35d28ced9
Authoritative record: this directory

1. Full ordinary coverage runs the complete lifecycle and trace UI suites on separate desktops and selects each existing ordinary UI test once. Add at most one UI desktop for full coverage and retain the existing cap for targeted coverage. Keep single-build reuse, required checks and per-test/step limits.
2. The Judges Settings test brings Request policy and the expanded Generation policy into the visible scroll area using bounded, position-aware scrolling. Preserve the collapsed/expanded, in-viewport and hit-test assertions, and keep all ten stability repetitions mandatory.
3. Demonstrate the routing regression against the old behavior and retain that test. Keep the existing Settings test as the failing baseline with GitHub evidence and obtain ten passing candidate iterations before claiming runtime verification. Confirm complete candidate UI selection and report local evidence independently of main recovery.

## Design and evidence

The previous runner-contention decision in [PR 146](https://github.com/coryparrry/Intents/pull/146) retained finite XCTest and job timeouts. Same-SHA nightly measured the lifecycle and trace suites at 620 and 504 seconds respectively. An additional independent desktop for full coverage gives each suite more headroom and isolates runner state. The triggering cause of both per-test stalls is unconfirmed. The nightly snapshot showed Request policy below the Judges form viewport after a single fixed scroll. The Settings test will continue to fail if real scrolling cannot make the controls reachable.

The maintainer requested fixing both failures. [CI documentation](../../docs/ci.md), the [validation gate](../../docs/contributing.md#validation-before-pushing), and the [workflow](../../docs/sdlc/workflow.md) apply. No product UI change, retry policy change, required check change, or release is in scope.

## Acceptance record

See [review](review.md).
