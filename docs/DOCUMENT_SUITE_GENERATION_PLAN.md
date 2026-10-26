# Turn documents into evaluation suites

Status: reviewed proposal for the next release, 26 October 2026. The document-assisted answering mode is confirmed; the remaining scope and limits are recommendations, not implemented behavior.

## Outcome

Import a specification or product guide and turn it into a runnable evaluation suite. Intents drafts questions, reference answers, and case-specific scoring criteria, with source passages beside every draft. The user checks and accepts the drafts before creating the suite.

Confirmed product decision: the model being evaluated receives document text when answering. This evaluates its ability to answer using supplied information. The first release supplies selected passages directly; it does not measure retrieval quality or whether the model already knows the product.

The reference answer and scoring criteria belong to the judge. Their fields and review metadata must never enter the answering model's request. The document can naturally contain the same words as the reference answer; test separation of fields and request construction, not absence of those words.

## First-release scope

| Decision | Proposed behavior |
|---|---|
| Entry point | **New Suite → From document…**, alongside creating a suite manually. |
| Input | One local, text-based PDF, UTF-8 Markdown, or plain-text document. |
| Coverage | Select PDF pages or text sections, then inspect the extracted text. |
| Draft count | Request 5, 10, or 20 cases; default to 10. Return fewer when the source cannot support enough distinct cases. |
| Question types | Direct facts, applying a documented rule, and documented limits or exceptions. Generate only types supported by the selected text. |
| Generation | On-device Foundation Models, structured output, small bounded batches, visible progress and cancellation. |
| Review | Edit questions, answers, and criteria; inspect sources; accept or discard each draft. |
| Result | A new suite using AI rubric scoring, retained document context, accepted cases, and source provenance. Creation does not start a run. |
| Execution | Single-turn text questions with complete per-case source context supplied inline. Tools, reference search, images, conversations, and app/code runners are outside this flow. |
| Default scoring | Existing on-device judge with the current 1–4 scale and pass threshold of 3 for every requirement. External answering or judging remains an explicit choice with the applicable disclosure. |

Keep multiple documents, website crawling, DOCX, OCR, interpretation of diagrams or complex tables, automatic updates when a source changes, and app/code execution outside this release. Do not add a new judge provider or scoring scale for this feature.

Appending into an existing suite can follow later. Starting with a new suite avoids silently changing existing instructions, scoring, or reference files.

Keep the ordinary suite editor available, but validate changes to scoring and execution settings against this contract. Do not let a later switch to reference search, automatic reference fitting, or a deterministic metric silently change what a document-generated case measures. Unsupported combinations need a clear explanation and cannot run.

## User workflow

### 1. Import and inspect

Choose or drop a document. Show its name, page or section count, extraction warnings, and a readable preview. Preserve PDF page boundaries and Markdown headings. For plain text, use stable numbered passages.

Use the existing 5,000,000-byte text/PDF file limit. Propose a separate 128,000-character ceiling for selected extracted source text; this is a storage/selection ceiling, not a model context allowance. Confirm it against measurements in stage 1. Extraction itself must be bounded and cancellable: inspect PDF pages incrementally, cap retained extraction output, and stop with a narrower-selection recovery action. A small file can expand into substantial extracted text. Finalize page/work limits before enabling PDF import; do not extract an unlimited document first and apply the text limit afterward. Never silently truncate and then claim the whole document was considered.

Encrypted or unreadable PDFs, scans without usable text, invalid UTF-8, and empty selections produce specific recovery messages. Identify pages without usable text even in a mixed scanned/text PDF. Preview remains necessary because extracted text may lose layout or reading order. Render imported text as text; do not execute Markdown/HTML or fetch linked images and resources.

### 2. Choose coverage

Default to all usable selected sections. Let users exclude sections and choose a draft count. Offer a simple mix of the three supported question types rather than a large configuration form.

Show the distinction between sections selected for consideration and sections actually represented by accepted cases. A heading list or page range does not establish requirement coverage. Report omitted and failed sections explicitly.

