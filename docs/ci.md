# CI coverage and results

Pull requests select affected checks from the complete base-to-head diff.
Unknown paths and unreadable diffs select full coverage. Main pushes, manual
runs, and the scheduled stability workflow select full ordinary coverage.

Linux workflow validation and selected script tests finish before Mac workers
are allocated. Native app and test products are built once. Core tests and
independent UI shards reuse the same retained products. Portable Swift and
selected macOS script tests share the **Portable regression tests** worker.
When no Apple checks are selected, that required worker completes on Ubuntu.

`MacIntentTestingTests` verifies the native Mac App Intent support library.
Foundation Models, developer runner, production batch, and standalone plugin
checks retain their separate scope. None of these source checks qualifies a
live AppIntentsTesting invocation. See [manual qualification](ci-manual-tests.md).

Native and portable Swift Testing cases use a maximum concurrency of four.
The maintained app scheme sets the native bound; the portable dispatcher sets
it for its own process. UI shards use recorded durations with fallback estimates
for new tests, run on independent desktops, and retain logs and result bundles.
Selected UI tests must execute and pass; a skipped selected method is a failure.
The optional stability worker repeats the settings accessibility check ten times.

The **Compile app and tests** terminal check enforces the complete selected
workflow state. **Workflow and script checks** and **Portable regression tests**
remain required check names. A routing decision may intentionally skip an
unselected worker. Failed, cancelled, missing, or unexpectedly skipped selected
workers fail the gate. The final job also publishes failure summaries and links.

Release packaging validates its immutable source on Ubuntu and waits for that
source's successful main CI before allocating a Mac runner. The Mac job checks
out the same SHA and validates the candidate before signing, notarizing,
verifying, and publishing. CI changes do not authorize a release.
