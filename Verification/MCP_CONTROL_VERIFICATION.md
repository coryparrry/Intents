# MCP app-control verification

Verified 3 October 2026, final live check completed by 17:13:59 UTC. This extends PR #68's production workspace with shared native app controls. The original working checkout was not edited.

## Result

- 110 unique MCP tools discovered, including the original 19. Typed workspace, review/calibration, batch/upload/export/schedule, runner and Intent Lab controls route through the same stores/coordinators as the UI.
- Final authenticated localhost HTTP run: **147 checks passed**, **100 distinct synthetic captured outputs** retained verbatim and unscored; **one separate real Apple on-device response** passed its configured criterion. Captured job ID: `97dded40-22d8-4b03-879a-396c3b6f8dcf`. Dataset revision: `803d65db115a492de9024efeb90fe0c77bb185086468547f5a3f698b5f2c55d5`.
- Checked operation retry identity, stale revisions, strict schemas, chunk integrity/preview/import, complete results, control CAS, schedule creation/deduplication, date rejection, exported report download, traversal denial and durable unapproved-build failure.
- Native accessibility and screenshot inspection showed **MCP verification / MCP controlled suite / Batch runs / Reports**, **MCP real Apple smoke Pass**, **1 of 1 saved / 1 passed / 0 errors**, on-device AFM 3 Core Advanced, Apple silicon, en_GB, macOS 27.2. Existing native layout and semantic colors retained. All instances of the isolated test build were closed afterward.

## Build and test evidence

Build product: `/private/tmp/intents-mcp-control-build/Build/Products/Debug/Intents.app`, bundle ID `com.coryparry.FoundationEvals`. Live connector process PID **73423** used `--evaluation-storage /private/tmp/intents-mcp-live/workspace --mcp-use-existing-credential`. The existing Keychain credential was used privately; it was not printed, rotated or committed.

This is an unsigned-development Debug build with linker ad-hoc signatures, not a notarized or distributed release. SHA256:

| Artifact | SHA256 |
|---|---|
| FoundationEvals executable | `a5053256ced6b91d536c44fc5bcec7c1c9f629567e6324f41f99f2435a4bb41b` |
| FoundationEvals.debug.dylib | `f929b88c583235c4704271bc9f4329c61d6905eb381d05a200f7c88314fd3e48` |

Commands/results:

```sh
swift test --package-path Packages/ProductionEvals --scratch-path /private/tmp/intents-mcp-core-tests -j 2
swift test --package-path Packages/ProductionEvals --scratch-path /private/tmp/intents-mcp-core-tests -j 2 --filter ProductionUploadTests
xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals -destination 'platform=macOS' -derivedDataPath /private/tmp/intents-mcp-control-build -clonedSourcePackagesDirPath /private/tmp/IntentsReviewFixes-DD64/SourcePackages -jobs 2 OTHER_SWIFT_FLAGS='$(inherited) -j2' CODE_SIGNING_ALLOWED=NO -only-testing:FoundationEvalsTests/MCPAppControlTests -only-testing:FoundationEvalsTests/MCPProtocolTests -only-testing:FoundationEvalsTests/MCPTransportRegressionTests test
python3 script/verify_mcp_app_control.py --native
```

The full core run passed all 19 existing tests, including 10,000-example resume without duplicate execution. One new assertion incorrectly compared raw versus persisted millisecond-rounded dates; it was corrected to compare the immutable revision. The subsequent focused run passed all **4 new upload/control tests**. Final native run passed **29 tests in 3 suites**, including export path alias/symlink and large persisted-result chunk regressions. Builds/tests ran sequentially with a maximum of two compile jobs; no automated UI test was executed. Python syntax check and `git diff --check` passed.

Live verification used the environment credential privately via the wrapper described in the guide. Log: `/private/tmp/intents-mcp-live-verification.log`. Final native log: `/private/tmp/intents-mcp-native-tests.log`; upload/core logs use the scratch-path names above with `.log` suffix.

Source identity was captured over 374 app/project/core/package inputs before commit/rebase. Sorted path/SHA256 manifest digest: `72498e8595efd4690cfc4d5e7ab8451f1fda202dbec5de16d6212ed22fc31e0e`. The local manifest is `/private/tmp/intents-mcp-verified-source.json`. After carrying only the new commit onto remote production head `91d5f469ea9644bee30fe11fe8fb0ef8664176f4`, all 374 input hashes remained identical. Newer fixture/CI changes were preserved; no native/core rebuild was required for that ancestry-only change.

## Independent review and retained failure lessons

Independent read-only reviews separately covered core authority/receipts/uploads/batches and shared native/device/installer/consent paths. Material findings were fixed, with reviewer rechecks clear. The final export fix was independently reviewed after the HTTP failure.

- Initial immediate post-launch HTTP call failed with `ConnectionRefusedError: [Errno 61] Connection refused`. Trace retained at `/private/tmp/intents-mcp-live-startup-failure.log`. Prevention: bounded initialization retry only for connection refusal.
- Final-build HTTP export check initially failed `AssertionError: export report manifest`. Trace retained at `/private/tmp/intents-mcp-live-export-pagination-failure.log`. Inspection then showed paths such as `<last eight UUID chars>/report.json`, caused by enumerated `/private/tmp` versus configured `/tmp`. Prevention: canonical root and guarded path components, alias/read compatibility and file/root symlink regression, complete manifest pagination. Final rerun passed.

## Qualification boundaries

The connector must already be enabled/authenticated. Product/domain operations are exposed; MCP does not automate window pixels, bootstrap its own access, launch arbitrary command workers or fabricate operator approval/device trust. Physical pairing, Siri/device execution, external judges, installer execution against a real consumer app and real production traffic were not exercised in this live run. They retain existing consent, trust, readiness and review safeguards.

Existing PR #68 production release-gate review findings remain open in their own review scope. These MCP checks establish controls, transport, retained evidence and a small real Apple model response; they do not qualify all underlying production gates or a distributed release.
