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

The existing result calculation now lives in a package-scoped Contracts helper. Production passes actual adapter callbacks synchronously; regression tests use that shared calculation without loading the SDK UI framework. No public API was added. Independent review confirmed equivalent assertion, claim, and provenance behavior. It also caught and verified a correction permitting the normal first-access Keychain authorization prompt.

## Local validation before publication

- Package suite with two build jobs and isolated caches: 134 portable, 18 contract, 14 developer, and 3 result-capture tests passed.
- Authenticated localhost CLI integration suite: 8 passed.
- FoundationEvals/My Mac app/test build and selected persistence/lifecycle tests: 11 cases passed, including all 5 new recovery cases.
- Legacy fixture and Tasks package-consumer generic-iOS test builds: passed with signing disabled and two build jobs.
- Scoped whitespace and source-preservation checks passed.

Initial sandbox socket/file-coordination restrictions were resolved by authorized local test execution outside the sandbox. An initial Siri test target could not load an SDK framework due to an OS private-symbol mismatch. The final framework-free target runs its three regressions without runtime skips, and the consuming testing module compiles.

Physical Siri, actual screenshot timing, a real native Mac direct-check connection, signed distribution, and the live default Keychain prompt were not exercised. Consumer builds did not launch devices or execute UI tests. Generated builds, raw device evidence, private verification history, and local working notes are retained locally.
