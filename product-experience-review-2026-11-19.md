# Intents app review, 19 November 2026

This is the running record of the native macOS app review. The baseline is `e7b01223d4fdbd53a57d134f1146b4c1d874b433`, confirmed as GitHub `main` at the start of the review. Work takes place in a dedicated checkout. Synthetic fixtures are used for verification.

The review follows tasks whose failure could lose work, misstate an evaluation result, block a supported workflow, or violate a stated privacy boundary. Cosmetic preferences and unverified hypotheses do not count as defects.

## Progress

- Confirmed the source baseline and located the workspace sidebar, app menu, Settings, and the native test scheme. The app is a local evaluation workbench for developers using Foundation Models or testing app actions.
- First pass traced workspace and suite persistence, case import and document drafts. It also traced Studio's per-app recovery and reproduced how a damaged draft could hide saved conversations.
- Second pass traced batch, review, and run evidence. It reproduced a batch storage rejection after form submission and found stale release-report text and inaccurate scheduling guidance.
- Final source pass traced the remaining navigation and handoffs. An independent audit added Overview, the Traces sidebar, guided Siri setup, documented backup and restore, Evaluation menu shortcuts, and the diagnostic clipboard export.
- The follow-up checked whether each workspace leads from setup to a saved result and a next action. It found three additional disconnects in Cases, Batch runs, and Siri Studio. The follow-up started from the hosted-tested `cafba2ebf` and uses source and isolated regression checks.
- The first-use pass simplified the route from opening Intents to an understandable pass or fail. It also made the sidebar destinations and run blockers clearer.

## Confirmed issues and fixes

| Issue | Reproduction and impact | Change and evidence |
| --- | --- | --- |
| **High.** Siri Studio cannot open saved conversations when the recovery file is corrupt | Save a conversation, damage the separate autosave, and reopen the same app in Studio. The source and a disposable on-disk reproduction both showed that decoding aborted the entire load. Explicitly saved work became unavailable. | Studio moves the unreadable recovery file aside before opening the last saved conversations and reports the backup filename. The focused executable passed after the fix, including a byte-for-byte backup check and reopening a later edit. Regression cases also cover foreign app and unsupported-version draft envelopes. |
| **Medium.** A rejected batch loses the entire creation form | Submit a name of 201 characters. The desktop sheet's source dismissed immediately after starting asynchronous creation. In the focused reproduction, the real store then rejected the name and created no job. Other storage validation failures, such as a mismatched baseline, took the same path. | The form waits for the storage result. It keeps the entered settings and shows the error inline if rejected. The focused check used real production storage and confirmed a corrected retry saved one batch with the original timeout. Desktop UI regression authored. |
| **High.** Run reports can retain a release verdict from earlier evidence | Open **Release report**, then switch saved runs or change the selected assessment. The report was stored as Markdown in view state, even though the workspace retains the view identity and the release evaluator uses the active assessment, suite and approval. The retained verdict could disagree with the current evidence. | The report is bound to the selected run ID and recalculated from its current release evidence while visible. On both hosted runs, the desktop regression switched saved runs and confirmed that the displayed run ID changed. Same-run assessment refresh was source-traced. |
| **Medium.** Scheduling instructions imply an open desktop will run due jobs | Create a schedule and leave the desktop open. The Workers pane reads schedules and writes changes, but it never ticks them. Only explicit CLI/MCP ticks or polling workers advance a schedule. Operators following the incorrect guide can miss scheduled runs. | Updated the batch guide to explain starting a polling worker or explicitly ticking the schedule and running the created job. Confirmed current tick call sites in the CLI, native worker, and MCP. |

## Verification during the fix passes

- The original Siri store failed the damaged-autosave fixture. The updated store passed four cases with the real Siri document and recovery implementation, temporary files, and a stubbed telemetry interface. Checked malformed data, a draft for another app, an unsupported version, and a corrupt draft without an explicitly saved document. Each case preserved the exact original bytes, then saved and reopened a new edit.
- Baseline batch creation returned before the rejection and left storage empty. The updated store delivered the error to the caller, then saved and selected one corrected job. The probe compiled the actual batch sheet and store with the production storage package and used a stubbed evaluation configuration and telemetry interface.
- The native Xcode 27.3 build was stopped while compiling dependencies as free disk space fell to about 1 GiB. That attempt established no native runtime evidence. Later local and hosted builds are recorded below.

- `swiftc -frontend -parse` passed for all seven modified Swift files. `git diff --check` passed.
- `python3 script/docstring_coverage.py --minimum 85` reported 2,819 of 2,819 functions documented. `python3 script/changed_function_docs.py --base HEAD` reported 9 of 9 changed declarations documented. All 37 documentation-detector tests passed.
- `swift test --disable-sandbox --package-path Packages/ProductionEvals --scratch-path <temporary-build> -j 2` passed all 82 tests in 10 suites, including the 10,000-example pause/resume fixture and the schedule idempotency and pause fixture.
- Independent read-only code review found no remaining material defect in the patch. Independent coverage review checked the journey inventory and source evidence. The skill's source queue check passed.

## Hosted desktop verification