Preview the context unit used for a question before acceptance. Page and heading boundaries are navigation aids, not proof that a passage is self-contained: definitions, exceptions, and cross-references may require adjacent or additional passages. Include those dependencies explicitly or flag the question as unsuitable. Coverage counts a section only through accepted, source-supported cases and updates after edits or discards.

### 3. Generate drafts

Show progress by section or batch and preserve completed drafts when cancelled or when a later batch fails. A retry works on failed or explicitly selected batches and preserves user edits.

Use a fresh model session per batch and admit small outputs, initially one or two drafts at a time. A request for 20 cases is a job target, not one model response. Checkpoint completed validated batches and review edits. After app restart, restore the draft and offer **Resume generation**; do not silently restart inference. Ignore late responses from cancelled or superseded jobs. Limit automatic repair to one changed attempt per failed batch, then expose a retryable issue.

Each draft contains:

- A short name, question, and question type.
- A reference answer based only on the supplied document text.
- One to four observable, case-specific rubric requirements.
- Source snapshot identity, stable passage identifiers, page/heading locations, and supporting quotes.
- The source sections to supply to the answering model.
- Validation issues and review state.

Avoid duplicate paraphrases that test the same fact. Do not pad the requested count with unsupported questions. Questions that require unavailable diagrams, external knowledge, or unresolved contradictions are excluded or flagged for correction.

### 4. Review beside the source

Use a draft list and detail pane with **Question**, **Reference answer**, **Scoring criteria**, and **Source**. Selecting a citation opens its retained passage with the evidence highlighted. Show the complete source context that will go to the answering model separately from the shorter supporting quote.

Drafts start as **Needs review**. Users explicitly accept or discard them; multi-selection may support a batch action after inspection. Editing an accepted draft's question, answer, criteria, citations, or context returns it to **Needs review**. Missing fields, invalid citations, or unsupported source references prevent acceptance until corrected.

Keep the source snapshot immutable. Users can adjust selected context or choose another supporting passage without rewriting the source. Acceptance records the exact question, answer, criteria, citations, and context revision reviewed. Later edits to those fields in the Cases workspace require renewed source review before the changed case runs; historical runs retain their original reviewed revision. Renaming a case alone does not invalidate acceptance.

Use specific validation labels such as **Quote found** or **Needs source review**. A matching quote proves that the text exists, not that it logically supports the generated answer. Do not label model-generated answers as verified ground truth.

### 5. Create and run

**Create suite with N accepted cases** shows the name, accepted count, coverage summary, and the active scoring approach. It is available only with at least one accepted case and a valid suite.

Save the suite and its source evidence together. A failed save leaves the draft available for retry and does not expose a partly created suite. A repeated create action must not duplicate it.

The resulting cases remain editable in the normal Cases workspace. Source references remain inspectable after the original file moves or disappears. Before enabling Run, preflight both answering and judging with the selected providers; an imported document fitting the storage limit does not establish that either request fits. A suite may be saved while a model is unavailable, with its blocked run state visible. The user runs the suite through existing controls and reviews ordinary results and traces.

## Example

Suppose page 6 of a product guide says:

> Owners can export a workspace. Members can view reports but cannot export a workspace.

| Field | Draft |
|---|---|
| Question | A member needs a workspace export. Can they create it themselves, and which role can perform it? |
| Reference answer | No. Members cannot export a workspace; an owner can perform the export. |
| Criterion 1 | States that a member cannot export the workspace. |
| Criterion 2 | Identifies an owner as a role that can export it. |
| Criterion 3 | Does not invent an undocumented member permission or workaround. |
| Source | Page 6, retained passage and supporting quote. |

The answering model receives the question and the retained source section. The judge receives the question, response, reference answer, effective criteria, and source evidence. A correct paraphrase should pass; an invented permission should fail.

## Implementation design

### Reuse the existing evaluation workflow

Current source provides useful foundations:

- `EvaluationCase` stores the question in `prompt` and the reference answer in `expected`.
- `EvaluationSuite` currently supplies shared rubric text and reference attachments.
- CSV/JSONL case import already has a preview-before-commit pattern.
- Attachment import has bounded local file reads and PDFKit extraction, but currently flattens PDFs and truncates extracted text at 16,000 characters.
- `EvaluationPromptImprovementGenerator` demonstrates on-device structured generation and cancellation handling.
- Local and external judges currently validate one to four criteria, with scores from 1 to 4.

