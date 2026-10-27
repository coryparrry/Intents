# Document-suite quality evaluation

For the product workflow and limits, see [Document suites](wiki/Document-suites.md).
Build success, matching quotes, and successful model requests do not establish answer quality.

## Reproducible checks

`Verification/Automation/Fixtures/DocumentQuality/` retains the inputs consumed by
`script/run_document_quality.sh`: the 12-document corpus, scoring pilot and holdout,
current repair controls, focused generation regressions, follow-up scoring controls,
22 original semantic controls, and the five historical false approvals paired with five positive controls. Superseded fixture versions and recorded campaign output
remain in Git history rather than the feature diff. Do not alter expected outcomes
to make a failed implementation pass.

Each run requires a new absolute output directory. The runner snapshots its inputs,
relevant sources, source hashes, runtime identity, and exit status. Keep generated
logs, source copies, PDFs, model responses, and result bundles outside tracked source.

```bash
bash script/run_document_quality.sh unit /private/tmp/document-unit
bash script/run_document_quality.sh semantic /private/tmp/document-semantic-controls
bash script/run_document_quality.sh acceptance /private/tmp/document-acceptance-regressions
bash script/run_document_quality.sh focus /private/tmp/document-focused-regressions
bash script/run_document_quality.sh generation /private/tmp/document-generation-run
bash script/run_document_quality.sh controls /private/tmp/document-scoring-run
bash script/run_document_quality.sh holdout /private/tmp/document-scoring-holdout
bash script/run_document_quality.sh repairs /private/tmp/document-repair-regressions
bash script/run_document_quality.sh followup /private/tmp/document-followup-regressions
python3 script/document_quality_report.py /private/tmp/document-generation-run \
  --controls /private/tmp/document-scoring-run \
  --semantic-controls /private/tmp/document-semantic-controls \
  --labels /absolute/path/to/review.json
```

Live checks are opt-in. To select an independent judge, set
`INTENTS_DOCUMENT_QUALITY_JUDGE_CONFIG` to an isolated JSON copy of its connection
configuration. The harness uses the bound Keychain credential and synthetic inputs;
it does not change saved connections. Declare the model's verified context limit.
The runner snapshots the connection configuration, never its credential.

## Review and qualification

Review complete extracted sources and every surfaced question, reference, rubric,
and citation. The report emits review packets and checks source/candidate hashes,
attempt completeness, terminal success, scoring inputs, source hashes, and runtime
identity. Failed attempts remain in the attempt-yield denominator. Source-support
and acceptance rates use all surfaced candidates, including failed review labels;
qualification separately requires at least 100 surfaced drafts. Do not combine incompatible runs.

Human review is the default. An explicitly authorized automated review may use
`--reviewer-kind automated`; it never counts as human approval. Qualification needs
at least 10 documents, 100 requested and surfaced drafts, complete labels, 90% source
support, 80% acceptance without substantive edits, and passing frozen scoring and
semantic controls. Record holdout results separately. Focused regressions alone
cannot qualify the full corpus.

## Outstanding qualification

The last broad run stopped with exit 75 after 100 admitted drafts and 124 passage
attempts. Automated review found 95 acceptable without edits. No terminal summary
was produced, so this source is **not qualified**. A fresh broad-corpus run, full scoring requalification, and final distributable release checks remain unfinished.

The five historical false approvals motivating the question-only check were: attachment-retention timing, a circular sequence
number question, two duplicate warehouse dispatch/cancellation questions, and a
question confusing quote matching with factual correctness. They are frozen in `acceptance-regressions.json` with their original source and question history. The question-only stage must reject them before reference review; positive controls prevent rejecting their valid corrected or standalone forms. Live replay results are recorded separately from broad-corpus qualification.

The original [checkpoint](https://github.com/coryparrry/Intents/blob/880b29ec8778155fa47df487061ed442163ca601/Verification/DocumentSuiteQuality/PR_CHECKPOINT.md)
and [five findings with recorded evidence](https://github.com/coryparrry/Intents/blob/880b29ec8778155fa47df487061ed442163ca601/Verification/DocumentSuiteQuality/2026-10-27/v19-generation-stopped/automated-review.md)
are preserved at the pre-cleanup commit. Their historical test results do not
qualify later source changes.


## Acceptance-fix verification

The v6 question-only stage rejects all five historical failures before reference
review. All five positive controls pass. The original 22 semantic controls also
pass with the same production judge hashes, semantic policy, runtime, and original
control helper. The first combined command passed those 22, then stopped on a
compact-fixture decoding error; after correcting the loader, the ten-control
replay completed successfully. These are targeted checks, not a completed combined
campaign or a new broad-corpus qualification.

The acceptance-stage validation at `35888b17b` passed 92 focused document/judge Swift
tests and all 3 document UI flows; light and dark screenshots were inspected.
The report-integrity, shared-source, and plugin checks also pass. Subsequent native
feedback-fix regressions are checked by current-head CI.
