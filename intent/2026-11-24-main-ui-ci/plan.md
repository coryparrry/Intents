# Implementation plan: Repair macOS UI CI on main

Change: 2026-11-24-main-ui-ci
Accepted [intent](intent.md): 42742c8e1cef989352a283db94e283c29fbb4c8f1673ffa61fbd92b35d28ced9
Accepted [spec](spec.md): 718114b7d88ffa7d32d6c794b565324dd578f326fae1efba0e76f6359ed79081
Base: origin/main at 9cc9b15757f6b2abb70613d248f38731dffc9710
Authority: this directory
Reserved decision owner: the Intents maintainer for scope expansions, merge and release authorization

## Findings

The router balances groups into at most three desktops. On full coverage the lifecycle and trace suites share one job. Two case-stall timeouts in that job consumed roughly six minutes before the step was cancelled. Same-source nightly completed both suites in 1124.659 seconds total. The job reuses compiled native products and retains independent desktop execution.

In Settings, a fixed scroll sometimes leaves the Request policy control outside the Judges form. The implementation already exposes both controls to accessibility. Use the position-directed scroll pattern from the existing UI harness while retaining full containment for these compact controls.

## Ordered changes

1. In `script/tests/test_ci_routes.py`, add a documented regression checking full coverage selects exactly the ordinary UI classes without duplication, uses four desktops on the present inventory, and keeps the complete lifecycle and trace classes in distinct jobs. Preserve the existing targeted cap test. Run the added regression against the old router and checkpoint the expected failure. Record the existing Settings regression and failed hosted repetition as the pre-fix baseline.
2. In `script/ci_routes.py`, add an explicit keyword shard limit to the duration-weighted allocator, default three. Have `with_matrices` pass four for full coverage. Keep group placement, class/method deduplication and opt-in exclusions. The regression makes accidental lifecycle/trace co-location visible as timings or groups change.
3. In `FoundationEvals/FoundationEvalsUITests/WorkspacePolishUITests.swift`, preserve the Settings test and use one private, documented helper for both policy controls. Keep existence checks before scrolling. From within the form, use up to six position-directed scroll gestures, rechecking full viewport containment and hittability before each gesture. Leave a final assert and accessibility snapshot for a control still unreachable. This absorbs missed scroll events while preserving the original accessibility requirement.
4. Update `docs/ci.md` with the full/targeted limits and the reason for the separate desktops. Record results and independent reviews in this directory.

## Verification and recovery

- Run the new regression before and after, followed by the router, workflow and complete selected Python tests. Inspect exact matrix, coverage inventory and job timings; current routing is 1008 estimated seconds for the combined shard. The extra desktop trades one more preparation step for separating the two suites without extending the timeouts.
- Run the documented pre-push baseline and complete diff selections, including portable/native, production, desktop UI and SDK checks. Build native products once and run UI jobs serially on the local desktop. Run the exact Settings selector for ten iterations and verify the count. Interactive macOS signing and other active work are prerequisites. Record unavailable or failed checks and hold the push if required validation cannot run.
- Verify candidate PR CI and the stability workflow where available. Main recovery requires an authorized merge and passing main push and nightly results. No app behavior, production configuration, timeout or release changes. If post-change runs still show the case stalls, inspect the retained per-shard evidence and seek renewed plan review for a material follow-up.

## Acceptance

Before implementation, an independent agent challenges and accepts the exact plan revision. Record the reviewer, decision, time, revision and evidence in [review](review.md). Resolve material findings and obtain renewed acceptance for material changes. Route expanded scope and reserved decisions to their named owner and complete required owner approvals.

## Deviations

The implemented test scope follows the accepted plan. The maintainer authorized hosted UI verification after local XCTest authentication failed. The documentation follow-up aligns the README with the verified CI limits and expands the approval record. See [verification](verification.md).