Important constraints found during review:

| Current behavior | Consequence for this feature |
|---|---|
| `EvaluationRunner+Prompt.swift` can shorten inline references under `fitReferences`, or route them to a lookup tool. | Document cases need a strict, complete context path that cannot fall back to either behavior. |
| `EvaluationSuite.needsModelJudge` and `usesSubjectModelForJudging` derive from the shared rubric. | Per-case overrides must affect judge selection and token reserves as well as the final scoring call. |
| `EvaluationStore` caps ordinary suite text at 256,000 characters, each prompt/answer at 32,000, and each rubric requirement at 4,000; attachment text is outside that suite-text calculation. | Count new rubric fields explicitly and enforce separate bounded source storage. Do not duplicate the document into every prompt or assume the existing validator bounds it. |
| Suite/case decoders read known fields; the suite's `version` is a user-facing string. | Adding optional fields or changing that string alone does not make old readers reject incompatible document cases. |
| Reassessment saves a suite-level rubric, while production datasets use a separate case model. | Update scoring identities and conversion contracts explicitly; serializing the main app model is insufficient. |

These observations describe the working tree inspected on 26 October 2026, which includes unrelated in-progress changes; they are not claims about a shipped build. Relevant sources are [models](../FoundationEvals/FoundationEvals/Models/EvaluationModels.swift), [prompt construction](../FoundationEvals/FoundationEvals/Services/EvaluationRunner+Prompt.swift), [storage and validation](../FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift), [reassessment](../FoundationEvals/FoundationEvals/Services/EvaluationReassessmentService.swift), and [production models](../Packages/ProductionEvals/Sources/ProductionEvals/Models/ProductionModels.swift). Keep extraction, generation, validation, and persistence in focused services rather than expanding the large `EvaluationStore`.

### Retain sources and draft state

Introduce focused models for a source snapshot, passages, draft job, draft case, and accepted-case provenance. Retain normalized text, page/heading anchors, original-file hash, normalized-content hash, extraction version, and stable passage IDs. IDs and locations come from the importer, not the model. Normalize Unicode to NFC and use exact normalized quote matching for highlights, without persisting Swift string indices. Retaining the original PDF binary is unnecessary for the text preview.

Implementation decision: drafts retain one selected source snapshot; each accepted case owns a copy of only its required passages. This uses more storage when cases overlap, but keeps existing case/run snapshots and copies self-contained without a new shared-file ownership system. Bound the combined retained context and case criteria to 256,000 characters, in addition to existing suite-text limits. The reviewed digest freezes case content, citations, context, and criteria. Case names remain outside that digest.

Record generator/model identity where available, generation configuration and prompt/schema version. Draft review state and completed batches survive closing the flow or reopening the app. Persist job/batch IDs, source-selection identity, and a draft revision so retries cannot overwrite edits or insert a completed batch twice.

Publish a suite only after its complete source context and cases are durably staged. Allocate and persist the destination suite ID with the draft before publication; retries reconcile that same destination. Recovery after a crash between publication and UI acknowledgement must not create a second suite. Recover an empty unpublished staging directory, while preserving unknown or published evidence. With case-owned snapshots, deleting a draft or suite cannot delete a different owner's source text.

### Generate within model limits

Extract passages deterministically and split them at page, paragraph, or heading boundaries. Select coverage across the requested sections rather than repeatedly taking the start of the document. Simple passage indexing is sufficient for this release; no vector database is required.

Admit each generation request against the model's context size, accounting for instructions, source text, output schema, and reserved response tokens. Validate schema, field sizes, allowed passage IDs, quote matches, and duplicate candidates before presenting a batch. Citations must resolve within that batch's supplied passages; reject invented IDs and out-of-context quotes. An exact match is a structural check, while semantic support remains the user's review responsibility. Do not mark a contradiction resolved merely because one side has a matching quote.

