# Turn a document into an evaluation suite

[Projects and suites](Projects-and-suites.md) · [Models and scoring](Models-scoring-and-tools.md)

Use **New Suite → From document…** to draft questions, reference answers, and scoring criteria from a specification or product guide. The answering model receives the retained source context with each question. This tests answering from supplied information; it does not test document retrieval or prior knowledge.

## Import and inspect

Choose or drop one text-based PDF, Markdown, or UTF-8 text file. The import accepts up to 5,000,000 bytes, 200 selected PDF pages, 512 passages, and 128,000 selected characters. To narrow a large document, enter a first and last page before choosing the file. For text/Markdown, that range selects blank-line-separated text blocks.

Inspect the extracted passages and choose which ones to consider. PDF page labels and Markdown headings are retained. Scanned pages are reported as omitted; diagrams and complex tables are not interpreted. Long sections are split into smaller passages, so inspect definitions and exceptions that may cross a boundary.

## Generate and review

Select a configured semantic judge and authorize sending the complete extracted document, questions, reference answers, rubrics, citations, and prior questions to its displayed endpoint. The judge needs structured outputs, a declared context window, and its saved credential. This selection does not change suite scoring defaults.

Request 5, 10, or 20 drafts. Generation uses the on-device model and may return fewer questions when the source cannot support enough distinct cases. **Stop generation** keeps completed drafts. **Save and close** retains progress; reopen the same project's document flow to resume. A model availability error does not switch generation to a cloud provider.

Selected passages choose the question topics. Generation consults and retains the complete imported source so definitions and exceptions elsewhere remain available. If that source and draft history cannot fit the on-device model, import a smaller page or text-block range; the app does not silently omit source context. Generation also stops before the saved suite's combined context limit, preserving the drafts that fit.

Before a draft appears, the judge first checks the question against the complete source and prior questions without seeing the proposed reference, rubric, or citations. It must independently identify an answerable, meaningful, distinct factual target; repeating part of an earlier compound question is a duplicate. A passing question then receives the separate source-support, accuracy, completeness, rubric, citation, and distinctness review. Every check in both stages must score 4. Rejected drafts receive up to two correction attempts; exhausted drafts are skipped. Provider or malformed-verdict errors stop the batch without accepting an unchecked draft. Saved attempts retain the verdict and rejection reason.

New drafts derive their initial semantic scoring requirement from the question and reference answer. The rubric includes the concrete reference facts and relevant restrictions, but explicitly treats reference details that the question does not request as optional. Check that the reference actually answers the question; a matching quote alone cannot establish this.

For each draft:

1. Read the question and reference answer.
2. Review one to four case-specific scoring requirements. Each must occupy one line.
3. Inspect the supporting quotes and the complete source context. **Quote found** means the quote exists, not that the answer is correct.
4. Check that the retained context includes required definitions and exceptions. Older drafts may need **Add context** for neighboring passages. Removing context requires a fresh review and must not remove a relevant exception.
5. Choose **Check and accept draft**, or discard the draft. Edits invalidate semantic approval; acceptance rechecks the edited content and current sibling questions. A current approval can be reused.

The coverage count reports selected passages cited by accepted cases; retaining a passage as background does not count as covering it. It does not establish complete requirements coverage. Omitted and failed generation attempts remain visible. Retry failed attempts explicitly; retries preserve existing edits.

## Create and run

**Create suite with N cases** saves accepted cases and their source evidence together. It does not start a run. Use the normal run controls after checking model readiness.

Each document case overrides the shared suite rubric. Every requirement must score at least 3 out of 4 to pass. The answering request excludes reference-answer and rubric fields; the judge receives them along with the original question, response, and source context.

Document cases require complete inline context. Reference trimming, lookup tools, other tools, images, output schemas, and conversation setup are not supported. A request that cannot fit reports an error instead of silently dropping evidence. Independent judges also need a declared context window in **Settings → Judge connections**, plus the normal external-evidence disclosure approval.

Questions, answers, criteria, citations, and context remain editable in **Cases**. Changing them invalidates source review until accepted again. Renaming a case does not. Saved runs retain the original evidence even after edits or removal of the original document file.

## Export, restore, and limitations

The export control in **Cases** saves document-only suites, including questions, reference answers, rubrics, and retained source passages. The file contains document content: share it only with intended recipients. Model/judge bindings are omitted. **Import saved document suite…** restores this evidence into a new draft with on-device defaults and requires fresh source review.

Drafts and cases own their retained text locally. Discarding a draft does not remove evidence from a created suite or historical run. Source content is excluded from telemetry and routine diagnostic logging; local draft, suite, run, and export files intentionally contain it.

Production dataset conversion, automatic prompt improvement, plugin execution/import, and whole-suite replacement through MCP are currently unavailable for document suites. These paths reject the operation rather than discard context or case criteria. Mixed manual/document suites cannot use the document-only export route.
