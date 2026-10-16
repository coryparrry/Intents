# Phase 6: saved failure and source fix comparison

The app accepts a released, assessed failure from a prepared simulator or Mac
workflow. It retains the original preparation and frozen checks, builds changed
source separately, and defaults to three attempts against each build.

The CLI exposes the same comparison:

```sh
intents-automation compare --baseline-support /path/to/baseline-support \
  --baseline-attempt SAVED_ATTEMPT_ID --support-root /path/to/candidate-support \
  --attempts 3
```

The candidate support directory must already contain a preparation of the changed
source. The command loads the canonical saved failure and derives the candidate
from the same executed steps, oracle, target, and host contract. It does not accept
replacement checks. Repeated fixture writes require frozen initial-state checks.

The saved report exposes `fixed`, `notFixed`, or `inconclusive`. `fixed` requires a
complete, released comparison in which every baseline attempt reproduces an
assessed assertion failure and every candidate attempt passes. A completed
`notFixed` comparison exits zero; an incomplete comparison exits one. Callers must
inspect `outcome` when deciding whether a fix succeeded.

The native acceptance harness changes only a staged copy of the fixture's real
completion implementation, saves its failure, restores the source, prepares the
candidate, and compares three attempts per build. Runtime defect toggles and
changed expectations cannot substitute for this source comparison.

## Validation

The shared focused run passed 219 Swift tests, including saved failure admission,
unchanged-oracle enforcement, comparison counts, conservative outcomes, Mac
approvals, and unresolved cleanup. The related Python harness/routing run passed
139 tests. Two independent source reviews completed; the process-ownership
finding was fixed and rechecked.

The live source comparison was not reached: the first Mac XCTest attempt timed
out enabling Automation Mode. Live source comparison, app UI acceptance, and
hosted CI remain pending. Unit tests and mocked harness checks do not replace
those runs.
