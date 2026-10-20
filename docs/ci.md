# CI coverage and performance

CI has two responsibilities: give a pull request useful feedback promptly, and
prevent a green required check when selected product checks did not pass.

## Execution policy

- Pull requests select affected checks from their complete base-to-head diff.
  Unknown paths and unreadable diffs select full coverage.
- Main pushes, manual runs, and the scheduled stability workflow run full
  ordinary coverage. The opt-in FreshRecord and MacPreparation UI fixtures are
  not part of ordinary coverage; the prepared pure-echo method in the mixed
  AppAutomation suite is also excluded, including when that file changes. Other
  methods in mixed suites are discovered automatically. Editing an opt-in-only
  test file keeps its bundle compiled but selects ordinary UI coverage; live
  qualification remains a separate manual run.
- Linux workflow validation and selected script tests finish before Mac workers
  are allocated. A failure here blocks expensive builds and simulator setup.
- Portable Swift, macOS script, native core and selected SDK consumer checks
  share one Mac regression worker. Native test products are built once; core
  tests reuse that artifact while UI shards run independently from the same build.
  Portable and installer tests share one root Swift build and one test selection.
  SDK consumers still build fresh temporary projects against the pinned remote
  revision; their checkouts, build products and receipts are never cached. The
  `Native core tests` and `Clean Intent Lab SDK consumer` checks are Ubuntu
  result gates. Actual Apple test execution remains in `Mac regression tests`;
  the gates link to that shared worker and its unchanged evidence artifact names.
  Portable tests do not generate unused coverage instrumentation; no coverage
  report or threshold previously consumed it.
- Native core and portable Swift Testing cases use a maximum concurrency of four. The maintained
  app scheme sets `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4`, and the
  generated core scheme preserves it in the built test descriptor. The workflow
  does not override that value through `TEST_RUNNER_`. The portable runner sets
  the same limit explicitly for `swift test`; the Xcode scheme cannot configure
  a separate SwiftPM process. This experimental control
  bounds case scheduling, not the subprocesses each case can launch; revalidate
  it when upgrading Xcode. Repository timeout/cancellation fixtures block on a
  FIFO instead of spinning a CPU, and verify stop reasons and child reaping
  within a one-minute test bound rather than asserting whole-suite scheduling
  latency. The full local native suite passed 1,110 tests, and the hosted native
  step passed on `c94df1e99` with this configuration.
- UI shards use recorded test durations, with median estimates for tests
  without measurements. Sharding changes placement, not the selected coverage.
  Test output streams to Actions and a durable log. Individual UI tests have a
  three-minute default allowance, preserving explicit fixture allowances up to
  ten minutes. The test step has a 16-minute limit inside the 20-minute job so
  failures can still export and upload diagnostics.
- UI fixtures open the suite editor through its menu command and verify its
  controls before testing navigation. They do not depend on a preceding test's
  restored window. Timeline assertions wait for the selected accessibility value
  and completed sidebar resize before checking the original geometry bounds.
- The synthetic readiness cancellation test announces its child PID and blocks
  on a FIFO until cancellation. It verifies that the executor sees a launched
  child before cancelling, joins cleanup on every path, and retains a two-minute
  deadlock bound. Scheduling delays cannot make a fixed-duration sleep expire
  before the test observes it.
- Fresh external SDK consumers run for SDK/installer changes and full runs.
  They still build the installer's immutable remote revision and verify a receipt
  for both public products. Unrelated app changes do not rebuild that SDK.

## Manual qualifications

Automatic runners exclude the [manual qualification methods](ci-manual-tests.md)
whose fixtures, profiles, model assets or activation flags they do not provide.
This includes 23 runtime opt-ins in ordinary Swift execution, the native model
integration, and the native duplicate of the SDK installer integration. Dedicated
SDK and input-conversion jobs keep their explicitly provisioned checks. These
exclusions remove skipped entries from automatic selection, preserving the
ordinary methods in each suite and direct manual execution paths.

## Required result

The existing `Compile app and tests` check is retained because repository rules
already require its name. It now always runs and also enforces the script,
portable, external SDK, simulator and Mac acceptance, and selected Mac input diagnostic
results. An expected skip passes only when the routing plan did not select that
job. Failures, cancellations, missing results, and unexplained skips fail the
gate, including for changes that do not require a native build.

`Workflow and script checks` and `Portable regression tests` remain stable
required check names. Branch rules do not need to change to adopt this workflow.
Job success is not evidence of coverage outside the selection printed by the
routing job. Simulator acceptance does not establish physical-device behavior;
the external SDK receipt establishes compilation, not runtime execution.

Release packaging resolves and validates its immutable source on Ubuntu and
waits there for that exact source's successful main CI. Only then does it request
a Mac runner. The Mac job checks out that SHA and revalidates the candidate before
signing, notarizing, verifying, and publishing. CI changes do not authorize a
release or change its signing requirements.

## Baseline and reference

Measured on 18 October 2026, Intents main
[`b29669de`](https://github.com/coryparrry/Intents/actions/runs/39115354510)
took **30m17s**. Selected jobs overlapped; their durations are not additive:

| Job | Execution time | Observation |
|---|---:|---|
| Native build | 10m09s | Cache miss; build step took 9m04s |
| Simulator acceptance | 23m04s | Runtime installation took 2m49s; contract took 19m22s |
| Slowest UI shard | 14m14s | 24 passed cases consumed about 13m25s |
| Other UI shards | 4m19s / 5m10s | Substantial imbalance |
| Fresh SDK consumer | 5m36s | Previously selected for any native or Swift change |
| macOS script tests | 39s | Separate allocation started over ten minutes after routing |

The reference [t3code CI at `9c161462`](https://github.com/pingdotgg/t3code/blob/9c161462c94f7d9d6d9169da5c841457cbadf213/.github/workflows/ci.yml)
uses conservative routing, measured sharding, parallel independent jobs, and an
explicit aggregate gate. Its matching
[main run](https://github.com/pingdotgg/t3code/actions/runs/39114462780) took
2m26s. It runs a different workload: Linux/browser checks, without Intents'
Xcode builds, Swift UI tests, or simulator App Intent execution. That elapsed
time is not an equivalent native-validation target.

Simulator and signed Mac acceptance share one worker. The Mac phase runs after
the simulator scenarios and verifies automation plus saved-fix comparison.
The historical simulator-only measurements below predate that Mac phase. A two-group hosted trial took 16m11s for
its slower group, versus 16m05s for the preceding single-worker run, and delayed a
UI shard by over six minutes. That split was removed. Full runs allocate seven
Mac workers instead of the original nine; all seven scenarios still run.

Fixture preparation and exact-Xcode validation finish before simulator boot.
Overlapping these phases failed hosted toolchain probes and stalled simulator
cleanup, so setup remains sequential. Installation waits for full readiness, and
cleanup releases only the device created by this run. All seven scenarios,
16 codec families, negative assertions, and timeout/recovery checks remain.

The unused legacy skip guard and its five self-tests were removed; the invoked
native runner still rejects missing, failed, and skipped selected UI tests. A
normally inactive fixture-generation method was also removed from the native
suite. Persistence, rollback, and review UI tests remain. These removals clean up
misleading test counts; they are not a material runtime speed improvement.

The slow simulator contract remains selected when relevant and on full runs.
Queue capacity, simulator boot/install, and cold Xcode compilation remain real
costs. Compare queue delay, setup, execution, and cache hit/miss separately when
evaluating subsequent runs. A single warm run or an intentionally skipped job
does not establish a general speedup.
