# Automatic instruction improvement

## Outcome

From Setup → Instructions or Compare → Instruction experiments, choose **Improve instructions**. Freeze the current suite, reserve user-selected cases for Held-out validation, generate two alternatives, and compare their pass rates. Review the instructions and evidence before explicitly applying a validated candidate.

## Implementation contract

- Improve shared model instructions; never rewrite test prompts, expected answers, rubrics, tools, or model settings.
- Require at least two distinct cases, scored results, and a nonempty Development/Held-out split. Preserve repetitions and existing external-judge disclosure requirements.
- Run the Development baseline, then ask the on-device Swift FoundationModels API for two distinct alternatives. The generator receives only Development cases and their baseline outputs. Treat these as data. Never send Held-out cases or outputs to the generator.
- Evaluate both alternatives on the same Development cases. Select a strict pass-rate improvement using Development evidence alone; ties keep the first candidate. If none improves, stop.
- Evaluate only that candidate and the original instructions on Held-out cases. Recommend application only with complete, error-free evidence, an improved Development pass rate, and no Held-out case pass-rate regression. Show pass counts without statistical-significance claims.
- Bound execution to two candidates and one selection round. Display the maximum sample budget before starting. Cancel through the existing run lifecycle, prevent concurrent workspace execution, and preserve phase checkpoints. Interrupted runs cannot be applied or resumed against reused holdouts as if they were fresh.
- Persist the frozen suite, split, candidates, and run evidence. Completed runs also enter ordinary history for trace inspection. Legacy suite state defaults to an empty improvement history.
- Mark comparison records durably so default suite/project release checks keep selecting ordinary full-suite runs. Explicit run-ID checks still evaluate exactly the requested record. Scope critical release-case IDs to each comparison partition while preserving the full source policy. Clean up unpublished snapshots when preparation fails.
- Apply only on an unchanged source suite and draft, through the existing save/rollback machinery. No automatic adoption. Report save failures and preserve recoverable evidence.

## Verification

Regression coverage: partition validation and leakage, generation constraints, Development-only selection, Held-out regression, incomplete/error/duplicate evidence, cancellation, state round-tripping, stale application, and persistence rollback. Build the macOS target and inspect the sheet and result flows. Use an independent scoped reviewer after implementation.

## Scope

Use the app's existing Swift framework integration. FM CLI adds no necessary capability to this feature. Iterative hill climbing, automatic retries after Held-out results, test-case generation, and autonomous adoption are outside this first version.

## Initial local verification

- macOS app build and `build-for-testing` succeeded with Xcode 27.1. The current core changes passed 37 case invocations across 19 test methods in the prompt-improvement and existing experiment-runner suites, with no failures or skips. Results: `/tmp/intents-prompt-improvement-native-tests-final.xcresult`.
- Inspected the running app using temporary isolated storage: the Setup entry point, one-case readiness blocker, Development/Held-out controls, and five-sample budget for a two-case suite rendered correctly.
- Independent review identified checkpoint navigation, terminal cancellation, and fixture identity issues; all three were repaired. Live verification additionally found missing frozen-run metadata and disabled sheet controls inherited from Setup. Both were repaired; an independent follow-up found no remaining issues in those fixes.
- With the user's approval for native execution, real on-device comparisons generated and evaluated two alternatives and saved the no-improvement outcome without touching Held-out cases or changing instructions. This small fixture did not produce a validated winner; successful candidate application, Held-out regression rejection, and save rollback passed the deterministic regression tests.
- Direct UI verification with the repository's delayed loopback fixture confirmed that Cancel and Done stay enabled during execution. Cancel stopped the request, saved a cancelled report, restored the form, and left Apply unavailable. The temporary app and fixture server were closed afterward.
- Added a native UI regression for this interaction. Its bundle compiled, but Xcode's UI runner was killed before establishing a test connection, including after using the prepared descriptor and repairing its temporary signature. Automated UI execution remains blocked by that host/toolchain prerequisite; it is not a passed check.

## Pull request qualification

The feature was ported into an isolated branch from current main, preserving newer unrelated fixes. Prior local test results above describe the original implementation workspace; GitHub Actions qualifies this PR's actual source. UI checks run only on GitHub. The cancellation UI regression now uses deterministic suggestions in an explicitly isolated Debug launch, so it does not skip when the hosted runner lacks Apple Intelligence. The fixture flag has no effect in Release builds or normal non-isolated launches.


## UI iteration

Use the existing workspace surfaces, inset text wells, notices, typography and 24-point sheet chrome. Keep the sheet footer visible while its body scrolls. Present one screen at a time: setup, active comparison, selected result, or compact history.

- Explain Development as **Practice** and Held-out as **Final check**. Preselect the split, keep individual choices in a disclosure, and state that saving is always explicit.
- Keep the maximum response budget visible before starting. Missing cases or scoring explain the next action and replace the footer’s primary action with direct recovery to the relevant editor. Keep that action outside combined notice accessibility elements.
- Make every disclosure’s full label row clickable with a native button while retaining its disclosure role and announced expansion state.
- Track the active comparison by ID so an ordinary evaluation never appears as an active instruction comparison. Allow closing and reopening it while editors remain locked.
- Lead results with a plain-language outcome, then compare pass counts and both instruction texts. Distinguish incomplete runs, unused final checks and suggestions with no selected winner. Keep full evidence and alternative suggestions in disclosures.
- Preserve stale-suite protection and per-case final-check checks. History reflects stale and applied results; reopening returns to the latest result or active comparison.
- Check light/dark appearance, compact/normal windows, long labels and instructions, selection errors, progress/cancellation, successful application, no improvement, final-check regression, failure, interruption, stale results, history and evidence navigation using isolated fixtures. Fixture outcomes verify presentation and interaction; they do not measure real model quality.
- Run automated UI regression coverage on GitHub, including setup recovery, close/reopen/cancel and deterministic comparison/review/apply flows. Retain screenshots in test attachments. Native presentation regressions cover setup guidance, lifecycle summaries and incomplete scores.
