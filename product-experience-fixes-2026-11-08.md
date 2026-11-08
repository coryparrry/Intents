# Experience review fixes — 8 November 2026

Remediation of the 13 findings in [the experience review](product-experience-review-2026-11-08.md). Changes build on the existing working tree, including its uncommitted Siri Studio implementation. The original reports and unrelated edits are preserved.

At the user's request, the newer UI from [PR #190](https://github.com/coryparrry/Intents/pull/190), head `8606d3c35ea7b94f7f0d38c54ea74aa29811b324`, is now carried into this checkout. Its Runs/setup navigation and native window appearance are combined with the review fixes and existing Siri work. The two overlapping views were reviewed independently after integration. Release/version metadata was not imported.

## Implemented changes

| Finding | Result |
|---|---|
| Unsaved Siri edits | Per-app recovery drafts retain edits and their saved revision baseline. Opening another document saves existing work first. Failed writes preserve the editor and expose retry. Quit stays open when unsaved work cannot be persisted. Clean saved documents do not require recovery storage to quit. |
| Imported Siri evidence | Import saves and revisions the document first. Generated summaries and transcripts carry a digest of the authored scenario and target app. Changed arguments and independently edited copies cannot accept old verdicts. Older saved verdicts without verifiable content identity reopen blocked, retaining observations. |
| Removing a Siri turn | Confirmation identifies that the utterance and its expectations will be removed. Cancelling retains both. |
| Siri app-selection save errors | The active Siri panel displays the save error and retry control while preserving the draft. |
| Incomplete/incompatible result summaries | Native headlines and history show scored/planned and saved/planned counts with completion status. Deltas require complete, uninterrupted, compatible runs. Unknown coverage remains unknown. Plugin history suppresses comparisons it cannot substantiate and separates errors from scored failures. |
| Archive recovery | The manager exposes archived projects and suites with restore controls. Restoration retains stable identities, saved evidence and selection, and rolls back failed catalog writes. Duplicate names remain distinct records. |
| Blank suite | New blank suites and blank projects start without a scored example. Starter/onboarding examples remain. Blank metadata can be renamed without accepting an invalid runnable suite or losing unfinished draft fields. |
| Capacity-limited import | Preview shows valid source, fitting and omitted counts. A partial import requires acknowledgement; an empty destination retains the chosen file and mappings from either editor entry point. Guidance explains duplicate reimports and interactive limits. |
| Batch baseline without scores | A missing candidate pass rate shows comparison unavailable. A genuinely scored zero-percent candidate still produces its correct delta. |
| Unfinished operator review | All form fields persist by job and result across selection, paging, pane changes and reopening. Failed writes retain in-memory input with retry and quit protection. Assignment/labels retain reconciliation input; successful reconciliation clears only its unchanged submitted draft. |
| Failure-pattern drilldown | Opening a pattern selects current Human failures with its tag. Users can deliberately change the verdict filter to broaden the list. |
| Scheduled batches | Rows identify the template, next due time and paused/exhausted state. Guidance requires a polling worker or explicit schedule tick; the ordinary open app alone does not start schedules. |
| Backup/restore boundaries | The central guide includes the native workspace, Siri, Direct Action, plugin, explicit CLI stores, external files, preferences and Keychain boundaries, plus staging, verification and rollback instructions. Synthetic directory recovery checks retain file bytes and reopen native batch records/drafts. |

## Review and validation

Independent reviewers covered workspace/imports, Siri/evidence/quit, production drafts/reporting, and native/plugin result presentation. Material findings were verified and corrected, including import-sheet continuity, preservation of reconciliation input after assignment, clean-document quit behavior, stopped-run comparisons and plugin error classification.

Completed checks:

