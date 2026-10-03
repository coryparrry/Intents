# Evaluation review and regression workflow

Status: implemented and reviewed; targeted tests passed. Native UI acceptance awaits an unlocked Mac. Independent branch `codex/eval-review-workspace`, based on stack tip `078fa0c96abf60ebe67a436fa5a00f206b7f00e4`. Do not register it in the existing stack or merge it before that stack. Rebase onto main after the stack lands; review the feature diff against this recorded tip until then. Existing dirty work is excluded.

## Research and product intent

Evals improve an application when observed failures become explicit expectations, repeatable checks, and verified changes. A human first examines the interaction and its user-facing outcome; labels and explanations reveal product-specific requirements. Coding agents help with sampling and proposals, while humans confirm the quality bar. Objective properties use deterministic assertions; subjective qualities use a judge evaluated against independently labeled examples. Evaluate the full outcome first and inspect recorded intermediate stages to diagnose failures.

Sources read before implementation:

- [Husain and Shankar, Building eval systems](https://www.lennysnewsletter.com/p/building-eval-systems-that-improve): discovery, human ground truth, evaluator choice and judge validation. Public preview only; paid ending unavailable.
- [Husain and Shankar, Advanced evals](https://www.lennysnewsletter.com/p/advanced-evals-how-to-find-and-fix): output-specific review interfaces, human-first annotation, representative and random sampling, confirmed failure patterns. Public preview only; paid ending unavailable.
- [Authors' error-discovery methodology](https://github.com/ai-evals-course/evals-skills/blob/main/skills/error-discovery/SKILL.md): review the actual data structure, preserve meaningful dimensions, combine coverage and random sampling. Used as research, not installed or executed.
- [Apple, Evaluating prompts](https://developer.apple.com/documentation/foundationmodels/evaluating-prompts-to-measure-performance-and-improve-model-responses): measurable criteria, core/challenge/known-failure datasets, repeated generations and human-aligned judging. Read through installed Xcode documentation.
- [Apple, Designing effective evaluations](https://developer.apple.com/documentation/evaluations/designing-effective-evaluations): probabilistic outputs, model changes and contextual sensitivity.
- [Apple, Designing effective model-judge evaluators](https://developer.apple.com/documentation/evaluations/designing-effective-model-judges): reference-guided judgments and human alignment.
- [Apple, SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel): availability conditions and model changes with OS releases.

### Apple Intelligence adaptation

Review saved on-device runs and real developer-feature runner outputs using their captured prompts, conversations, structured values, tool evidence and environment. Display OS, locale, provider and device evidence when captured; unknown information stays unknown. Availability, cancellation, incomplete capture and transport failure remain execution issues, not semantic failures. No inferred internal Apple reasoning, unobserved state change, or Siri qualification. App Intent/Siri routes retain their separate existing evidence contracts.

Examples: assert an extracted date, entity ID or schema field with code; assess summary fidelity using a verified reference and calibrated judge; test conversation context through preserved setup/history; confirm a real app state change with developer-owned evidence. An output's structure alone cannot prove its factual correctness or a completed action.

## User workflow and UI contract

Add **Review** to the existing suite page selector. Reuse the existing page width/margins, `WorkspacePaneLayout`, `WorkspacePanelHeader`, `WorkspaceSearchField`, `WorkspaceIcon`, `WorkspacePill`, `workspaceSurface`, `workspaceInset` and `workspaceTextWell`. Follow existing typography, native controls, semantic status colors and narrow-layout behavior. No new palette, global layout, window, asset, style system or animation.

Review panes:

1. **Samples**: saved sample list and evidence/detail editor. Default judge hidden. Show input, response, verified reference when recorded, conversation and captured execution context. Structured JSON is displayed as a readable field tree without executing content. Save a human pass/fail or needs-more-evidence verdict, explanation and user-defined failure tags. Review is available for collect-only runs without an AI assessment. Source failures cannot receive semantic pass/fail labels.
2. **Patterns**: human-confirmed failed examples grouped by normalized tags, with drill-down to the sample. Show unique cases and reviewed-example counts rather than claiming production prevalence. Suggestions from agents are visibly pending until accepted or rejected by a human. Tags are hypotheses about observable behavior, not asserted root causes.
3. **Judge checks**: existing corrected examples and new reviewed examples can become check examples. Label groups as development or held-out test; repetitions and runs of the same case stay in one group. Existing examples default to development. Run checks using the existing consented independent-judge replay. Show accepted failures, rejected successes, correctly accepted successes, correctly rejected failures, unavailable/error examples, group counts and explicit denominators. No claimed reliability when one class is missing; do not aggregate incompatible scoring contracts into one rate.

A diverse review queue orders representatives from different cases/providers/outcomes and reproducible pseudorandom picks. Include passed and collected examples. Describe it as a discovery sample, not an unbiased prevalence estimate. All samples remain accessible through filters/search; no mandatory 10/100-example gate.

## Data, evidence and safety contracts

- Persist annotations, proposals and promotion links in additive suite-local review state. Decode old state with an empty review collection. Local annotations are not embedded into repository suite definitions or used silently as release approvals.
- Bind each review to run ID, sample ID and a digest of immutable subject evidence. Judge selection changes cannot invalidate the human's observed output. Changed/missing source evidence marks a review stale and prevents promotion/calibration.
- Human verdicts do not overwrite generated output, original scores, reassessments or existing human corrections. Require a concrete explanation for a verdict; allow undecided notes. Bound text, tags and proposal counts. Preserve save failures and rollback in-memory mutation.
- Agents may list review samples and propose verdicts/notes/tags through narrowly scoped MCP tools. They cannot silently confirm human labels. Suggestions retain their pending/accepted/rejected state; accepting produces a separate human annotation. Existing agent authorization governs MCP access.
- Regression promotion creates a new case with a provenance link and an explicitly supplied reference/expected value. Preserve the source prompt, conversation/history and field assertions. Never copy the known-bad response as the expected answer. Fail closed when source evidence is incomplete, altered, or current subject instructions/features/attachments differ. Preserve unrelated draft edits; surface a clear blocked reason. Use existing scoring settings and case/sample limits.
- Persist the promoted case as part of the existing atomic suite save and keep provenance in the case, so retry cannot duplicate it after a review-state write failure. Do not regenerate or rejudge the source during promotion.
- Judge checking replays captured outputs only. Preserve existing external-evidence disclosure and attachment approvals. Development examples are for tuning; held-out examples must not enter prompts automatically. A partition change moves every example from the same case to prevent leakage.
- No new telemetry or network service. No speculative causal labels, automatic prompt changes, baseline approval or release gating. Keep legacy judge scores and policies intact; review decisions are binary plus explanation.

## Integration

Existing instruction experiments and run comparisons are reused after promotion. The review UI links back to saved reports/traces and suite Cases/Compare instead of implementing another runner. `EvaluationStore` remains the persistence authority; new pure review workflow/analysis helpers live in focused files. Extend existing judge replay report with group-aware calibration summaries. MCP review operations share the same validation and source binding as the UI.

## Acceptance and verification

- Existing stack and dirty checkout unchanged. Independent feature diff starts at the recorded base.
- Old state/runs/cases decode; new review data survives save/reload and project/suite switching.
- Unconfirmed drafts survive navigation and relaunch, scoped to the exact source digest; write failures retain session edits and display an error. Confirmation alone creates a human label.
- Human review works on unscored saved outputs with the judge hidden. Execution errors remain undecided. Notes and tags survive, original evidence/scores remain unchanged.
- Changed/missing evidence, invalid labels, oversized inputs, foreign-suite references and failed persistence are rejected safely.
- Diverse queue is deterministic, unique and includes coverage beyond failures. Filters preserve valid selection.
- Patterns count only confirmed current human failures; pending/rejected suggestions cannot enter statistics or release decisions.
- Promote a confirmed complete failure to a saved regression with a supplied expected answer and provenance. Preserve conversation/assertions; retry deduplicates. Reject incompatible subject context, missing snapshots and full suite limits.
- Judge test/development groups stay disjoint by case; unavailable results are explicit; missing classes show no unsupported rate. Compatible contract groups are reported separately.
- Meaningful unit/integration regression tests cover persistence, evidence binding, failure paths, promotion, sampling, proposal confirmation and calibration. Native UI tests cover review/save/reload/promotion/navigation and narrow layouts.
- Build the exact worktree and inspect its real native UI in light/dark and a narrow window, using the existing design as reference. Close the app and any Xcode workspace opened for this work after verification. No simulator is required.
- Independently adversarially review a stable feature diff, verify material findings, and rerun affected checks after fixes. At most two UI fix/recheck rounds; report remaining limitations.

## Using the workflow

Open a suite in the editor and choose **Review**. Samples shows captured outputs without the AI verdict; write a note, select a human verdict and optionally add comma-separated failure tags. Unconfirmed edits are retained as local drafts. **Save review** confirms the label. **Patterns** groups current confirmed failures and opens their source examples.

For a complete confirmed failure, **Create regression case** requires a correct expected response or verified reference. The case opens in the existing Cases editor and retains source provenance. Use the existing Compare/instruction-experiment workflow to evaluate a change against the suite. Promotion preserves the original conversation and assertions and checks historical subject settings and attachment bytes.

Select a current AI rubric assessment in a saved report before **Use as judge check**. Keep tuning examples in Development; reserve Held-out test for untouched validation examples. Every repetition/run of a case moves together. Choose an existing approved judge connection in Judge checks to replay recorded outputs and inspect false acceptance/rejection counts and unavailable sources. Existing external-evidence consent remains mandatory.

Agents can call `eval_list_review_samples` with the current suite ID to obtain bounded previews and source digests, then `eval_propose_review` with those IDs/digest and an explicit proposal ID. The native Suggestions disclosure accepts or rejects each proposal. An agent cannot confirm a human label through these tools.