[PR #202](https://github.com/coryparrry/Intents/pull/202) submitted commit `ccb829638` to [GitHub CI](https://github.com/coryparrry/Intents/actions/runs/44538262126). The [hosted Xcode build](https://github.com/coryparrry/Intents/actions/runs/44538262126/job/135609930434) passed. The three desktop shards started from its retained test bundles.

- The [traces shard](https://github.com/coryparrry/Intents/actions/runs/44538262126/job/135611895233) ran 16 tests with zero failures. The saved-run switch regression passed. The hosted screenshot confirms the Release report action is reachable at minimum window width. [Trace results and screenshots](https://github.com/coryparrry/Intents/actions/runs/44538262126/artifacts/14537537541).

The first [suite-editor run](https://github.com/coryparrry/Intents/actions/runs/44538262126/job/135611895210)
passed 18 of 19 cases. The dataset regression stopped at the Version field.
The retained accessibility tree showed a separate visible Version caption and
an unnamed field, with the same problem on the dataset name and adjacent form
controls. Explicit labels identify the name, version, sampling, production-data,
and redaction controls. The regression now checks the accessible names and
continues through rejection, redaction confirmation and corrected import.
[First suite-editor results](https://github.com/coryparrry/Intents/actions/runs/44538262126/artifacts/14538037224).

The first [App Intents and review shard](https://github.com/coryparrry/Intents/actions/runs/44538262126/job/135611895170)
passed 22 of 23 cases, including batch creation and corrected retry. The Siri
recovery fixture showed the saved conversation and warning in the accessibility
tree. The check matched only the accessibility label, but SwiftUI exposed the
warning as a text value. The assertion now checks both properties for the same
warning text before verifying the saved conversation and original draft bytes.
[First App Intents and review results](https://github.com/coryparrry/Intents/actions/runs/44538262126/artifacts/14539107842).

The corrected candidate `cafba2ebf` passed the full local Xcode build and the
native unit suite recheck. [The second GitHub run](https://github.com/coryparrry/Intents/actions/runs/44542947775)
passed on that exact commit. All 58 desktop UI tests passed.

- The [second Xcode build](https://github.com/coryparrry/Intents/actions/runs/44542947775/job/135626394749)
  and [portable and native regression job](https://github.com/coryparrry/Intents/actions/runs/44542947775/job/135629079139) passed.
- The [second traces shard](https://github.com/coryparrry/Intents/actions/runs/44542947775/job/135629079227)
  passed all 16 tests, including the release report switching between saved runs.
- The [second suite-editor shard](https://github.com/coryparrry/Intents/actions/runs/44542947775/job/135629078965)
  passed all 19 tests. The dataset test covered accessible import controls, a
  late duplicate ID, retained version, fresh redaction confirmation and
  successful import of the corrected file. The inspected screenshot shows the
  error under the retained form and the disabled Import button before
  reconfirmation. [Suite-editor results and screenshot](https://github.com/coryparrry/Intents/actions/runs/44542947775/artifacts/14540468407).
- The [second App Intents and review shard](https://github.com/coryparrry/Intents/actions/runs/44542947775/job/135629078870)
  passed all 23 tests. The batch form retained its invalid input and advanced
  setting until the operator corrected the name. Siri Studio reopened the saved
  conversation, showed the recovery notice, kept the saved file's bytes and
  preserved the original corrupt draft. The inspected screenshot shows the
  recovery notice and original conversation in the editor.
  [App Intents and review results and screenshots](https://github.com/coryparrry/Intents/actions/runs/44542947775/artifacts/14541623208).
- GitHub reported the aggregate gate and all required checks green on
  `cafba2ebf`. All desktop UI execution took place on GitHub runners.
  The tests used synthetic app and data fixtures. Live Siri, external providers,
  and a full workspace restore remain outside the verified results.


The follow-up found a dataset import failure alongside batch creation. A JSONL
file can have three valid preview rows and a duplicate ID later in the file.
The real CLI rejected a synthetic file with that layout and published no
dataset. The desktop form previously dismissed before that validation finished.
It now keeps the selected file and metadata and shows the rejection inline.
If the file contains production data, a retry requires fresh confirmation of
redaction. The native store and desktop tests cover rejecting a late duplicate
and retrying with the corrected file and the same settings.

- The follow-up uses GitHub's Xcode 27 runners for all desktop UI execution. The PR runs the full native build, native unit tests and all three desktop UI shards.
- Added a Siri Studio desktop regression using an isolated synthetic app, a saved conversation, and a separately damaged autosave. It checks that the recovery message and saved text are visible and that both the original saved document and the preserved draft bytes match exactly.
- The batch regression submits a rejected form, checks its retained values, corrects the invalid input and confirms that the saved batch appears in Jobs. The release-report regression switches between two saved runs and checks the displayed evidence identifier.

### Pre-push coverage and independent checks

The complete candidate against `origin/main` selects full ordinary CI. The
router selects `FoundationEvalsTests`, the complete portable Swift set, the
production package and CLI qualification, and these desktop UI shards.

- **native-intents+review+runs** runs EvaluationReviewUITests, FoundationEvalsRunLifecycleUITests, MacIntentTestingUITests.
- **suite-editor** runs ChartHoverUITests, DocumentSuiteUITests, FoundationEvalsUITests, WorkspacePolishUITests.
- **traces** runs WorkflowTraceUITests.

The ordinary Python selection contains 29 modules. All 396 tests passed
through `script/ci_run_tests.py python`. Selected modules include test_changed_function_docs, test_ci_core_scheme, test_ci_failure_summary, test_ci_gate, test_ci_macos_signing, test_ci_native_cache, test_ci_native_routes, test_ci_native_tests, test_ci_production_evals, test_ci_route_outputs, test_ci_routes, test_ci_run_tests, test_ci_ui_display, test_ci_ui_xctestrun, test_ci_workflow, test_docstring_coverage, test_document_quality_report, test_document_semantic_report, test_local_app_build, test_package_installer_workflow, test_release_dispatch, test_release_notes, test_release_pr, test_release_validation, test_shared_app_sources, test_update_feed, test_update_homebrew, test_upload_posthog_symbols, test_wait_release_ci.
The macOS script selection passed all 13 tests in test_foundation_evals_cli, test_update_signature.

- `CI_TEST_SELECTION='["*"]' python3 script/ci_run_tests.py swift --scratch-path <portable-build>` passed 172 tests with the repository's manual-test exclusions.
- The previous 82 production package tests remain applicable. The package, tests and configuration inputs are unchanged. The current candidate's `swift build --product intents-evals` plus `script/test_production_evals.py` passed 89 CLI assertions.
- The pinned actionlint command, `shellcheck script/*.sh`, Python example compilation, and all website syntax/style and unit checks passed. The website ran 40 tests.
- The final `xcodebuild build-for-testing` passed with the full `FoundationEvals` scheme on Xcode 27.3. The first rebuild of the import regression exposed a Swift Testing macro type error. Capturing the task before using the assertion corrected it.
- The native `FoundationEvalsTests` suite passed 1,069 tests with zero failures and six existing opt-ins skipped. The Siri recovery and dataset retry cases passed. All desktop UI execution is reserved for GitHub.
- The docstring verifier reported full coverage and found documentation for all 14 changed declarations. Independent review caught the need to reset redaction confirmation after an import failure. The UI test now requires confirmation of the corrected file before it retries.

## Journey ledger

The initial source pass traced 37 journeys across 14 app surfaces. Each entry follows the action to stored state or handoff, including readback and failure handling. Three additional paths are traced in the coherence follow-up below. The hosted results above identify the tested commit and fixtures.

### Workspace and project management

- **Create, rename, and switch projects and suites.** The catalog remembers active project and suite. Loading the remembered suite restores its definition, recoverable draft and saved runs. Switching saves or preserves outgoing edits first and rolls back the visible selection if loading or publication fails. *Runtime.* Desktop flow unverified. [Entry](FoundationEvals/FoundationEvals/Views/WorkspaceManagerView.swift#L32) · [State](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L381) · [Save or handoff](FoundationEvals/FoundationEvals/Services/EvaluationWorkspacePersistence.swift#L167) · [Readback](FoundationEvals/FoundationEvals/Views/WorkspaceSidebar.swift#L118) · [Reopen](FoundationEvals/FoundationEvals/Services/EvaluationWorkspacePersistence.swift#L20) · [Failure](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L904)
- **Duplicate a project or suite.** Copies have new IDs in the catalog. Reopening a copied suite reloads its definition, matching draft, and copied attachments. Duplication stages files before adding the copy to the catalog and cleans up staged files on failure. Run history and approvals stay with the original. *Runtime.* Desktop flow unverified. [Entry](FoundationEvals/FoundationEvals/Views/WorkspaceManagerView.swift#L35) · [State](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L422) · [Save or handoff](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L5414) · [Readback](FoundationEvals/FoundationEvals/Views/WorkspaceSidebar.swift#L217) · [Reopen](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L970) · [Failure](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L430)
- **Archive and restore a project or suite.** Archive flags persist in the catalog. The archive list can restore child suites and projects on return. Archiving the selected suite chooses an active replacement. The last active suite cannot be archived. Restore clears the flag without rewriting suite contents. *Runtime.* Desktop flow unverified. [Entry](FoundationEvals/FoundationEvals/Views/WorkspaceManagerView.swift#L36) · [State](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L752) · [Save or handoff](FoundationEvals/FoundationEvals/Services/EvaluationWorkspacePersistence.swift#L167) · [Readback](FoundationEvals/FoundationEvals/Views/WorkspaceManagerView.swift#L83) · [Reopen](FoundationEvals/FoundationEvals/Services/EvaluationWorkspacePersistence.swift#L20) · [Failure](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L526)
- **Recover workspace data after relaunch or an older layout.** `Application Support/FoundationEvals` holds the catalog and `Projects/<project>/Suites/<suite>` definitions, attachments, state and history. Startup migrates older layout and loads revision-bound drafts, interrupted run data and local state. Review drafts, production data and Siri Studio have distinct storage owners and recovery paths below. Corrupt data is preserved where supported and failed preservation blocks replacement. The app has no workspace-wide backup/import button. Run and document-suite exports cover chosen evidence; connector and judge secrets live in the login Keychain and are outside those exports. *Runtime.* Desktop flow unverified. [Entry](FoundationEvals/FoundationEvals/FoundationEvalsApp.swift#L32) · [State](FoundationEvals/FoundationEvals/Services/EvaluationWorkspacePersistence.swift#L20) · [Save or handoff](FoundationEvals/FoundationEvals/Services/EvaluationWorkspacePersistence.swift#L271) · [Readback](FoundationEvals/FoundationEvals/Views/WorkspaceSidebar.swift#L118) · [Reopen](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L269) · [Failure](FoundationEvals/FoundationEvals/Services/EvaluationWorkspacePersistence.swift#L176)
- **Reset a suite or delete saved runs.** Reopening reads remaining files in Runs. Tombstoned records are not normal history and interrupted cleanup can be retried by ID. Confirmation precedes reset or removal. The combined reset and history deletion performs two mutations and reports partial failure; deleted evidence has no undo. *Runtime.* Desktop flow unverified. [Entry](FoundationEvals/FoundationEvals/Views/WorkspaceResetControl.swift#L25) · [State](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L3079) · [Save or handoff](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L2948) · [Readback](FoundationEvals/FoundationEvals/ContentView.swift#L121) · [Reopen](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L5522) · [Failure](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L2993)
- **Back up and restore the separate application stores.** The cold-copy procedure covers the workspace, production audit, Siri and Direct Action roots, externally referenced files and optional preferences. After restoring, reconnect Keychain-backed credentials and verify run and draft readback. Restoring a mixed snapshot is unsupported. Keep complete rollback directories and restore them together if readback fails. *Runtime.* Documented restore source-traced. No full native restore executed. [Entry](docs/wiki/Data-and-troubleshooting.md#L13) · [State](docs/wiki/Data-and-troubleshooting.md#L15) · [Save or handoff](docs/wiki/Data-and-troubleshooting.md#L17) · [Readback](docs/wiki/Data-and-troubleshooting.md#L38) · [Reopen](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L269) · [Failure](docs/wiki/Data-and-troubleshooting.md#L39)

### Suite Cases and document creation

- **Author and autosave cases.** Valid canonical edits and revision-bound incomplete drafts reload by stable case ID. Editing document-backed questions immediately invalidates old source review. The store flushes buffered prompts before switching or saving. Invalid drafts remain editable and run validation blocks incomplete inputs. *Runtime.* Desktop flow unverified. [Entry](FoundationEvals/FoundationEvals/Views/SuiteCasesView.swift#L128) · [State](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L3441) · [Save or handoff](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L3547) · [Readback](FoundationEvals/FoundationEvals/Views/SuiteCasesView.swift#L88) · [Reopen](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L970) · [Failure](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L3514)
- **Import CSV or JSONL cases.** Accepted rows enter the suite through the canonical case commit and appear when the suite reopens. Preview maps name, prompt, and expected values. Invalid rows block import. Only valid rows that exceed the remaining capacity can use acknowledged partial import or a new suite. *Runtime.* Desktop flow unverified. [Entry](FoundationEvals/FoundationEvals/Views/CaseImportView.swift#L27) · [State](FoundationEvals/FoundationEvals/Views/CaseImportView.swift#L217) · [Save or handoff](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L2794) · [Readback](FoundationEvals/FoundationEvals/Views/SuiteCasesView.swift#L88) · [Reopen](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L970) · [Failure](FoundationEvals/FoundationEvals/Views/CaseImportView.swift#L103)
- **Generate, review, and resume document-backed cases.** The per-project draft holds the extracted source, selected sections, candidates and completed attempts. Publishing writes a separate suite via createSuite with accepted cases. Cancel or retry preserves completed candidates and operator edits. Changed source evidence requires review again. An external reviewer requires explicit authorization for that judge. *Runtime.* Desktop flow unverified. Requires matching test app or service for a live trial. [Entry](FoundationEvals/FoundationEvals/Views/WorkspaceManagerView.swift#L142) · [State](FoundationEvals/FoundationEvals/Stores/EvaluationDocumentDraftController.swift#L101) · [Save or handoff](FoundationEvals/FoundationEvals/Stores/EvaluationDocumentDraftController.swift#L288) · [Readback](FoundationEvals/FoundationEvals/Views/DocumentSuiteView.swift#L138) · [Reopen](FoundationEvals/FoundationEvals/Stores/EvaluationDocumentDraftController.swift#L36) · [Failure](FoundationEvals/FoundationEvals/Stores/EvaluationDocumentDraftController.swift#L271)
- **Export and reimport a document suite.** The JSON file retains per-case quotes and source snapshots. Import persists a new editable draft that reloads by project. Network-bound options are reset, prior review is cleared and invalid/mixed or excessive archives surface errors. *Runtime.* Desktop flow unverified. [Entry](FoundationEvals/FoundationEvals/Views/DocumentSuiteExportButton.swift#L13) · [State](FoundationEvals/FoundationEvals/Services/EvaluationDocumentArchive.swift#L25) · [Save or handoff](FoundationEvals/FoundationEvals/Stores/EvaluationDocumentDraftController.swift#L84) · [Readback](FoundationEvals/FoundationEvals/Views/DocumentSuiteView.swift#L138) · [Reopen](FoundationEvals/FoundationEvals/Stores/EvaluationDocumentDraftController.swift#L36) · [Failure](FoundationEvals/FoundationEvals/Services/EvaluationDocumentArchive.swift#L15)

### Suite Setup and model routing

- **Configure prompts, references, conversations and scoring.** Case conversation settings, rubric, repeats, assertions, references and text/image attachment metadata are read back from the suite and local attachment store. File work is bounded and admission is gated while it is running. Removing an attachment uses its suite revision and edits flow through autosave. *Runtime.* Desktop flow unverified. [Entry](FoundationEvals/FoundationEvals/Views/SuiteEditorView.swift#L802) · [State](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L3268) · [Save or handoff](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L4529) · [Readback](FoundationEvals/FoundationEvals/Views/SuiteEditorView.swift#L836) · [Reopen](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L970) · [Failure](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L3401)
- **Select a subject model and configure tools, output and profiling.** The suite persists model settings, tools, output schema and profiling options. The runtime resolves on-device, private cloud, Core AI or custom HTTP configuration again when admitted. Core AI resource changes invalidate a loaded model. Provider readiness and token/context checks stop execution early. External transport and profiling require compatible resources. *Runtime.* Desktop flow unverified. Requires matching test app or service for a live trial. [Entry](FoundationEvals/FoundationEvals/Views/ModelControlsSection.swift#L73) · [State](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L2700) · [Save or handoff](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L4599) · [Readback](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L2602) · [Reopen](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L970) · [Failure](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L3490)

### Run and result history

- **Run locally, cancel, retry saving, and reopen the result.** The active checkpoint is published into history with the run's identity. Inspect the saved report, trace or performance after relaunch. Cancel preserves available partial evidence. Failed publication blocks further work until retry or explicit preservation of unreadable recovery bytes. *Runtime.* Desktop flow unverified. Requires matching test app or service for a live trial. [Entry](FoundationEvals/FoundationEvals/Views/SuiteRunControls.swift#L229) · [State](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L3636) · [Save or handoff](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L4712) · [Readback](FoundationEvals/FoundationEvals/ContentView.swift#L121) · [Reopen](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L5665) · [Failure](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L3610)
- **Inspect traces, compare runs, and export evidence.** Run comparison and trace inspector rebuild from saved run data. Trace selection and comparison UI state are session choices. A JSON export is a standalone artifact. The comparison is constrained by earlier runs of the same suite and rejects incompatible or incomplete evidence. *Runtime.* Desktop flow unverified. [Entry](FoundationEvals/FoundationEvals/Views/SuiteResultsView.swift#L25) · [State](FoundationEvals/FoundationEvals/Views/RunDetailView.swift#L89) · [Save or handoff](FoundationEvals/FoundationEvals/Views/RunDetailView.swift#L115) · [Readback](FoundationEvals/FoundationEvals/Views/WorkflowTraceView.swift#L279) · [Reopen](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L5522) · [Failure](plugins/apple-foundation-evals/native/AppEngine/EvaluationDevelopmentAnalysis.swift#L150)
- **Reassess and correct judgments, then check release requirements.** The selected assessment lives with the run, and approval is stored by run/assessment in suite-local state. The report can be regenerated against current settings and persisted evidence. Reassessment leaves the original response evidence intact. The evaluator checks coverage, provenance and current suite revision before a pass. The report was corrected to follow the current run and assessment. *Runtime.* Hosted fixtures verified release-report run switching. Live reassessment and same-run assessment refresh were source-traced. [Entry](FoundationEvals/FoundationEvals/Views/RunWorkflowPanel.swift#L73) · [State](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L1264) · [Save or handoff](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L1461) · [Readback](FoundationEvals/FoundationEvals/Views/RunWorkflowPanel.swift#L92) · [Reopen](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L970) · [Failure](plugins/apple-foundation-evals/native/AppEngine/EvaluationDevelopmentAnalysis.swift#L202)

### Review, judge checks and instruction experiments

- **Review evidence, keep notes, and create a regression.** Review drafts are sample-keyed. Saved annotations rejoin immutable responses using source digests and surface in Samples and Patterns. The reviewer can reveal or hide the AI decision, accept or reject a suggestion, and create a regression only with a verified reference answer. *Runtime.* Desktop flow unverified. [Entry](FoundationEvals/FoundationEvals/Views/ReviewSampleEditor.swift#L85) · [State](FoundationEvals/FoundationEvals/Stores/EvaluationStore+Review.swift#L10) · [Save or handoff](FoundationEvals/FoundationEvals/Stores/EvaluationReviewDraftStore.swift#L54) · [Readback](FoundationEvals/FoundationEvals/Views/SuiteReviewView.swift#L74) · [Reopen](FoundationEvals/FoundationEvals/Stores/EvaluationReviewDraftStore.swift#L29) · [Failure](FoundationEvals/FoundationEvals/Views/ReviewSampleEditor.swift#L213)
- **Partition examples and test a judge.** Development and Held-out examples persist with suite-local state and can be used for a later rerun. Latest judge validation output is session state. Unqualified evidence blocks promotion or scoring. Partition changes and removals are saved and reports retain evidence availability metadata. *Runtime.* Desktop flow unverified. Requires matching test app or service for a live trial. [Entry](FoundationEvals/FoundationEvals/Views/ReviewJudgeChecksPane.swift#L20) · [State](FoundationEvals/FoundationEvals/Stores/EvaluationStore+Review.swift#L61) · [Save or handoff](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L5124) · [Readback](FoundationEvals/FoundationEvals/Views/ReviewJudgeChecksPane.swift#L31) · [Reopen](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L970) · [Failure](FoundationEvals/FoundationEvals/Stores/EvaluationStore+Review.swift#L102)
- **Run experiments and compare proposed instructions.** Manual experiments, reviewed decisions, checkpoints and retained comparison runs reload from the suite and its history. Cancel comparison preserves completed evidence. Applying is explicit and rejects changes when the suite or held-out evidence has become stale. *Runtime.* Desktop flow unverified. Requires matching test app or service for a live trial. [Entry](FoundationEvals/FoundationEvals/Views/SuiteExperimentsView.swift#L22) · [State](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L1665) · [Save or handoff](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L1768) · [Readback](FoundationEvals/FoundationEvals/Views/PromptImprovementView.swift#L42) · [Reopen](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L970) · [Failure](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L1787)

### Paired developer app runs

- **Pair, run, cancel, and forget a developer runner.** Trust receipts and the desktop ID reload from DeveloperRunners. The selected device must reconnect and advertise its registered feature. Completed feature evidence is saved in normal run history. Wrong/mismatched trust, disconnected runners and timeout are surfaced. Cancel addresses the current runner request and Forget pairing deletes the trust receipt. No fallback to a local model. *Runtime.* Desktop flow unverified. Requires matching test app or service for a live trial. [Entry](FoundationEvals/FoundationEvals/Views/DeveloperDevicesView.swift#L115) · [State](FoundationEvals/FoundationEvals/Stores/DeveloperRunnerStore.swift#L116) · [Save or handoff](Sources/FoundationEvalsDeveloper/DeveloperRunnerClient.swift#L941) · [Readback](FoundationEvals/FoundationEvals/ContentView.swift#L121) · [Reopen](FoundationEvals/FoundationEvals/Stores/DeveloperRunnerStore.swift#L40) · [Failure](FoundationEvals/FoundationEvals/Stores/DeveloperRunnerStore.swift#L220)

### Batch runs

- **Import, freeze, and inspect immutable datasets.** Dataset revision and manifest load together from production storage. Imported captures can start a captured-output review without rerunning the subject. JSONL parsing, review of redaction and content validation precede publication. Document cases cannot be flattened into a batch dataset. *Runtime.* Hosted suite-editor fixtures verified late duplicate handling, redaction reconfirmation and corrected import. Freezing a live suite was source-traced. [Entry](FoundationEvals/FoundationEvals/Views/ProductionWorkspaceView.swift#L128) · [State](FoundationEvals/FoundationEvals/Stores/ProductionWorkspaceStore.swift#L269) · [Save or handoff](Packages/ProductionEvals/Sources/ProductionEvals/Services/ProductionDatasets.swift#L87) · [Readback](FoundationEvals/FoundationEvals/Views/ProductionWorkspaceView.swift#L143) · [Reopen](FoundationEvals/FoundationEvals/Stores/ProductionWorkspaceStore.swift#L117) · [Failure](FoundationEvals/FoundationEvals/Views/ProductionWorkspaceSheets.swift#L72)
- **Create and retry batch setup.** The job freezes a dataset revision, repetitions, targets, scoring and policy. It appears by its persisted ID after successful creation. Configuration and storage rejection show inline and preserve the form, including advanced values. Successful creation dismisses the form and opens Jobs with the durable job selected. *Runtime.* Hosted fixtures verified retaining settings and saving a corrected batch from Jobs. The new handoff from Datasets was checked separately in this follow-up. [Entry](FoundationEvals/FoundationEvals/Views/ProductionWorkspaceSheets.swift#L236) · [State](FoundationEvals/FoundationEvals/Stores/ProductionWorkspaceStore.swift#L308) · [Save or handoff](Packages/ProductionEvals/Sources/ProductionEvals/Services/ProductionJobs.swift#L57) · [Readback](FoundationEvals/FoundationEvals/Views/ProductionWorkspaceView.swift#L182) · [Reopen](FoundationEvals/FoundationEvals/Stores/ProductionWorkspaceStore.swift#L117) · [Failure](FoundationEvals/FoundationEvals/Views/ProductionWorkspaceSheets.swift#L252)
- **Run, pause, resume or cancel a batch.** Jobs reread immutable configuration and saved chunks, leases and controls. The desktop UI refreshes pending or completed evidence from the same store used by workers. Pause persists before interrupting local work. Resume requires compatible worker admission. Cancellation is permanent for that job. Interrupted side-effectful work is recorded for reconciliation. *Runtime.* Desktop flow unverified. Requires matching test app or service for a live trial. [Entry](FoundationEvals/FoundationEvals/Views/ProductionWorkspaceView.swift#L193) · [State](FoundationEvals/FoundationEvals/Stores/ProductionWorkspaceStore.swift#L391) · [Save or handoff](Packages/ProductionEvals/Sources/ProductionEvals/Services/ProductionJobs.swift#L104) · [Readback](FoundationEvals/FoundationEvals/Views/ProductionWorkspaceView.swift#L73) · [Reopen](Packages/ProductionEvals/Sources/ProductionEvals/Services/ProductionJobs.swift#L65) · [Failure](FoundationEvals/FoundationEvals/Stores/ProductionWorkspaceStore.swift#L360)
- **Review or reconcile results, approve baseline and export.** Operator drafts reload separately from the audit. The report rereads the frozen job, reviews, and baseline bound to current evidence. Export publishes a separate evidence folder. Disagreements remain unresolved until an assigned reviewer acts. Edits, pause/cancel or changed evidence invalidate stale approvals instead of advancing the gate. *Runtime.* Desktop flow unverified. [Entry](FoundationEvals/FoundationEvals/Views/ProductionResultDetailView.swift#L55) · [State](FoundationEvals/FoundationEvals/Stores/ProductionWorkspaceStore.swift#L475) · [Save or handoff](Packages/ProductionEvals/Sources/ProductionEvals/Services/ProductionBaselineApproval.swift#L43) · [Readback](FoundationEvals/FoundationEvals/Views/ProductionReportPane.swift#L38) · [Reopen](Packages/ProductionEvals/Sources/ProductionEvals/Services/ProductionAnalysis.swift#L71) · [Failure](Packages/ProductionEvals/Sources/ProductionEvals/Services/ProductionAnalysis.swift#L170)
- **Schedule jobs and inspect worker provenance.** Schedule templates and worker registrations reload from production storage. Polling advances due slots using deterministic job IDs. Pause and resume use the expected schedule revision. The UI stores a schedule and a worker or polling command is required to run it. *Runtime.* Desktop flow unverified. Requires matching test app or service for a live trial. [Entry](FoundationEvals/FoundationEvals/Views/ProductionWorkspaceView.swift#L260) · [State](Packages/ProductionEvals/Sources/ProductionEvals/Services/ProductionSchedules.swift#L44) · [Save or handoff](Packages/ProductionEvals/Sources/ProductionEvals/Services/ProductionSchedules.swift#L32) · [Readback](FoundationEvals/FoundationEvals/Views/ProductionWorkspaceView.swift#L245) · [Reopen](FoundationEvals/FoundationEvals/Stores/ProductionWorkspaceStore.swift#L117) · [Failure](FoundationEvals/FoundationEvals/Stores/ProductionWorkspaceStore.swift#L350)

### App Intents and Siri Studio

- **Inspect a Mac app and run a direct App Intent test.** App Intents keeps its mode preference. A new session requires selecting the app again. Its local XCTest result bundle/log remain on disk. Catalog loads can be cancelled, cannot publish a superseded selection and verify app identity. Editing test inputs clears its old verdict. Native app execution needs matching signing and registration. *Runtime.* Desktop flow unverified. Requires matching test app or service for a live trial. [Entry](FoundationEvals/FoundationEvals/Views/MacIntentTestingView.swift#L60) · [State](FoundationEvals/FoundationEvals/Stores/MacIntentTestingStore.swift#L145) · [Save or handoff](Sources/MacIntentTesting/MacIntentRunner.swift#L122) · [Readback](FoundationEvals/FoundationEvals/Views/MacIntentTestingView.swift#L142) · [Failure](FoundationEvals/FoundationEvals/Stores/MacIntentTestingStore.swift#L48)
- **Author, save, reopen or recover Siri conversations.** Studio restores the saved per-bundle document and a newer recoverable draft after selecting the same app again. Explicit export creates a shareable scenario JSON file. App switches save outgoing work. Malformed or incompatible recovery is preserved before opening saved work. An unreadable saved canonical file remains protected and is reported. *Runtime.* Hosted fixtures verified reopening after a corrupt draft and retaining the original bytes. [Entry](FoundationEvals/FoundationEvals/Views/SiriStudio/SiriStudioView.swift#L300) · [State](FoundationEvals/FoundationEvals/Stores/SiriStudioStore.swift#L145) · [Save or handoff](FoundationEvals/FoundationEvals/Stores/SiriStudioStore.swift#L321) · [Readback](FoundationEvals/FoundationEvals/Views/SiriStudio/SiriStudioView.swift#L272) · [Reopen](FoundationEvals/FoundationEvals/Stores/SiriStudioStore.swift#L78) · [Failure](FoundationEvals/FoundationEvals/Stores/SiriStudioStore.swift#L362)
- **Run Siri or import and inspect saved result evidence.** Siri evidence has a unique run folder. Open saved run reads its authored snapshot and result reports without relaunching Siri. Open either verdict-only or explicit transcript export. Siri requires a compatible macOS/Xcode development identity. Native operation owns cancellation. Edited conversations display stale evidence and result import enforces result integrity. *Runtime.* Desktop flow unverified. Requires matching test app or service for a live trial. [Entry](FoundationEvals/FoundationEvals/Views/SiriStudio/SiriStudioView.swift#L390) · [State](FoundationEvals/FoundationEvals/Stores/SiriStudioStore.swift#L218) · [Save or handoff](Sources/MacIntentTesting/SiriStudio/SiriStudioRunner.swift#L160) · [Readback](FoundationEvals/FoundationEvals/Views/SiriStudio/SiriStudioView.swift#L363) · [Reopen](FoundationEvals/FoundationEvals/Stores/SiriStudioStore.swift#L231) · [Failure](FoundationEvals/FoundationEvals/Stores/SiriStudioStore.swift#L246)
- **Detect and confirm Siri prerequisites.** Setup restores no signing secret or prior confirmation. Choose the installed registered app and inspect the selected Xcode and matching certificate again. App changes invalidate an in-flight probe. Edited settings are never overwritten, and a report for different settings blocks Run until rechecked. Confirmation of Siri downloads comes from the user. XcodeGen installation and app registration are explicit handoffs. *Runtime.* Desktop flow unverified. Requires matching test app or service for a live trial. [Entry](FoundationEvals/FoundationEvals/Views/SiriStudio/SiriStudioSetupView.swift#L74) · [State](FoundationEvals/FoundationEvals/Stores/MacIntentTestingStore.swift#L107) · [Save or handoff](FoundationEvals/FoundationEvals/Stores/SiriStudioSetupStore.swift#L48) · [Readback](FoundationEvals/FoundationEvals/Views/SiriStudio/SiriStudioSetupView.swift#L30) · [Failure](FoundationEvals/FoundationEvals/Stores/SiriStudioSetupStore.swift#L75)

### MCP Connector and workspace handoff

- **Connect or remove Codex and inspect status.** Managed local configuration and Keychain credential feed startup. Settings refreshes actual installation and connection state. Failure reports distinguish installed configuration from server startup. Remove stops the service and removes the managed credential; manual configuration remains an explicit action. *Runtime.* Desktop flow unverified. Requires matching test app or service for a live trial. [Entry](FoundationEvals/FoundationEvals/Views/MCPSettingsView.swift#L41) · [State](FoundationEvals/FoundationEvals/MCP/Installer/MCPSettingsController.swift#L158) · [Save or handoff](FoundationEvals/FoundationEvals/MCP/Installer/MCPSettingsController.swift#L324) · [Readback](FoundationEvals/FoundationEvals/Views/MCPSettingsView.swift#L49) · [Reopen](FoundationEvals/FoundationEvals/FoundationEvalsApp.swift#L159) · [Failure](FoundationEvals/FoundationEvals/MCP/Installer/MCPSettingsController.swift#L200)
- **Use the connector to edit the shared workspace or link repository definitions.** The connector and desktop share a store. A linked definition loads from the linked Git root under its revision and restores local-only state from the workspace. Repository import checks suite identity and refuses conflicting local changes. The MCP action checks revisions and destructive confirmation or safe retry where applicable. *Runtime.* Desktop flow unverified. Requires matching test app or service for a live trial. [Entry](FoundationEvals/FoundationEvals/Services/MCPWorkspaceControl.swift#L221) · [State](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L2467) · [Save or handoff](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L5342) · [Readback](FoundationEvals/FoundationEvals/Views/WorkspaceSidebar.swift#L217) · [Reopen](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L970) · [Failure](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L2539)

### Judge connections and privacy settings

- **Save, verify, replace and remove an external judge.** App storage contains connection metadata. A credential is stored separately and resolves only for its saved connection provider and exact endpoint. Changing provider/endpoint requires a replacement credential. Failed writes preserve existing state. External sample disclosure is checked independently of connection reachability. *Runtime.* Desktop flow unverified. Requires matching test app or service for a live trial. [Entry](FoundationEvals/FoundationEvals/Views/JudgeConnectionsSettingsView.swift#L134) · [State](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L1045) · [Save or handoff](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L5301) · [Readback](FoundationEvals/FoundationEvals/Views/JudgeConnectionsSettingsView.swift#L132) · [Reopen](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L291) · [Failure](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L1178)
- **Change sharing consent and inspect diagnostic status.** Separate telemetry and diagnostic choices reload from defaults. Internal diagnostics keep fixed categories and session-local records. Changing consent rotates the epoch, stops/discards pending delivery and rejects older callbacks. Debug and isolated launches do not send production telemetry. *Runtime.* Desktop flow unverified. Requires matching test app or service for a live trial. [Entry](FoundationEvals/FoundationEvals/Views/TelemetrySettingsView.swift#L12) · [State](FoundationEvals/FoundationEvals/Services/TelemetryController.swift#L121) · [Save or handoff](FoundationEvals/FoundationEvals/Services/TelemetryController.swift#L116) · [Readback](FoundationEvals/FoundationEvals/Views/TelemetrySettingsView.swift#L33) · [Reopen](FoundationEvals/FoundationEvals/Services/TelemetryController.swift#L103) · [Failure](FoundationEvals/FoundationEvals/Services/TelemetryController.swift#L139)
- **Copy a local diagnostic report.** Recent local diagnostic events accumulate afresh in each app session. The user may copy them with optional sharing disabled. The report is generated from app-defined operational facts and fixed categories. Copying places text on the clipboard and does not submit it to telemetry. *Runtime.* Desktop flow unverified. [Entry](FoundationEvals/FoundationEvals/Views/TelemetrySettingsView.swift#L46) · [State](FoundationEvals/FoundationEvals/Services/TelemetryController.swift#L303) · [Save or handoff](FoundationEvals/FoundationEvals/Views/TelemetrySettingsView.swift#L48) · [Readback](FoundationEvals/FoundationEvals/Views/TelemetrySettingsView.swift#L49) · [Failure](FoundationEvals/FoundationEvals/Views/TelemetrySettingsView.swift#L53)

### App menu updater

- **Request an app update.** Release startup delegates update check state and prompts to Sparkle. Debug builds intentionally omit the menu control. The control is gated by Sparkle readiness. Published feed, installer and signed update behavior require a release build and were outside this source patch. *Runtime.* Release-only Sparkle workflow unverified. [Entry](FoundationEvals/FoundationEvals/FoundationEvalsApp.swift#L274) · [State](FoundationEvals/FoundationEvals/FoundationEvalsApp.swift#L16) · [Save or handoff](FoundationEvals/FoundationEvals/FoundationEvalsApp.swift#L274) · [Readback](FoundationEvals/FoundationEvals/FoundationEvalsApp.swift#L276) · [Reopen](FoundationEvals/FoundationEvals/FoundationEvalsApp.swift#L17) · [Failure](FoundationEvals/FoundationEvals/FoundationEvalsApp.swift#L275)

### Model evaluations overview

- **Check project readiness and open the relevant run.** Overview reloads every active suite in the selected project. Saved runs, compatible drafts, baseline state and repository revisions feed readiness and recent history. Needs attention and search filter visible summaries. The loader flags missing or changed evidence and excludes uncommitted pending runs. Opening a recent run first activates its owning suite. *Runtime.* Hosted fixtures verified the Overview timeline and expansion of recent runs. Repository-change cases are source and native unit evidence. [Entry](FoundationEvals/FoundationEvals/Views/WorkspaceOverviewView.swift#L88) · [State](FoundationEvals/FoundationEvals/Views/WorkspaceOverviewView.swift#L96) · [Save or handoff](FoundationEvals/FoundationEvals/Services/WorkspaceOverviewLoader.swift#L30) · [Readback](FoundationEvals/FoundationEvals/Views/WorkspaceOverviewView.swift#L73) · [Reopen](FoundationEvals/FoundationEvals/Services/WorkspaceOverviewLoader.swift#L6) · [Failure](FoundationEvals/FoundationEvals/Views/WorkspaceOverviewView.swift#L175)

### Traces sidebar

- **Find a saved trace by case, suite or version.** The index is scoped to the selected suite and reads saved runs. Opening one shows its report and Workflow trace tab. Trace filter and span selection are transient. Unmatched searches and missing timelines are surfaced, and an empty index links back to Evaluations. *Runtime.* Hosted fixtures verified navigation to saved evidence and trace inspection. The full combination of search inputs was source-traced. [Entry](FoundationEvals/FoundationEvals/Views/WorkspaceTracesView.swift#L32) · [State](FoundationEvals/FoundationEvals/Views/WorkspaceTracesView.swift#L40) · [Save or handoff](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L4680) · [Readback](FoundationEvals/FoundationEvals/Views/RunDetailView.swift#L77) · [Reopen](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L5522) · [Failure](FoundationEvals/FoundationEvals/Views/WorkspaceTracesView.swift#L45)

### App menu and desktop distribution

- **Use the Evaluation menu to navigate and control a run.** Menu navigation and shortcuts use the shared store. The menu writes cases and references through the same suite persistence used by the editor. Runs saved from the menu appear in regular history. The same admission rules apply for starting and cancelling a run. Commands that only navigate do not alter saved evidence. *Runtime.* Desktop flow unverified. [Entry](FoundationEvals/FoundationEvals/FoundationEvalsApp.swift#L186) · [State](FoundationEvals/FoundationEvals/FoundationEvalsApp.swift#L204) · [Save or handoff](FoundationEvals/FoundationEvals/Views/SuiteRunControls.swift#L229) · [Readback](FoundationEvals/FoundationEvals/ContentView.swift#L105) · [Reopen](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L970) · [Failure](FoundationEvals/FoundationEvals/FoundationEvalsApp.swift#L227)


## Whole-app coherence follow-up

The principal workflow holds together. Create a suite, add cases and choose
scoring and a destination, run it, and inspect the saved report. Then use
**Review** to label a response or make a regression case, **Compare runs** to
evaluate a change, and **Release report** to apply release requirements. The
suite and run history give this workflow a clear place to resume.

| Starting task | Expected result and next step | Source check |
| --- | --- | --- |
| Create or return to a suite | A project owns the suite, its draft and its saved runs. **Overview** flags changed definitions. An old run is still readable. The first run guide leads through Cases, Setup and the destination control. | [First run](docs/wiki/Getting-started.md#L27) · [Overview](FoundationEvals/FoundationEvals/Models/WorkspacePresentation.swift#L117) · [Restore](docs/wiki/Data-and-troubleshooting.md#L13) |
| Run and understand an evaluation | The selected destination is explicit. A disconnected selected app runner blocks the run. A saved response gives the operator a score, its supporting evidence and a trace when available. Human reviews and release approvals are separate actions. | [Destination](FoundationEvals/FoundationEvals/Views/SuiteRunControls.swift#L229) · [Results](docs/wiki/Runs-and-results.md#L22) · [Human review](docs/wiki/Review-and-judge-checks.md#L13) |
| Expand a suite into a batch or review captured data | The job freezes dataset and execution settings. **Jobs** owns start and resume. **Results** shows saved responses and operator review. **Reports** provides the batch's release evidence. | [Batch panes](FoundationEvals/FoundationEvals/Views/ProductionWorkspaceView.swift#L4) · [Batch and capture guide](docs/wiki/Production-batches.md#L7) |
| Test an action in a built app or check a Siri conversation | **Direct Action** tests the callback with supplied inputs. **Siri Studio** runs authored conversation checks against the selected development build. Reopening saved results reads their recorded evidence without invoking Siri. | [Direct Action](docs/wiki/Mac-App-Intent-tests.md) · [Siri setup](docs/wiki/Siri-Studio.md#L6) · [Open saved result](FoundationEvals/FoundationEvals/Stores/SiriStudioStore.swift#L231) |
| Share work, recover it, or hand it to a worker or agent | Exports and MCP expose specific evidence, and workers have their own execution and scheduling controls. The cold-copy guide identifies the stores and credentials that are needed to recover a workspace. | [MCP](docs/wiki/Codex-and-MCP.md) · [Worker scheduling](docs/wiki/Production-batches.md#L46) · [Backup and restore](docs/wiki/Data-and-troubleshooting.md#L13) |

### Confirmed disconnects corrected in the worktree

| Problem and trigger | User impact and correction |
| --- | --- |
| **Medium.** A saved Siri pass appears current for a rebuilt app. Select a different build with the same bundle ID, then open a saved passing run without changing the conversation or launch arguments. The selected catalog and the saved run have different hashes, but the former label only checked the conversation and arguments. | The conversation list and Results now show **Previous app build** alongside the original verdict. A matching conversation with no confirmed build identity shows **App build unverified**. Reopening, inspecting, and exporting the original evidence still work. Intents compares the catalog captured at selection, so a rebuild in place must be reselected. [Run snapshot](Sources/MacIntentTesting/SiriStudio/SiriStudioRunner.swift#L153) · [Verdict](FoundationEvals/FoundationEvals/Stores/SiriStudioStore.swift#L245) · [Regression](FoundationEvals/FoundationEvalsTests/SiriStudioStoreTests.swift#L218) |
| **Medium.** Creating a batch from **Datasets** left the user looking at the dataset after success. The selected job ID had changed, but the pane stayed on Datasets and the run controls live in Jobs. | Once storage accepts the batch, Intents opens **Jobs** with the saved job selected. A rejected batch stays on the submitting form with its entries. The batch guide now also uses the actual **Results** tab name and explains the start step after **Review captured outputs**. [Dataset entry](FoundationEvals/FoundationEvals/Views/ProductionWorkspaceView.swift#L152) · [Durable handoff](FoundationEvals/FoundationEvals/Stores/ProductionWorkspaceStore.swift#L320) · [Regression](FoundationEvals/FoundationEvalsTests/ProductionWorkspaceStoreTests.swift#L9) |
| **Medium.** Finishing **Improve instructions** could replace the suite's case verdicts with a partial trial. Save an ordinary passing suite run and then save newer Practice or Final check trial records. **Cases** used whichever record was newest, even for a trial that omitted that case. **Overview** and the default release check excluded those trial records. | **Cases** now reads the same run as the default release check. Partial trials remain in the run history for comparison and trace inspection. The regression covers saving the trials and reopening the suite. The guide has one correct route to **Improve instructions**. [Case readback](FoundationEvals/FoundationEvals/Views/SuiteCasesView.swift#L16) · [Run selection](FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift#L1915) · [Regression](FoundationEvals/FoundationEvalsTests/EvaluationPromptImprovementTests.swift#L314) |

An independent source audit cross-checked the ledger against actual entry
points. An independent diff review checked the three code changes and their
regression fixtures. The source queue checker passed with 40 journeys across
14 app surfaces.

### Follow-up verification

- `xcodebuild build-for-testing -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals -configuration Debug -destination 'platform=macOS'` passed on Xcode 27.3. The build used isolated DerivedData, ad-hoc signing, two build jobs, and disabled indexing. It compiled both test bundles.
- A command-line Swift Testing runner linked the Xcode-built app library and native test objects. The filtered run passed the three affected tests. The Siri test passed all three startup-argument cases, including a different build, a matching build, and missing build evidence. The batch test used real temporary storage and checked both rejected and corrected writes. The Cases test checked the saved regular run after later trials and after reopening. The runner did not launch Intents.
- Swift parsing, `git diff --check`, and documentation checks passed. Coverage was 2,820 of 2,820 declarations tracked by the repository detector and 8 of 8 changed function declarations.
- The 58 GitHub desktop passes above apply to `cafba2ebf`. The follow-up changes are local to the worktree. Their rendered desktop flows remain unverified. No desktop automation ran on this Mac.

## First-use pass

The initial screen asked users to understand cases, scoring, and review before
they had seen a simple check. The seeded example used an AI rubric with three
criteria. A person learning the app had to understand an AI judgment before
they could tell what a basic pass meant.

| Where the user got stuck | What changed |
| --- | --- |
| The Overview gave several abstract steps, followed by a button that opened the first listed suite even when the user was working in another. | **Create example suite** creates a separate editable suite and opens its one case. The user can see the prompt and the expected answer, `Paris`. A deterministic exact-text check explains the verdict. Running is explicit. **Open [suite name]** returns to the selected suite. [Overview actions](FoundationEvals/FoundationEvals/Views/WorkspaceOverviewView.swift#L55) · [Example definition](FoundationEvals/FoundationEvals/Services/EvaluationStarterPacks.swift#L44) |
| A new blank suite said to select a test case when there were no cases. A longer reason why Run was disabled was replaced with **Can't run**. | The blank case editor has an **Add a case** action and explains what a case contains. The suite header shows the full reason Run is blocked. When expected text is missing, it names the scoring rule and asks for an expected answer. [Blank case editor](FoundationEvals/FoundationEvals/Views/SuiteCasesView.swift#L55) · [Run reason](FoundationEvals/FoundationEvals/Views/SuiteEditorView.swift#L438) |
| **Evaluations** opened the human review page. An empty **Traces** index sent users there to start a run. | **Review outputs** says what the sidebar destination opens. The empty trace screen has an **Open suite** button that leads to the runnable case editor. [Sidebar](FoundationEvals/FoundationEvals/Views/WorkspaceSidebar.swift#L94) · [Traces action](FoundationEvals/FoundationEvals/Views/WorkspaceTracesView.swift#L27) |

The first-run guide now starts with the same example and explains how to read
the saved verdict. The example uses the existing suite write and reopen paths
and an ordinary evaluation run. The original suite stays available. Paired
devices, service credentials, and developer signing still have their own setup.
[First-run guide](docs/wiki/Getting-started.md#L28) · [Save and score regression](FoundationEvals/FoundationEvalsTests/EvaluationWorkspaceCreationTests.swift#L8)

### First-use verification

- The full `FoundationEvals` Xcode 27.3 build compiled the app and both test bundles. The command and signing setup match the follow-up build above.
- Nine native regression tests passed in a command-line runner linked to the Xcode build. These include saving the example, reopening it without a run, showing an actionable message when its expected answer is missing, then saving a pass and a fail with an explanation. The original suite remained unchanged.
- Independent review caught wording that promised a verdict in Collect only mode. The shared empty response panel now promises only a response. The updated example still explains its exact-text verdict.
- The source queue passed with 43 journeys across the same 14 app surfaces. Swift parsing, diff checks, local document links, and documentation checks passed. All 15 changed function declarations have comments as tracked by the repository detector.
- The Overview and Traces regressions were compiled for future hosted execution. They were not run on the desktop. The changes remain in the review worktree.

## Hosted first-result follow-up

A report for one short text check used to put its verdict above a results
table. The expected answer, response, and explanation were farther down in
the detail pane. The report now shows those three facts together at the top
for a completed text-only check. Field checks and runs with execution issues
keep their full evidence view so a partial explanation cannot be mistaken
for the cause of the verdict. [Report summary](FoundationEvals/FoundationEvals/Views/RunReportSummary.swift#L32)

The GitHub desktop regression opens a disposable workspace, creates the
example from Overview, reads its expected answer, and runs it through the
ordinary evaluation path. A loopback fixture supplies `Paris` because the
hosted runner does not supply Apple Intelligence. The test requires the
saved report's verdict, expected text, response, and exact-match explanation
to fit in the visible window. It saves a screenshot for inspection.
[First-result UI regression](FoundationEvals/FoundationEvalsUITests/FoundationEvalsRunLifecycleUITests.swift#L77)

The complete PR diff selects all ordinary CI, including three desktop
shards. The first-use tests are in **native-intents+review+runs**. The user
specified GitHub runners for all desktop tests. Portable Swift and
production checks retain their inputs from the previous passing candidate
`cafba2ebf` and will run again in hosted CI.

Pre-push checks passed on the full candidate. Xcode 27.3 built the app and
both test bundles. The headless runner passed ten tests, including the first
check and the guard against presenting a text-only explanation for a field
or execution failure. The routed Python checks passed 396 tests and the
macOS script checks passed 13. Actionlint, ShellCheck, example syntax,
website checks and 40 website tests passed. The documentation detector
reported 34 of 34 changed functions documented. The proposed PR body passed
release-note validation with 11 entries.

## Product assessment and evidence limits

Intents gives developers a reason to return when changing a prompt, model, tool,
or app feature. A saved suite reruns the same cases, and the trace and review views
show which requests, outputs and judgments drove the result. The biggest trust
risk is using a clear-looking verdict after selected evidence changes. The
result must say which cases, assessment, run and app build it describes.
Batch jobs and App Intents have different prerequisites, but both fit the
product because they answer a distinct question and save the evidence needed to
return to it. A developer can start with one scored case and add either workflow
when their need changes.

The easier entry path is a source and fixture conclusion. First-time user
comprehension, the new desktop layout, and a live run of the example on an
Apple Intelligence Mac remain unverified.

This review covers the native app and its direct handoffs to the connector,
workers, model providers, and test runners. It does not qualify the separate
standalone plugin UI, public website, CLI distribution, or release/updater
artifact. The installed or released app was not changed. Live on-device/cloud
models, external judges, Core AI resources, physical app runners, Direct Action
and live Siri, and provider privacy delivery remain unverified. The review used
synthetic workspaces and fixtures. Workspace-wide backup and restore was
source-traced only.
