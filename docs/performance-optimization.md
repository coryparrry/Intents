# Performance profiling and optimizations

Profiling found repeated work in overview rendering and saved-output review.
The changes reduce that work while preserving source digests, selected-assessment
semantics, error handling, and per-sample recovery checkpoints.

## Changes

| Area | Optimization |
|---|---|
| Targeted review actions | Locate and hash the requested sample instead of constructing the entire review queue. Duplicate and unencodable sources retain the queue's ordering and fallback behavior. |
| Overview rendering | Build one summary snapshot per render and share it between the hero, gallery, filtering, and recent-run timeline. Repository-change and storage-error overlays remain intact. |
| History outcomes | Project selected assessment results once per run, calculating pass/fail/error counts, chart rates, and historical outcome together. Original subject errors and invalid assessments still produce incomplete outcomes. |
| Review presentation | Cache one source/annotation projection and one discovery ordering. Changes to history, selected suite, or local state invalidate both. Cache hits still read observed inputs so SwiftUI tracks subsequent changes. |
| Review allocation | Return the shared ordering directly for All samples with no tag/search, avoiding an unnecessary array copy. Swift value semantics preserve independent mutation behavior. |
| Patterns | Materialize patterns once within each render. |
| Instruction improvement | Group selected results and count passes by case once rather than reprojecting and scanning them for each case. |
| Startup history | Find the global sequence by validating one run at a time, without retaining and sorting whole histories. Skip history reloads for snapshot directories with no JSON checkpoints. |

The review caches are presentation-only. Mutations still independently resolve
and validate their source evidence, including applicable image checks. There is
no persisted cache or digest-format change. The cache retains only the current
projection/order rather than accumulating generations.

For `C` cases and `S` samples, the instruction-improvement loops change from
`O(C × S)` to `O(C + S)`, apart from unchanged admission checks. The startup
maximum-sequence scan removes `O(R log R)` sorting for `R` runs; full decoding and
filename/project/suite validation remain. Directory enumeration still allocates
its URL list.

## Whole-app profiling

Time Profiler captures used the native Debug app on macOS 27.3 / Xcode 27.3,
with isolated storage, defaults and credentials, disabled telemetry and MCP
autostart, and synthetic content. The history fixture contains 30 runs, 20 cases
with five repetitions per run, 3,000 samples, and 21,000 workflow spans (about
11 MB of JSON). Its evidence hashing agrees with the tracked Swift-generated
review fixture.

The controlled review workload opens Samples, selects another output, searches
for `fixture`, clears the search, and selects a third output. Each review capture
runs for 35 seconds; normal migrated-workspace startup captures run for 12 seconds.
Startup migration was excluded from the comparison.

| Measurement | Before | Optimized |
|---|---:|---:|
| Startup: total process sampled CPU weight | 5,428 ms | 1,861 ms |
| Startup: overview summary, inclusive sampled CPU | 2,125 ms | 27 ms |
| Review: total process sampled CPU weight | 2,873 ms | 2,765 ms |
| Review: Samples body, inclusive sampled CPU | 1,819 ms | 897 ms |
| Review: source projection, inclusive sampled CPU | 1,039 ms | 501 ms |
| Review: discovery ordering, inclusive sampled CPU | 716 ms | 302 ms |
| Live malloc allocation after clearing review search | 96.4 MB | 96.3 MB |

These are individual statistical sampling captures, **not wall-clock launch or
interaction latencies**. Inclusive rows overlap and must not be added together.
The Mac was shared with other work, and GUI captures include accessibility
inspection and framework rendering. Total review CPU was only slightly lower
in the final capture; do not describe the reduced review-body weight as an
end-to-end 51% latency improvement. An earlier optimized capture had lower
weights, illustrating the variability. Window geometry was not held fixed
across all captures.

The first cache implementation retained 107.3 MB of live malloc allocation.
Sharing the unfiltered array brought that back to 96.3 MB. Resident/physical
footprints are not directly comparable: the baseline had substantial compressed
or swapped memory, while later captures were resident. No memory-leak or
production memory-saving claim is established.

