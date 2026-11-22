# Review working record: {{TITLE}}

Change: {{CHANGE_ID}}
PR / authoritative review: {{PR_LINK_OR_NOT_OPENED}}
Reviewed revision: {{REVISION}}
Policy: root `REVIEW.md` at {{REVIEW_POLICY_REVISION}}
Spec / plan: {{ARTIFACT_LINKS_AND_REVISIONS}}
Status: awaiting review

## Findings
| Pass | Severity | File/line | Evidence and consequence | Disposition / fix |
| --- | --- | --- | --- | --- |
| {{BUGS_SECURITY_OR_COMPLIANCE}} | {{IMPORTANT_OR_NIT}} | {{LOCATION}} | {{EVIDENCE}} | {{DISPOSITION}} |

Run all three passes. No findings in a pass means explicitly saying so after review, not leaving an unreviewed blank. Report at most five nits and count the remainder.

## Scope, documentation, and recurring mistakes
{{SPEC_PLAN_MATCH_STALE_DOCS_AND_SECOND_OCCURRENCE_CORRECTIONS}}

## Rechecks after fixes
{{VERIFICATION_LINKS}}

## Human code-owner decision
Pending. Record actual human decision with reviewed revision and authoritative PR reference. The authoring agent cannot provide this approval. Do not treat this working file as branch protection.
