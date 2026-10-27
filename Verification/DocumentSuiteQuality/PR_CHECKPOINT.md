# Document-suite review checkpoint

This branch implements document import, on-device draft generation, source review and suite creation, plus per-case scoring and a configured semantic judge before draft admission. It is a draft PR: final qualification is incomplete.

## Acceptance behavior

All six semantic requirements must score 4. Structural quote errors and semantic failures receive at most two correction retries. Exhausted candidates are omitted; provider errors and malformed verdicts stop the batch. Content edits invalidate approval. Duplicate questions and repeated source facts are also checked locally. External review requires explicit document/endpoint authorization.

## Recorded verification

- Last completed focused Swift regression run: 41 tests passed.
- Python report-integrity tests: 18 passed.
- Semantic policy v5: 22/22 frozen controls passed using the configured DeepSeek judge.
- Five focused generation regressions passed, including correction of read-only autosave wording.
- Interrupted corpus: 100 admitted drafts across 10 completed documents, 124 passage attempts, 75 semantic rejections and three structural rejections. Independent automated review found 98 source-supported, 97 useful/distinct, 97 rubric-correct and 95 acceptable without edits.
- Corpus exit code 75; no completed summary. The current source is not gate-qualified. Full scoring rerun, updated UI tests and the final distributable build remain unfinished.

The five retained flags concern attachment-retention timing, a circular sequence-number question, two duplicated dispatch exceptions, and a question that confuses quote matching with factual correctness. See the [independent review](2026-10-27/v19-generation-stopped/automated-review.md) and [hash-bound labels](2026-10-27/v19-generation-stopped/automated-review.json). Automated labels are not human approval.

## Evidence included in this PR

The stopped run retains its attempts, semantic decisions, full extracted sources, synthetic input documents, source snapshots and runtime metadata under `2026-10-27/v19-generation-stopped/`. The passing semantic controls are under `2026-10-27/semantic-v5-controls/`; their frozen inputs are `../Automation/Fixtures/DocumentQuality/semantic-controls-v3.json`. Build logs, result bundles and older exploratory campaigns remain local and are not included in this PR. No credentials are stored in these artifacts.

A proposed independent question-answerability stage has not been implemented or validated. No additional provider runs were started for PR preparation.
