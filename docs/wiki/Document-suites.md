# Turn a document into an evaluation suite

[Projects and suites](Projects-and-suites.md) · [Models and scoring](Models-scoring-and-tools.md)

Use **New Suite → From document…** to draft questions, reference answers, and scoring criteria from a specification or product guide. The answering model receives the retained source context with each question. This tests answering from supplied information; it does not test document retrieval or prior knowledge.

## Import and inspect

Choose or drop one text-based PDF, Markdown, or UTF-8 text file. The import accepts up to 5,000,000 bytes, 200 selected PDF pages, 512 passages, and 128,000 selected characters. To narrow a large document, enter a first and last page before choosing the file. For text/Markdown, that range selects blank-line-separated text blocks.

Inspect the extracted passages and choose which ones to consider. PDF page labels and Markdown headings are retained. Scanned pages are reported as omitted; diagrams and complex tables are not interpreted. Long sections are split into smaller passages, so inspect definitions and exceptions that may cross a boundary.

## Generate and review

Request 5, 10, or 20 drafts. Generation uses the on-device model and may return fewer questions when the source cannot support enough distinct cases. **Stop generation** keeps completed drafts. **Save and close** retains progress; reopen the same project's document flow to resume. A model availability error does not switch generation to a cloud provider.

For each draft:

1. Read the question and reference answer.
2. Review one to four case-specific scoring requirements. Each must occupy one line.
3. Inspect the supporting quotes and the complete source context. **Quote found** means the quote exists, not that the answer is correct.
4. Use **Add context** when neighboring passages contain required definitions or exceptions. Remove unused added context if it makes the request too large.
5. Choose **Accept source review**, or discard the draft.

The coverage count reports selected passages represented by accepted cases. It does not establish complete requirements coverage. Omitted and failed generation attempts remain visible. Retry failed attempts explicitly; retries preserve existing edits.

## Create and run

**Create suite with N cases** saves accepted cases and their source evidence together. It does not start a run. Use the normal run controls after checking model readiness.

Each document case overrides the shared suite rubric. Every requirement must score at least 3 out of 4 to pass. The answering request excludes reference-answer and rubric fields; the judge receives them along with the original question, response, and source context.

Document cases require complete inline context. Reference trimming, lookup tools, other tools, images, output schemas, and conversation setup are not supported. A request that cannot fit reports an error instead of silently dropping evidence. Independent judges also need a declared context window in **Settings → Judge connections**, plus the normal external-evidence disclosure approval.

Questions, answers, criteria, citations, and context remain editable in **Cases**. Changing them invalidates source review until accepted again. Renaming a case does not. Saved runs retain the original evidence even after edits or removal of the original document file.

## Export, restore, and limitations

The export control in **Cases** saves document-only suites, including questions, reference answers, rubrics, and retained source passages. The file contains document content: share it only with intended recipients. Model/judge bindings are omitted. **Import saved document suite…** restores this evidence into a new draft with on-device defaults and requires fresh source review.

Drafts and cases own their retained text locally. Discarding a draft does not remove evidence from a created suite or historical run. Source content is excluded from telemetry and routine diagnostic logging; local draft, suite, run, and export files intentionally contain it.

Production dataset conversion, automatic prompt improvement, plugin execution/import, and whole-suite replacement through MCP are currently unavailable for document suites. These paths reject the operation rather than discard context or case criteria. Mixed manual/document suites cannot use the document-only export route.
