# Evaluate application feature code

`EvaluationStore.runFeatureAdapter` is the in-process developer integration for
exercising a real Swift feature entry point without routing the request through
Foundation Models. It snapshots the selected suite, executes the adapter, and
persists the resulting `EvaluationRun` in normal project history. That run can
then be reassessed, compared, approved as a baseline, and used by release checks.

The following example is complete Swift that can be placed in the app target;
`normalizeTitle` stands in for the application's existing shared-code entry
point and is implemented here so the example has no undefined symbols.

```swift
func normalizeTitle(_ value: String) -> String {
    value
        .split(whereSeparator: \Character.isWhitespace)
        .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        .joined(separator: " ")
}

let adapter = ClosureFeatureAdapter(displayName: "Title normalizer") { input in
    normalizeTitle(input.prompt)
}

let run = try await store.runFeatureAdapter(
    expectedRevision: store.suiteRevision,
    adapter: adapter
)

let report = store.releaseCheckReport(runID: run.id)
print(EvaluationReleaseCheckEvaluator.markdown(report))
```

The example shape and production persistence path are compiled and executed by
`EvaluationDevelopmentWorkflowTests`; the integration test reloads the saved
run and evaluates its release report. This remains an in-process macOS app
integration, not a standalone or Linux runner.
Exact-match and contains-text suites are scored directly. Review suites remain
unscored unless they contain deterministic JSON field assertions. AI-rubric
suites evaluate collected feature responses with the suite's approved
independent judge connection before the run is saved. Deterministic literal
requirements are checked locally. Missing approval, credentials, or a configured
independent judge blocks the run before feature execution; judge failures remain
unscored errors. Release checks fail closed rather than treating missing judgment
as a pass.

## Review saved feature results

Use the [Review guide](EVAL_REVIEW_GUIDE.md) for human labels, confirmed failure
patterns, regression cases, and held-out judge checks. Read [Runs and results](wiki/Runs-and-results.md)
for the suite's selected assessment, baseline approval, and release requirements.
[Production batches](PRODUCTION_EVALS_GUIDE.md) are a separate job/worker path
with their own audit and exact-evidence baseline approval. The in-process adapter
does not automatically become an unattended batch executable.