The startup capture predates only the final Review-only array-sharing fast path;
its startup source and workload remain applicable. The final review capture and
native tests use the final application implementation.

### Runtime coverage

| Journey | Evidence and boundary |
|---|---|
| Startup and overview | Normal startup profiled; overview summaries, attention state, charts, and saved history inspected. |
| Review | Loading, selection, search/clear, diverse ordering and Patterns exercised; the final review screen was inspected visually. |
| Runs and reports | History, report, performance charts, trace index and trace expansion/selection exercised. More/Fewer columns were checked directly, including retention of the second selected case. |
| Review persistence | In a separate synthetic fixture, removed an orphan judge example, saved a human failure, assigned Development, inspected persisted JSON, and confirmed both review and replacement after relaunch. |
| Active execution | Profiled a 100-response collect-only streaming run against the repository's loopback fixture provider. All 100 responses were saved as unscored with zero errors and recorded workflow traces; persisted elapsed time was 12 seconds. No real model inference was performed. |
| Batch workspace, App Intents, settings | Navigation and available controls inspected; large production datasets, live App Intent/Siri invocation, and paired devices were not profiled. |

In the 40-second streaming capture, checkpoint persistence accounted for 875 ms
of inclusive sampled CPU weight, including 843 ms in canonical encoding.
Per-sample durability was retained. The remaining capture includes substantial
framework/accessibility work; this evidence did not justify a broader execution
or persistence rewrite.

### Capture artifacts

Retained under `/tmp`:

- `intents-valid-startup-warm-before.trace` and `intents-valid-startup-after.trace`
- `intents-valid-review-before.trace` and `intents-final-review-after.trace`
- `intents-streaming-execution.trace`
- Corresponding `*-analysis.json` summaries and `intents-*-memory.txt` snapshots
- `intents-profile-seed.py`, `intents-profile-analyze.py`, and the isolated fixture directories

Baseline app binary UUID: `1EEE64D8-830C-358A-BCEB-D2E5BBD01170`.
Final app binary UUID: `046EC334-9EBC-3EC9-9E4B-E0A9E5A6F3BD`.
The baseline is the previously verified local build from the first optimization
pass; both builds include uncommitted work and are not published releases.

Representative capture/export commands:

```sh
xcrun xctrace record --template 'Time Profiler' --time-limit 35s \
  --output /tmp/example.trace --attach "$(cat /tmp/intents-profile-pid)"
xcrun xctrace export --input /tmp/example.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
  --output /tmp/example.xml
```

All trace bundles were kept. During disk pressure, only task-owned regenerable
compiler caches and XML exports were removed. The isolated app and loopback
fixture server were closed after verification.

## Verification

The final native build and ordinary suite passed: **1,051 tests passed, zero
failed, six opt-in tests skipped**. The runner also omits the live Core AI
resource-loading check under the existing manual-test policy.

New regression cases cover cached Observation dependencies, nested source edits,
annotation saves, evidence corruption, same-size history/assessment changes,
removals and suite switches. Outcome tests cover selected assessments, original
subject errors, judge errors, unscored captures, missing assessments and duplicate
assessment identities. Earlier tests cover targeted lookup equivalence and
malformed/foreign/archived history sequence restoration. Independent source
reviews found no actionable issues, including in the final array-sharing fast path.

Commands from the repository root:

```sh
xcodebuild build-for-testing -jobs 2 \
  -project FoundationEvals/FoundationEvals.xcodeproj \
  -scheme FoundationEvals -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/intents-performance-derived \
  -disableAutomaticPackageResolution -only-testing:FoundationEvalsTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
CI_TEST_SELECTION='["FoundationEvalsTests"]' python3 script/ci_native_tests.py \
  --products /tmp/intents-performance-derived/Build/Products \
  --result /tmp/intents-whole-core-final.xcresult
python3 script/docstring_coverage.py --minimum 85
git diff --check
```

### UI automation limits