Treat document text as untrusted material in generation, answering, and judging. Disable tools and network access for document generation through application configuration; prompt wording alone cannot guarantee resistance to embedded instructions. The application owns schema, passage identities, scoring scale, and persistence. Test instruction-like source text and fabricated citations. Generation stays on-device and reports model unavailability or refusal with a clear next step; it does not switch providers automatically.

### Keep source context separate from grading evidence

Store explicit per-case document context references. Assemble the answering request from shared instructions, the question, and complete selected source sections with enough surrounding context to preserve conditions and exceptions. Use the generation section as the initial context boundary rather than automatically reducing input to answer-bearing quotes.

Keep reference answers, rubric requirements, and review metadata out of that request. Give the judge the same complete source context, the candidate response, reviewed reference answer, and effective rubric. A supporting quote alone can omit an exception. Use a separate judge session with no generator history. Describe the reference as user-reviewed rather than machine-verified ground truth.

Budget generation, answering, and judging independently. Judge admission must include the full context, question, reference answer, rubric, schema, candidate-response allowance, and judge output reserve. Apply this to external judges too, using declared capabilities and conservative estimates where exact tokenization is unavailable. On overflow, require a smaller complete context unit or an explicitly selected capable provider; never trim source evidence, the candidate response, or the rubric to obtain a score. Failed admission is a configuration error, not a failed answer.

Freeze the prepared answering context, reviewed case revision, effective criteria, source identities, and request-format version with each run. Hashes alone cannot reproduce missing text. Reassessment uses the saved answering input and response; an explicitly revised rubric creates a separately identified assessment rather than rewriting the original one. Local generation does not imply every subsequent evaluation stays local.

### Add case-specific rubric overrides

Add optional case-level criteria with one shared effective-criteria resolver. A case override replaces the suite rubric for that case; a case without an override retains existing suite behavior. An empty override is invalid, not a fallback. Each effective rubric must still contain one to four requirements and obey current field limits. Preserve current aggregation: the lowest requirement score determines the result and every requirement must score at least 3 to pass. Show the override clearly in the editor and result inspector, including that editing the shared rubric does not update overridden cases.

Use the same effective criteria for judge selection, token reserves, local/external judging, admission/validation, reassessment, review checks, and supported batch execution. Include per-case criteria and source-context identities in scoring contracts, fingerprints, and assessment metadata; a changed case contract must invalidate comparisons or approvals that require an unchanged contract.

### Compatibility and supported consumers

Older suites must still load and score as before. New document suites need an explicit format/capability contract, separate from the editable suite version label. A new optional version field is not enough to protect against old decoders that ignore it. Choose a guarded format or non-legacy envelope and prove that a pre-feature reader cannot execute it as a plain suite. Do not emit a legacy-decodable payload that silently loses source context or criteria.

| Surface | First-release requirement |
|---|---|
| Native suite editor, runner, results, reassessment | Full support, including immutable context and effective per-case criteria. |
| Save/load, revisions, copy/duplicate | Preserve all references and retained source ownership; corrupt or missing evidence blocks the affected operation with a recovery message. |
| Evidence-preserving export/import | Round-trip a self-contained, bounded package with context, criteria, and provenance. Legacy CSV/JSONL cannot serve as a faithful export; disable that route for these cases unless clearly offered as a lossy question-only copy. |
| MCP, native plugin, production/frozen batches, experiment and improvement workflows | Preserve and execute the full contract, or explicitly reject the unsupported operation before conversion, mutation, or execution. Reading and writing through an unsupported consumer must not erase fields. |

Supporting every auxiliary workflow is not a prerequisite for the creation UI if it is safely gated; silent degradation is never an acceptable shortcut. A new MCP document-generation command is outside scope. Prompt improvement must not receive held-out questions, answers, or criteria. Cases based on the same fact or source context are correlated; do not describe a case-only split as independent document generalization. Group by source context or gate automatic improvement until its split and data boundaries are supported.

Implementation boundaries: document cases encode a versioned prompt object so pre-feature readers expecting a string fail decoding. The plugin rejects document cases explicitly. Production conversion, automatic improvement, and whole-suite MCP replacement are gated. The document-only JSON export includes retained source and rubrics, omits provider/judge bindings, and requires fresh review on import. A mixed manual/document suite is rejected by this export route rather than partially exported.