- `CI_TEST_SELECTION=<router Python selection> python3 script/ci_run_tests.py python`: 394 tests passed. The final routing changes were rechecked with `python3 -m unittest script.tests.test_ci_routes script.tests.test_ci_native_routes`: 70 passed.
- macOS script selection through `script/ci_run_tests.py python`: 13 tests passed.
- Final native build with PR #190's UI: passed. `script/ci_native_tests.py` selected the complete `FoundationEvalsTests` target: 1,044 tests passed (1,522 executed cases), zero failures, six existing corpus/live document opt-ins skipped. The configured Core AI resource test remains excluded by the maintained manual-test policy.
- `CI_TEST_SELECTION='["*"]' python3 script/ci_run_tests.py swift --scratch-path /tmp/intents-experience-portable-build`: passed; the explicit live Siri qualification remains excluded by policy.
- Plugin `npm test`: 317 passed; `npm run typecheck`, `npm run build:ui`, and `node scripts/package.mjs /tmp/intents-experience-apple-foundation-evals.zip`: passed.
- Plugin `npm run test:native`: passed, including core boundaries, process protocols, workflows and revision/summary checks. Its basic local-model smoke inference completed.
- `bash script/ci_production_evals.sh`: 82 production tests passed; CLI integration passed 89 assertions.
- `python3 -m unittest script.tests.test_shared_app_sources`: 7 passed.
- Pinned actionlint, `shellcheck script/*.sh`, Python example compilation, and all website checks: passed (40 website tests).
- Local links in changed guides: 71 checked, none missing.
- `python3 script/docstring_coverage.py --minimum 85`: 99.10% overall. Task-specific changed-function comparison against the preserved working-tree baseline passes. The whole-checkout `changed_function_docs.py --base HEAD` separately flags 26 pre-existing undocumented video/website declarations outside this task.

The final isolated local UI checks passed both import flows and review navigation/layout. Three failed: archive restoration stopped at the collapsed disclosure (`value` remained `0`); Siri recovery did not find the reply-check field after clicking Add reply check; Siri save/reopen did not find the second utterance control. These are retained failures, not successful qualification. Native restoration, identity, persistence and Siri regression tests pass.

Passing automatic screenshots are discarded; failure screenshots and explicit captures remain. The newer Runs screen, App Intents controls and complete-import preview were inspected directly with synthetic data. Native results remain valid after UI-test-only changes: app sources, native tests, toolchain and dependencies are unchanged and matched the validated snapshot. Subsequent UI-test changes are verified on GitHub.

The native validation copy uses a distinct bundle identifier and isolated storage to preserve the existing running Intents session. Its copied UI identity guard requires that explicit validation identifier; the repository guard remains unchanged. Initial environment failures (missing explicit signing team, full temporary disk and sandbox compiler-cache access) are recorded in the temporary validation logs; they are not passing checks. An earlier run against the older UI is superseded: it exposed a backup-fixture path-alias comparison and an ambiguous archive-test selector, both corrected before the newer UI build.

The user explicitly requested testing on GitHub instead of locally. Further local testing stopped. This authorizes the repository's exception for publishing the candidate before every local check is green; the PR discloses the outstanding UI failures and uses GitHub CI for subsequent verification. Unrelated website/video work remains outside the candidate. The candidate combines the existing Siri Studio draft, the requested PR #190 UI and these review fixes.

[PR #195](https://github.com/coryparrry/Intents/pull/195) publishes the combined candidate. Its [first GitHub CI run](https://github.com/coryparrry/Intents/actions/runs/42515115064) passed the native build, portable/native regression job, workflow/script checks and trace UI shard. The standalone plugin and documentation workflows also passed. The other two UI shards each passed 18 of 19 tests: Siri recovery's Cancel query also matched a Touch Bar button, while the archive click missed the visible disclosure chevron. Hosted recordings and logs establish those selector failures. The follow-up scopes confirmation buttons to their sheet and accounts for the manager's 24-point chevron inset; its GitHub rerun is pending.

No live Siri, external-provider, physical-device or Keychain-migration qualification is claimed. No merge or release is included in this task.
