# Offline Intent Lab evidence

The intents-evidence command checks a saved .intentlabrun directory without launching the Intents app, MCP server, simulator, or device. It consumes captured evidence; it does not run App Features, App Intents, or Siri.

The checker accepts bundle schema 1 and report policy intent-lab-report-v3. Each executed case has a frozen plan and a terminal record covering every planned route and attempt, with child evidence, retained assessments, journals, artifacts, provenance, and a derived report. The checker ignores any exported pass flag and recomputes the decision from the frozen evidence.

## Build a local review artifact

From this repository:

    ./script/package-intents-evidence ./dist/intents-evidence-macos

The script builds the release executable and writes intents-evidence-macos.tar.gz, its SHA-256 file, and a manifest with the exact binary digest, source revision, dirty-tree flag, toolchain, and architecture. A consumer can unpack the archive and run its intents-evidence binary without the source checkout. This local artifact is neither signed nor published. A manifest with sourceTreeDirty: true identifies a working-tree overlay, not an exact committed source build. Verify the archive digest from a trusted distribution channel before use.

## Prepare trusted inputs

Commit a reviewed requirement file in the consumer repository. Its schema is:

    {
      "schemaVersion": 1,
      "collectionID": "summary-regressions",
      "cases": [
        {
          "required": true,
          "definition": {"...": "the complete frozen v3 ScenarioDefinition"},
          "semanticPolicy": {
            "scoringContractDigest": "64 lowercase hexadecimal characters",
            "judgePolicyDigest": "64 lowercase hexadecimal characters"
          }
        }
      ]
    }

Keep the complete frozen definition produced by Intents, including its calculated definitionDigest and testContractDigest. Review the expected values, fixture digest, required routes, input mapping, and required/optional case status before committing it. Do not adopt a replacement requirement file supplied only by the evidence producer. A changed expectation or omitted case needs a reviewed requirement change.

Include semanticPolicy only when the check uses semantic assertions. Both digests are externally reviewed pins: the checker recomputes the raw output, reference, rubric and source binding, then checks the full retained assessment, its saved sample and criterion trace under those pinned scoring and judge policies. A selected status without its matching immutable assessment cannot pass. Missing or unscored selections cannot pass.

Obtain the expected source label and checked app executable SHA-256 from the reviewed checkout or trusted native execution job. A clean, single-repository checkout whose checked source files are tracked is frozen as `git:<commit SHA>` when the connection build is verified. A dirty, multi-repository, untracked-source or non-Git checkout is frozen as `inputs-sha256:<checked build-input digest>`; it must be pinned from a trusted native job, and must never be presented as a Git commit. Existing v3 plans without the newer source label export with this explicit digest fallback. The bundle's own source label and checksums establish consistency only; they are not hardware attestation or proof that the producer built that revision. CI should consume bundles from its trusted native job or an approved artifact source. The externally supplied app digest must match every frozen plan in the bundle.

## Check and compare

    ./intents-evidence check \
      --bundle ./artifacts/summary-check.intentlabrun \
      --requirements ./.intents/summary-regressions.json \
      --expected-source "git:$GIT_COMMIT" \
      --expected-app-digest "$APP_EXECUTABLE_SHA256" \
      --policy intent-lab-report-v3 \
      --reference-time 2026-09-28T12:00:00Z \
      --format json

    ./intents-evidence compare \
      --baseline ./artifacts/baseline.intentlabrun \
      --candidate ./artifacts/candidate.intentlabrun \
      --requirements ./.intents/summary-regressions.json \
      --baseline-source "git:$BASELINE_COMMIT" \
      --candidate-source "git:$GIT_COMMIT" \
      --baseline-app-digest "$BASELINE_APP_SHA256" \
      --candidate-app-digest "$APP_EXECUTABLE_SHA256" \
      --policy intent-lab-report-v3 \
      --mode app-change \
      --reference-time 2026-09-28T12:00:00Z \
      --format json

The source, app digest, and policy flags are required in addition to the specification's illustrative syntax. They enforce its explicit external source, build and policy trust boundary. The reference-time flag is optional for this policy, which has no age gate; provide it to keep a GUI/CLI report timestamp identical for the same frozen inputs.

The JSON result keeps incompleteEvidence and requiredFailures separately, with per-case reports. Compare also gives comparable; an outcome change can be visible even when it does not qualify as an app fix. Exit codes are:

| Code | Meaning |
|---|---|
| 0 | Required checks passed; comparison, if requested, is qualified. |
| 10 | A required observed outcome failed, with otherwise complete evidence. |
| 20 | Evidence or comparison is incomplete or incompatible. |
| 30 | Invocation, trusted-input, format, checksum, schema, or file validation error. |

Precedence is 30, then 20, then 10, then 0. A clean assertion failure can retain its observed failed outcome even when XCTest exits nonzero. A skipped or zero-test native child, unsafe recovery, or missing coordinate cannot pass. The checker requires one executed test for each native child and an accepted matching journal. The app's old script/foundation-evals scenario-report --run-id command remains the existing live MCP report command with its existing semantics and exit behavior.

A collection bundle retains the full reviewed membership and its sealed batch manifest. The checker reconstructs every required route and Siri attempt from the trusted definition, so a self-consistent but shortened plan cannot pass. It also reconstructs App Feature inputs and observations from the trusted binding, fixture and raw child output. A collection with no required cases cannot qualify. Executed optional routes are bound to their own saved children; their case assertions do not become required failures. A full collection batch still fails if any planned member or route failed, matching the app's batch verdict. A selected or failed-only rerun includes only the new child evidence for selected cases; unselected members appear as not run in the result. A partial baseline or candidate exits 20 for full-collection comparison even if every selected case passes. Older green rows are not borrowed into the new batch.

## Failure checks

The command rejects an altered requirement, source or app build mismatch, missing child route, unlisted file, symlink, path traversal, oversized file, wrong checksum, and unsupported schema or policy. A saved report.json saying “passed” does not override a failed assertion or missing child evidence. Keep incomplete and failed bundles for diagnosis; changing expectations to make them green creates a different requirement.