### Privacy and evidence

Document names, contents, source excerpts, generated questions, reference answers, and scoring criteria stay out of telemetry. Existing disclosures for external models and judges must accurately cover the source text sent to them.

Exports containing document evidence should make that inclusion clear and preserve enough material to reproduce the evaluation. Local suites, drafts, run traces, and exports intentionally retain content; telemetry and routine diagnostic logs must not. Before an external run, show the actual provider boundary: answering receives question/context, judging also receives answer/criteria/candidate output. Reuse the existing disclosure flow and re-evaluate it when provider or sent content changes. Hash changes indicate a different source snapshot, not an instruction to overwrite existing suites.

## Delivery sequence

| Stage | Reviewable result |
|---|---|
| 1. Prove one complete case | Hand-authored fixture with retained context and case criteria: answer, judge, save/reload, inspect, and reassess. Establish separate token budgets, strict context handling, bounded source storage, and old-reader rejection. Measure extraction/generation feasibility and finalize provisional import limits. |
| 2. Source import and persistence | Page/section-aware bounded extraction, preview and selection, immutable source snapshots, draft checkpoints, atomic publication, and recovery. |
| 3. Draft generation and review | Small structured batches, citation checks, coverage and duplicate handling, cancellation/resume, source inspection, acceptance invalidation, and suite creation. |
| 4. Compatibility and product integration | Exercise the supported-consumer matrix; implement full preservation or explicit gates. Verify exports, duplication, scoring identities, external disclosure, and storage cleanup. |
| 5. Release validation | Fixed corpus evaluation, UI flows, failure injection, privacy checks, performance measurements, and user documentation. |

Do not ship the creation flow before its cases execute and retain their evidence correctly. Stage 1 is the feasibility gate: if a useful representative case cannot fit the default local answering and judging path, revise context selection or supported scope before building the full wizard. Do not silently substitute a cloud model. Estimate release effort after this proof, because rubric propagation, format compatibility, and context limits dominate the uncertainty.

## Acceptance and release checks

- A user can import a supported guide, inspect extraction, request drafts, review citations, edit an answer or criterion, accept cases, create a suite, and run it successfully.
- Each accepted case has a nonempty question and answer, a valid effective rubric, resolvable source references, and preserved answering context. Quotes and locations resolve after restarting the app and removing the original source file.
- Captured answering requests contain source text and questions but no reference-answer fields, criteria, or review metadata. Judge requests include the effective case rubric and the evidence it needs.
- Exercise all three request budgets at their boundaries, including a judge request that overflows although answering fits. Assert that `fitReferences`, lookup mode, external-provider conversion, and response handling cannot shorten document evidence silently.
- Controlled outputs demonstrate that correct paraphrases pass and materially wrong answers fail for the example and representative fixtures. Existing suites without overrides retain their scoring behavior.
- PDF page boundaries, Unicode, empty/scanned/locked PDFs, Markdown headings, repeated headers, ambiguous rules, malformed output, instruction-like source text, oversized input, and context overflow have regression coverage appropriate to each behavior.
- Cancellation and partial failure preserve completed drafts; retry preserves edits; save failure preserves recoverable draft state; repeated creation cannot duplicate a suite.
- Inject crashes before and after suite publication, deliver a late cancelled batch, reopen a changed selection, and delete one of two source owners. Verify no duplicate suite, stale draft insertion, lost edit, or missing shared evidence.
- Coverage distinguishes considered, represented, omitted, and failed sections. There is no silent truncation or claim of exhaustive requirement coverage.
- Save/load, duplication, export/import, MCP access, native plugin execution, reassessment, and supported frozen-batch execution preserve context, criteria, and provenance or explicitly reject unsupported versions. Run evidence keeps its original source snapshot after edits.
- Use fixtures for pre-feature readers and mixed cases with/without rubric overrides. Verify old-reader rejection, scoring-contract changes, judge availability/reserves, and that unsupported export/conversion/edit routes cannot drop fields. Reassessment must preserve the original response and context.
- Verify keyboard navigation, focus, accessible labels, light/dark appearances, progress announcements, and source inspection through actual UI flows.
- Evaluate a fixed corpus of at least 10 varied documents, requesting at least 100 drafts in total. Include short/long guides, specifications, cross-page exceptions, mixed scanned/text PDFs, and contradictory or instruction-like text. Freeze fixtures, generation settings, and model/OS identity. Human review labels every surfaced draft: supported, useful/distinct, rubric-correct, and acceptable without substantive edits. Proposed release gates are at least 90% source-supported and 80% acceptable without substantive edits among surfaced drafts. Report counts and rates per document as well as overall, and separately report yield against requested drafts, structural rejections, duplicates, and failed/omitted sections so returning very little cannot masquerade as quality. Never pad weak documents to reach 100 outputs.
- Require at least 100 surfaced drafts before treating the percentage targets as evaluated. If the initial corpus yields fewer, retain its failures and extend the corpus with additional suitable documents; the gate remains unevaluated meanwhile. Every accepted release-fixture case must pass human source review. Use controlled correct paraphrases, omissions, and invented claims to validate scoring independently of the generator. Keep deterministic fixtures/stubbed-model tests in CI; report stochastic on-device quality separately and do not repeatedly rerun failures until a favorable sample appears.
- Measure time to first draft, total generation time, cancellation response, and memory on a supported Mac before setting a user-facing performance expectation.

