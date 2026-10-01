# Production review resolution — 1 October 2026

Seven established defects and seven concrete cleanup groups were resolved in the local application snapshot. The two conditional architecture refactors remain deferred.

| Defect | Correction |
|---|---|
| Repository errors could overwrite valid local decisions | Load durable local state before repository parsing and reconciliation. |
| Recovery suites used an ID different from the catalog | Preserve the selected catalog ID in missing-suite and corrupt-catalog recovery. |
| Failed catalog updates left refreshed suite data partially committed | Restore canonical suite bytes if the catalog update fails. |
| Project preview expanded external XML entities | Reject DTDs before parsing and prohibit external entity loading across supported Unicode encodings. |
| Flat bundle assumptions rejected native Mac products | Resolve metadata, executable, resources, and fingerprints consistently for native Contents and flat layouts. |
| Cleanup could erase successful Siri proof | Capture assertions, claims, provenance, and screenshot before fixture cleanup. Cleanup failure and quarantine behavior remain. |
| The bundled CLI could not authenticate | Load the local Keychain credential or a private credential file and send Bearer authentication. Reject redirects and insecure remote transport. |

Removed unreachable internal errors and unused helpers/parameters, collapsed unreachable feature-result branches, removed the constant-empty Tasks receipt cache, shared relative-path calculation, and reused one OpenStep parse per insertion. The live legacy completion helper remains.

## Reconciliation with the existing PR stack

The publication layer is based on PR #63 and preserves its newer snapshot recovery, draft-generation, runtime, source/product fingerprint, and saved-execution safeguards. Persistence, XML, and bundle fixes were adapted to that source rather than replacing newer implementations with older local files.

The shared Core Siri engine already evaluates results inside the lifecycle action before cleanup. Its existing lifecycle tests cover context-clearing cleanup, cleanup failure, incomplete completion, and invalid receipts. Most dead-code and parser/path simplifications are also present in the base. The Tasks observation helper now has live upstream test callers and remains. The older snapshot's Contracts result helper and test target were not ported into this architecture.

CLI publication retains the existing environment credential and saved-execution report workflows while adding private credential files and redirect/transport protections. Default Keychain loading is limited to the default connector endpoint; custom endpoints require explicitly supplied credentials.

The complete local source snapshot and six historical source-only snapshots are published separately. Historical backups retain source while excluding private verification ancestry and local working notes. Generated verification directories remain local.

## Local validation before publication

- Package suite with two build jobs and isolated caches: 134 portable, 18 contract, 14 developer, and 3 result-capture tests passed.
- Authenticated localhost CLI integration suite: 8 passed.
- FoundationEvals/My Mac app/test build and selected persistence/lifecycle tests: 11 cases passed, including all 5 new recovery cases.
- Legacy fixture and Tasks package-consumer generic-iOS test builds: passed with signing disabled and two build jobs.
- Scoped whitespace and source-preservation checks passed.

Initial sandbox socket/file-coordination restrictions were resolved by authorized local test execution outside the sandbox. An initial Siri test target could not load an SDK framework due to an OS private-symbol mismatch. The final framework-free target runs its three regressions without runtime skips, and the consuming testing module compiles.

Physical Siri, actual screenshot timing, a real native Mac direct-check connection, signed distribution, and the live default Keychain prompt were not exercised. Consumer builds did not launch devices or execute UI tests. Generated builds, raw device evidence, private verification history, and local working notes are retained locally.

## Final reconciled stack validation

- Portable suite: 292 passed, including Unicode XML and native/flat bundle regression cases.
- Core lifecycle suite: 32 passed, including existing Siri cleanup/receipt tests.
- Contracts: 27 passed. Developer registry/protocol: 18 passed.
- Reconciled CLI: 11 passed, including environment credentials and saved-execution qualification exit codes.
- Native FoundationEvals Mac build and three selected persistence/lifecycle suites: 20 passed, zero failed/skipped, signing disabled.
- Two independent review lanes found no material defects in the reconciled source.

The overall package command exited 1 because the existing IntentLabTesting test bundle cannot load the installed SDK's AppIntentsTesting framework on this Mac: it requires a missing private OS symbol. That target did not execute; the other four suites above passed. This is a local SDK/runtime limit and is not presented as an application defect or a passing full suite.

Publication follow-up: the repository requires curated release-note overrides, now present and locally validated in the PR body. The new native-bundle suite is registered in the CI dependency catalog for executor and test-file edits. All 104 CI-selected script unit tests passed locally after that registration, including all 11 CLI integration tests.