The initial `EvaluationReviewUITests` run passed seven of nine methods. Two
failed: the report test could not establish its requested 1,180-point viewport
(actual width 1,170), and judge-check replacement lost an XCTest menu snapshot.
Disk exhaustion then prevented result-bundle finalization; the complete runner
log is retained at `/tmp/intents-whole-ui-runner.log`.

A bounded recheck did not stabilize window sizing/control visibility. A test-only
window-position experiment was reverted completely; no UI-test assertions were
weakened or excluded. These two automated cases remain **failed/unverified**.
Direct checks verified column toggling with selection retention and judge-check
replacement/persistence, but do not substitute for a successful automated suite.
The UI logs and recheck result artifacts remain under `/tmp/intents-whole-ui*`.

### Documentation coverage

The standard source check reports **99.11%**, including 100% for counted Swift
production functions. All **20 changed Swift functions** are documented. Existing
test files remain below the requested 85% target: counting all existing functions
in the touched Swift files gives 250/436 documented (57.34%). This pre-existing
shortfall was not expanded into an unrelated documentation rewrite.

### Earlier targeted-lookup benchmark

`EvaluationReviewWorkflowTests.targetedLookupLargeHistoryBenchmark` compares the
former full-queue lookup with the targeted store lookup for 20 synthetic runs
with 50 samples each, checking identical source digests without a timing assertion.
The first optimization pass measured 90.27 ms versus 0.380 ms, and 121.12 ms
versus 0.637 ms on a second run. These are individual Debug measurements of
that operation, separate from the GUI workload above.

## PR candidate validation on current main

The performance source was transferred unchanged onto `origin/main` at
`b23167aa3` for branch `codex/profile-app-performance`. Earlier profile captures
and manual checks describe the same performance source; they are separate from
this candidate's fresh build and test evidence.

The fresh `build-for-testing` succeeded using the maintained `FoundationEvals`
scheme with Xcode 27.3 on macOS 27.3, two build jobs, Debug configuration, and
ad-hoc signing. The routed native selection passed **1,067 tests**, with zero
failures and six documented opt-in skips:

```sh
CI_TEST_SELECTION='["FoundationEvalsTests"]' python3 script/ci_native_tests.py \
  --products /tmp/intents-performance-derived/Build/Products \
  --result /tmp/intents-pr-core.xcresult
```

All always-on checks passed: documentation coverage at minimum 85%, 37
documentation-detector tests, changed-function documentation (20/20), pinned
actionlint, ShellCheck, example syntax, all website syntax/style checks and 40
website tests, and `git diff --check`. Full check logs are retained under
`/tmp/intents-pr-validation/`.

A current-base recheck of the two previously failing UI methods also failed.
`testRunReportRevealsAdditionalColumns` obtained a 1,004-point window rather
than the required 1,180-point viewport.
`testUnavailableJudgeExampleCanBeRemovedAndReplacedAfterRelaunch` failed menu
and review-control visibility assertions. The log and result bundle are retained
at `/tmp/intents-pr-ui-recheck-runner.log` and
`/tmp/intents-pr-ui-recheck.xcresult`. The original assertions are unchanged.

The complete coverage selection in `/tmp/intents-prepush-coverage.json` includes
all native tests and eight UI suites: EvaluationReview, RunLifecycle,
MacIntentTesting, ChartHover, DocumentSuite, FoundationEvals, WorkspacePolish,
and WorkflowTrace. The remaining UI selection was not rerun after the repeated
UI failures; it remains unverified on this candidate. No additional portable
Swift, Python/macOS, production-evaluation, or standalone-plugin checks were
selected. The required UI gate is unsatisfied.

## Remaining boundaries

Live on-device/Core AI inference, Siri, paired-device execution, large production
batches, installer behavior, and Release-build performance remain unqualified.
The overview loader still fully decodes history, and the first review projection
still encodes/hashes its sources. No remote CI, push, merge, or release is part
of this evidence. The user explicitly authorized PR publication with the two failed UI cases and
the remaining selected UI suites unverified. This publication exception does
not establish a passing UI gate or readiness to merge.
