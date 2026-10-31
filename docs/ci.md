# CI coverage and results

Pull requests select affected checks from the complete base-to-head diff.
Unknown paths and unreadable diffs select full coverage. Main pushes, manual
runs, and the scheduled stability workflow select full ordinary coverage.

Prioritize integration and end-to-end checks of complete user workflows and
important failure paths. Keep focused unit tests when they cover meaningful
edge cases or invariants that those workflows cannot exercise reliably. Avoid
tests that only freeze implementation details, callback counts, marketing copy,
or dated content. A passing test count does not establish release readiness.

Linux workflow validation and selected script tests finish before Mac workers
are allocated. Native app and test products are built once. Core tests and
independent UI shards reuse the same retained products. Portable Swift,
selected macOS script tests, and production batch qualification share the
**Portable regression tests** worker.
When no Apple checks are selected, that required worker completes on Ubuntu.

`MacIntentTestingTests` verifies the native Mac App Intent support library.
Foundation Models, developer runner, and standalone plugin checks retain their
separate scope. Production package tests and the real CLI worker protocol run
through `bash script/ci_production_evals.sh` for affected changes and every full
main, manual, or release-version run. The standalone production workflow uses
the same script. A failure fails the required regression worker and blocks
installer publication at that source commit. None of these source checks qualifies a
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

The app and its test targets invoke intents in other apps but do not export
`AppIntent` or `AppShortcutsProvider` types. Their project configurations set
`LM_SKIP_METADATA_EXTRACTION = YES` to omit an unused metadata-generation step.
Remove that setting from any target that starts exporting its own app intents.
Compiler diagnostics remain enabled.