## Implementation status

The implementation is isolated on `codex/document-suite-generation`, based on main at `2f9252d1c`. It includes document import, resumable draft generation, source review, per-case criteria, preserved evaluation evidence, portable export/import, and explicit rejection of unsupported conversion paths. The user guide is [Document suites](wiki/Document-suites.md).

Independent review identified and corrected criteria normalization, mixed-case judge selection, reassessment rubric selection, interrupted suite publication, bounded import cancellation, and citation editing. Deterministic app tests and actual UI flows are being validated separately from stochastic generation quality.

### Verification record — 26 October 2026

- Mac build and signed bundle verification passed with `script/build_and_run.sh --build-only`.
- Focused document, context-budget, review-workflow, observed-context, and persistence tests: **82 passed**. Compatible-judge coverage, including integrity regressions: **27 passed**.
- Document review → accept → create → relaunch: **2 UI tests passed**, then passed again after screenshot-driven spacing and singular/plural fixes. Both light and dark screenshots were inspected.
- Plugin compatibility and backend parity: **42 tests passed** using `node --test plugins/apple-foundation-evals/tests/document-suite-compatibility.test.mjs plugins/apple-foundation-evals/tests/backend-parity.test.mjs`.
- Live generation on macOS 27.2, using the default on-device Foundation Models model: the first single attempt returned no draft; the subsequent fixed batch returned **0 drafts from 10 attempts**. Raw synthetic-fixture inspection found a grounded answer marked `supported=false` and category labels used as criteria. Prompt version `document-draft-v2` corrects these two instructions; the failed v1 observations remain part of this record.
- One fixed v2 batch requested five drafts and produced **1 draft from 10 attempts**, with all nine omitted/duplicate/unsupported attempts retained. The first draft was answered and scored through the real runner. This live plumbing check plus the document regression rerun passed **20 tests**. The runtime reported **AFM 3 Core Advanced**. This is one synthetic passage, not a representative yield estimate.
- **Quality gate remains failed/unevaluated:** the response “Members cannot export a workspace. Owners can.” correctly answered the synthetic source, but the local judge assigned **1/4** with unsupported scope objections. The generated rubric also contained a redundant requirement. The successful plumbing assertion only establishes that an assessment was produced; it does not establish grading correctness. Preserve this false rejection as a calibration fixture before release. The fixed live test took about 82 seconds including generation, answering, and judging on a busy Mac; it is not a performance benchmark.

The UI uses a deterministic saved-draft fixture. It does not establish model generation quality. Likewise, synthetic live fixtures are not human approval of generated user content.

The 10-document/100-surfaced-draft human quality study and performance measurements above remain release gates. A successful build or synthetic smoke test does not satisfy them.
