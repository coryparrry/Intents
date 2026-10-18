# CI coverage and performance

CI has two responsibilities: give a pull request useful feedback promptly, and
prevent a green required check when selected product checks did not pass.

## Execution policy

- Pull requests select affected checks from their complete base-to-head diff.
  Unknown paths and unreadable diffs select full coverage.
- Main pushes, manual runs, and the scheduled stability workflow run full
  ordinary coverage. The opt-in FreshRecord and MacPreparation UI fixtures are
  not part of ordinary coverage; their specialized runtime prerequisites remain
  explicit.
- Linux workflow validation and selected script tests finish before Mac workers
  are allocated. A failure here blocks expensive builds and simulator setup.
- Portable Swift and macOS script tests share one Mac job. Native test products
  are built once and consumed by core and UI test jobs without rebuilding.
  Portable tests do not generate unused coverage instrumentation; no coverage
  report or threshold previously consumed it.
- UI shards use recorded test durations, with median estimates for tests
  without measurements. Sharding changes placement, not the selected coverage.
- Fresh external SDK consumers run for SDK/installer changes and full runs.
  They still build the installer's immutable remote revision and verify a receipt
  for both public products. Unrelated app changes do not rebuild that SDK.

## Required result

The existing `Compile app and tests` check is retained because repository rules
already require its name. It now always runs and also enforces the script,
portable, external SDK, simulator acceptance, and selected Mac input diagnostic
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

The slow simulator contract remains selected when relevant and on full runs.
Queue capacity, simulator boot/install, and cold Xcode compilation remain real
costs. Compare queue delay, setup, execution, and cache hit/miss separately when
evaluating subsequent runs. A single warm run or an intentionally skipped job
does not establish a general speedup.
