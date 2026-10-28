# PR #180 review-comment triage — 28 October 2026

> Follow-through: the user subsequently authorized fixes and merge when ready. Both findings are corrected in source; the six focused backend tests pass and an independent review found no material issue. The PR records current-head hosted validation, thread resolution, and the final merge state.

**Original complete inventory: one unresolved inline thread, one review summary, and one general status comment. Two verified root causes: 1 Fix now, 1 Fix if cheap, 0 Defer, 0 Ignore.** One is the reported formatting issue; the other is a separate reference-budget defect found while testing that report.

PR: [#180](https://github.com/coryparrry/Intents/pull/180). Reviewed head: **3ce8f52ac1d7ccfc4bfa945ddd1f9d3957a74c54**. Base: 25214c175df16b29e013f5454c79ccecaa5924b9. The local checkout matched the PR head and was initially clean.

## Inventory and scope

- Inline feedback: one thread, one comment, unresolved and not outdated. [Original finding](https://github.com/coryparrry/Intents/pull/180#discussion_r4401465607).
- Review submissions: one COMMENTED review containing a summary of the same inline finding; no additional standalone finding.
- General comments: one [CodeRabbit review-skipped notice](https://github.com/coryparrry/Intents/pull/180#issuecomment-6470879576). It reports that the PR exceeds its file limit and lacks review capacity. This is a coverage notice, not a code finding or an instruction to change billing or split the PR.
- GraphQL total counts, returned counts, and hasNextPage=false were verified for threads, nested thread comments, reviews, and general comments. A final refetch retained the same head and feedback IDs.
- All applicable current PR checks succeeded. Optional/retargeted checks and CodeRabbit were skipped. Passing CI does not cover the newly demonstrated boundary cases.
- The initial triage was a read-only source/feedback review with isolated synthetic backend probes. It made no code edits, commits, pushes, replies, resolutions, or external issues. The authorized follow-through is recorded below. No UI tests or native execution ran locally.

## Findings

| ID | Bucket | Priority | Confidence | Result |
| --- | --- | --- | --- | --- |
| PR180-01 | Fix now | P2 | High | Ordinary reference bundles can import successfully but violate export's smaller aggregate reference budget. |
| PR180-02 | Fix if cheap | P3 | High | Deep drafts can fit compact import limits but fail export solely because of indentation. |

The two failures are independent. Switching export to compact JSON fixes PR180-02, but leaves PR180-01.

## PR180-01 — imports bypass the aggregate reference budget

**Fix now, high confidence.** The common import/export workflow accepts valid files that cannot subsequently be exported. The individual files, total request, complete bundle, saved suite, and integrity metadata all satisfy their respective admission checks.

### Current-head evidence and reachable trigger

[workspace.mjs:62](https://github.com/coryparrry/Intents/blob/3ce8f52ac1d7ccfc4bfa945ddd1f9d3957a74c54/plugins/apple-foundation-evals/server/workspace.mjs#L62) checks the complete import bundle against 32 MiB, then calls importReferences. [references.mjs:66](https://github.com/coryparrry/Intents/blob/3ce8f52ac1d7ccfc4bfa945ddd1f9d3957a74c54/plugins/apple-foundation-evals/server/references.mjs#L66) checks file count, identities, and individual files, but has no aggregate encoded-size preflight. It then extracts references and saves the suite.

Export subsequently calls exportReferences. Its [exact aggregate guard at references.mjs:60](https://github.com/coryparrry/Intents/blob/3ce8f52ac1d7ccfc4bfa945ddd1f9d3957a74c54/plugins/apple-foundation-evals/server/references.mjs#L60) rejects anything above **16,000,000 base64 bytes**. The error calls this a “16 MiB” limit; the actual constant is decimal 16,000,000.

A real isolated EvaluationApp.call probe produced:

~~~text
files:                 3 × 4,999,998 raw bytes
aggregate base64:      19,999,992 bytes
complete bundle:       20,000,341 bytes (< 33,554,432)
JSON-RPC request:      20,000,507 bytes (< 68,157,440)
import:                succeeded
saved suite:           51,421 bytes, 3 attachments
integrity metadata:    matched all original bytes
export:                rejected by the 16,000,000-byte reference cap
mock extraction calls: 3
native/UI executions:  0
owned fixture:         removed
~~~

### False-positive checks

Each file is below the existing 5,000,000-byte individual limit; three files are below the 20-file limit. The saved definition is below 1 MiB. Both request and complete-bundle limits pass, and all integrity fields match. These per-file sizes already occur in the existing positive boundary fixture. No later head commit fixes the path. This failure occurs before JSON formatting and therefore is not a duplicate of PR180-02.

If unchanged, users can import ordinary large reference collections, receive a successfully saved suite, and discover later that portable export is unavailable. Existing data remains saved, but the advertised export/backup workflow fails.

### Fix brief

- **Desired behavior:** an accepted portable import remains exportable under the existing resource budgets.
- **Smallest correction:** share the exact 16,000,000 encoded-reference budget between import and export. Reject an excessive aggregate during import preflight, before extraction, reference writes, or suite persistence.
- **Stable interfaces:** retain the separate 32 MiB complete-bundle bound, request bound, per-file/count limits, attachment identities, integrity checks, and portable JSON fields. This correction does not require raising the export resource budget.
- **Acceptance:** the demonstrated three-file bundle rejects before any extraction or persisted side effect; exactly 16,000,000 encoded bytes still import/export/re-import; the smallest possible encoded overrun, 16,000,004 bytes, rejects.
- **Prevention:** add focused cases to [backend-portable-bounds.test.mjs](https://github.com/coryparrry/Intents/blob/3ce8f52ac1d7ccfc4bfa945ddd1f9d3957a74c54/plugins/apple-foundation-evals/tests/backend-portable-bounds.test.mjs), including unchanged storage and zero-extraction assertions on rejection. The existing positive fixture stays just below the aggregate boundary at 15,999,992 encoded bytes, so it cannot detect this asymmetry.
- **Validation and scope:** run the focused backend boundary suite and the full Plugin workflow on GitHub for a fix. Keep work limited to portable-reference admission and its regressions.
- **Adjacent risk:** count the canonical encoded size that export will produce, preserve legacy attachment matching, and enforce admission before partially writing earlier files.

Probe provenance: [script](/tmp/intents-prelaunch-fixes-20261028/pr180-reference-budget-probe.mjs), [output](/tmp/intents-prelaunch-fixes-20261028/pr180-reference-budget-probe.log).

## PR180-02 — indentation alone can make an accepted draft unexportable

**Fix if cheap, high confidence.** The reviewer's formatting diagnosis is real, but its straightforward near-32-MiB reference example misses earlier guards. Reachability is through an accepted draft with a deep field schema.

### Current-head evidence and reachable trigger

[suiteBundleJSON at workspace.mjs:19](https://github.com/coryparrry/Intents/blob/3ce8f52ac1d7ccfc4bfa945ddd1f9d3957a74c54/plugins/apple-foundation-evals/server/workspace.mjs#L19) serializes with optional indentation, then checks that serialization against the same 32 MiB limit. Import uses compact JSON at line 62; export passes the pretty-print flag at [line 63](https://github.com/coryparrry/Intents/blob/3ce8f52ac1d7ccfc4bfa945ddd1f9d3957a74c54/plugins/apple-foundation-evals/server/workspace.mjs#L63).

[saveSuite at workspace.mjs:28](https://github.com/coryparrry/Intents/blob/3ce8f52ac1d7ccfc4bfa945ddd1f9d3957a74c54/plugins/apple-foundation-evals/server/workspace.mjs#L28) normalizes imports as drafts. [app-format.mjs:79](https://github.com/coryparrry/Intents/blob/3ce8f52ac1d7ccfc4bfa945ddd1f9d3957a74c54/plugins/apple-foundation-evals/server/app-format.mjs#L79) defers the execution schema depth/node check in draft mode. The [1 MiB saved-definition check at line 138](https://github.com/coryparrry/Intents/blob/3ce8f52ac1d7ccfc4bfa945ddd1f9d3957a74c54/plugins/apple-foundation-evals/server/app-format.mjs#L138) measures compact JSON, which does not bound indentation expansion.

A real isolated API probe used 400 nested object fields followed by a bounded leaf subtree:

~~~text
compact input:         674,016 bytes
saved compact suite:   674,234 bytes (< 1 MiB)
pretty serialization:  59,255,432 bytes (> 32 MiB)
import:                succeeded
export:                rejected: Portable suite bundle exceeds 32 MiB
reference files:       none
native/UI invocations: 0
~~~

### False-positive checks and impact

Ordinary definitions are capped at 1 MiB including JSON escaping, and exported reference base64 is capped at 16,000,000 bytes. Those guards defeat the reviewer's simple ordinary-reference example, but do not defeat the demonstrated deep-draft case. The real probe passed normalization and persistence and used no references, so neither a reference limit nor merely invalid input explains its export failure.

This is an exceptional draft shape, rather than an ordinary runnable suite. Data is still saved; export is blocked. A compact-export correction is small and within scope, so Fix if cheap fits its limited impact.

### Correction and prevention

Use the same compact serialization for export's returned JSON and its byte measurement as import, while preserving suite/reference content, schema, filename, and revision. Alternatively, retain normal pretty output only when it fits and use a validated compact fallback. Measuring compact JSON but still returning oversized pretty JSON would leave the round-trip contract broken.

Add a separate regression that imports the accepted draft, exports within the bound, and reimports into a fresh store with equivalent retained draft content. Retain genuine oversized-input rejection tests. Do not close this by rejecting all draft schema states that the editor intentionally supports.

Probe provenance: [reconstructed script](/tmp/intents-prelaunch-fixes-20261028/pr180-indent-probe.sh), [original output](/tmp/intents-prelaunch-fixes-20261028/pr180-indent-probe.log).

## Original triage disposition

The inline comment should remain unresolved until its formatting correction and regression pass. PR180-01 also needs a separate reference-budget correction; compact serialization alone is insufficient. No remote thread status was changed during triage; the subsequent PR workflow records its final resolution.

The current green PR checks remain valid evidence for their existing test coverage, not for the missing boundary regressions above. GitHub feedback snapshots, final pagination inventory, and probe artifacts are retained under /tmp/intents-prelaunch-fixes-20261028/.


## Authorized remediation and merge gate

The user requested merging once ready, authorizing the two verified corrections, validation, the review response, and resolution before merge. A backup branch preserves the previous PR head; the branch was rebased onto main's guidance-only update before this source checkpoint.

- **PR180-01:** import and export now use one exact 16,000,000-byte canonical base64 budget. Import validates every incoming file and its aggregate before any extraction or reference writes. Individual size/count, identity, integrity, complete-bundle, and transport limits remain. Direct file-add workflows retain their existing export cap.
- **PR180-02:** suite export now returns the same compact serialization that import measures. Draft normalization, portable content, filename, and revision are preserved.
- **Regression coverage:** six focused backend tests passed, including the ordinary three-file overflow, smallest padded overrun, exact-boundary roundtrip, existing export rejection above the reference cap, deep-draft export/reimport, the existing positive bundle above 16 MiB, and true complete-bundle rejection. Some tests cover multiple assertions/scenarios; six is the executed test count.
- **Independent review:** the stable three-file source/test diff received a read-only review with no actionable findings.
- **Local checks:** pinned plugin dependency installation, typecheck, UI bundle compilation, distributable packaging, 100% function documentation (2,568/2,568), changed-function documentation (366/366), documentation-detector tests (24), pinned actionlint, shellcheck, and example compilation passed. Broader backend results and reusable evidence are recorded in the PR's verification section and the pre-push evidence file.

The complete proposed PR diff selects full native, portable, Python/macOS, production, and UI coverage. Successful prior checks are reused before push only where their source, tests, workflows, build inputs, and environment are unchanged. The only runtime edits in this follow-through are the two standalone JavaScript backend files and their focused backend tests; the base update changes AGENTS.md only. The user explicitly requires UI tests on GitHub, which is disclosed in the PR. Current-head hosted checks and all review feedback must pass/reconcile before merge; prior successes do not satisfy that final gate.

Authoritative final delivery record: [PR #180](https://github.com/coryparrry/Intents/pull/180). Local command logs and pre-push coverage/evidence are under /tmp/intents-pr180-merge-20261028/.

### Final pre-push checkpoint

The complete local backend run recorded 158 passes and one 30-second timeout during severe machine contention. With lower load and no parallel validation work, the unchanged affected file passed all six tests in 7.97 seconds; the exact-boundary case took 3.59 seconds. No assertion, deadline, or implementation was loosened. The retained runs provide passing evidence for all 159 backend cases. The user then explicitly requested that remaining tests run on GitHub; no further local test runs are part of this follow-through. This push-gate exception is disclosed in the PR.

Current-head CI, Plugin validation, all selected UI tests, and all review feedback are required to pass/reconcile on GitHub before the authorized merge.
