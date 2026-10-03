# Eval review worklog

Goal: research, specify and implement native review -> confirmed patterns -> regression -> existing experiments, plus calibrated judge checks. Separate feature branch, preserving current UI standards.

Base: 078fa0c96abf60ebe67a436fa5a00f206b7f00e4 (PR #66 stack tip, fetched 2026-10-03). Worktree: /private/tmp/intents-eval-review. Branch: codex/eval-review-workspace. Not a stack layer; merge only after stack.

Completed: inventoried stack/dependencies and dirty work; created isolated branch; read Lenny previews, author methodology and installed Apple documentation; mapped current review correction/replay, state persistence, cases, experiments and shared UI.

Contract: docs/EVAL_REVIEW_SPEC.md. Existing scoring, evidence and consent contracts stay intact. Reuse native components; additive local review state and explicit source links.

Remaining: complete final targeted checks and native appearance/interaction verification; commit on independent branch. Native verification currently needs the Mac unlocked.

Implementation: additive suite-local annotations/proposals; immutable source digests; deterministic discovery ordering; confirmed tagged patterns; regression cases with provenance and explicit expected answer; development/held-out judge groups; separate confusion summaries; bounded MCP list/propose operations; Review tab using existing UI primitives. Added focused unit/integration and native UI tests.

Verification trace: initial Xcode MCP open used unsupported workspacePath field, corrected after reading tool schema; corrected call requires user MCP approval. Continue shell path. Initial shell build failed fetching packages in sandbox (DNS). Reused /private/tmp/IntentsReviewFixes-DD64/SourcePackages with isolated DerivedData and two jobs. Compilation identified definition attachments omitted by design; promotion now compares source attachment snapshots separately. MCP integer payloads use Int64. Full build logs retained under /private/tmp/intents-eval-review-*.log.

Independent review: Sol 6.1 reviewers assigned disjoint evidence/MCP and UI integration responsibilities; read-only, no concurrent builds or app launches.

Review fixes: retained source-keyed unfinished drafts; identified unavailable judge sources; guarded output digest at replay; included subject definition in identity; verified run-owned images; compared historical local sources or failed closed; inherited held-out partition for legacy corrections. First focused run: 20 new workflow tests passed. Recheck found Core AI clearing-path bypass; fixed provider-based guard and added regression. Native integration suite in progress.

Final targeted batch found the existing catalog completeness test needed two new names and exposed a real missing JSON Schema declaration on the new tools. Added the standard schema URI and updated the complete ordered catalog assertion. Retained failure trace in /private/tmp/intents-eval-review-final.log and .xcresult. UI run was interrupted safely after existing workflow tests passed because native test runner could not access the locked Mac.

Native test source correction: ContentView enforces minWidth 1000. The narrow test now resizes to that supported width (asserts <=1050), which still triggers the existing pane-menu breakpoint after the main sidebar/margins. It does not change the app's window or UI standards.

Final source verification: 153 tests in five suites passed in /private/tmp/intents-eval-review-final2.xcresult (23 new review tests plus existing development workflow, compatible-judge integrity, MCP authority and protocol checks). Independent evidence/UI rechecks report no remaining material source findings. Original checkout remains codex/local-workspace-20261001 at cc64e220d. No stack metadata or existing PRs changed.

Native boundary: CUA reports Mac locked and automatic unlock unavailable; user unlock requested. UI test source is present, with fixture and explicit supported narrow width, but interaction/appearance checks remain unverified. Interrupted only this task's waiting UI run. Test app processes exited. Xcode list confirms only the pre-existing Interval workspace; no eval workspace to close.

User steering: promote Evaluations and Traces into the main sidebar alongside Overview/Intent Lab. Evaluations opens Review with the existing editor tabs; Traces lists saved runs visibly and opens the existing trace/report viewer. Preserve UI components/colors. Native inspection also exposed a parent accessibility identifier overriding review-control IDs; remove the unnecessary parent identifier and give the note field a clear label before real UI tests.

Sidebar verification: build-for-testing passed; 23 review tests passed on current source. Native XCTest runner is killed before bootstrap with unsigned, ad-hoc and existing Apple Development signatures; development runner verifies on disk. Preserve three xcresults/logs; no UI assertions ran. Continue actual native flows with CUA and isolated fixtures. Diagnostic lesson: zsh `log` is a shell builtin and numeric message filters can match unrelated records; use /usr/bin/log with processID/process predicates and never publish raw system logs.

Native CUA verified on isolated fixture: sidebar Evaluations selects Review directly, Traces lists the saved run and opens its existing viewer (legacy durations explicitly lack timeline offsets); unfinished verdict/note/tag survive sidebar roundtrip; Save confirms failure; Patterns shows one confirmed source and opens it; promotion sheet starts blank/disabled, supplying Friday creates a saved Regression: Meeting date case with correct prompt/reference. Native appearance exposed singular count grammar; fix and recheck with final source.

Final sidebar acceptance: 23 review tests passed again in /private/tmp/intents-eval-sidebar-final.xcresult; native app and UI target compile. CUA reopened the final app and confirmed saved verdict/note/tag and the created regression case persisted. Native half-screen resize reached about 1001 points: top destinations remain visible, compact Review selector activates, Samples/Patterns remain readable and singular counts are corrected. Separate empty workspace verified Traces -> Open evaluations -> empty Review. Light appearance inspected; app-only dark argument had no visible effect, so dark remains unverified. Sol UI recheck found no remaining material source issue. Close isolated test apps, then open the exact latest app on the user's normal workspace as requested.

Latest app left open on Testing / Conversation behaviour with Evaluations selected and six existing saved outputs visible. Executable identity verified at /private/tmp/intents-eval-review-build/Build/Products/Debug/Intents.app/Contents/MacOS/FoundationEvals. CUA's /private/tmp app lookup timed out after this relaunch; a short process sample showed the main thread idle in the normal event loop, and selecting the registered /tmp alias worked immediately. Use the registered canonical app path when CUA path lookup fails; do not infer an app hang from the lookup timeout. No user reviews or cases were modified during this final read-only inspection.

## Replacement branch — 3 October 2026

- Rebuilt on current main (`2477e157c`) after the prior stack landed through squash merges.
- Applied only original evaluation commits `e6103c417` and `8d24fb5f1`; range-diff confirms both patches are unchanged.
- The replacement contains the 29 evaluation files and preserves main’s later Siri/fixture checks.
- Preserve the dirty primary and production-evaluation checkouts; prepare the production PR’s committed layer separately.
