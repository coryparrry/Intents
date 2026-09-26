# Reusable Intent Lab implementation and verification

Started 2026-09-26 from the existing PR #51/#52 descendant checkout. The two
pre-existing local edits in `AppleTestConnectionView.swift` and
`IntentLabGuidanceUITests.swift` are outside this work and must be preserved.
Branch `cursor/macos-ui-redesign-341e`, base commit
`38dc7e28bfe2b251c0b40a1bc76ecdf8c4670b29`; the integration changes are
currently working-tree edits on top of that commit. Environment:
macOS 27.2, Xcode 27.0 (27A266a), iOS 27 Simulator for the local runtime tests.
Simulator builds are unsigned; a physical-device signature identity was not
established because provisioning profiles were unavailable.

## Milestones

- M1 contracts and coverage: implemented v2 purpose, check mode, claims,
  observation plan and integration identity with v1 golden samples; focused
  host suite passes.
- M2 reusable runner: package products and two example adapters compile;
  declaration allowlisting, generic queries and timeout fencing pass targeted
  source/contract checks. Notes direct and real entity-query Simulator checks pass.
- M3 independent task app: standalone SwiftData example and controlled faults
  pass 12/12 focused Simulator checks; clean outside-repository installation
  builds against a pinned development Git snapshot.
- M4 guided installation: static preview, transactional apply/recovery,
  workspace ownership, connection receipt and Mac UI are implemented.
- M5 qualification: host policy, CLI gate, visual inspection, release-hook
  exclusion and local Git consumption checked. Physical Mac Run/Siri and report
  relaunch demonstrations are blocked by provisioning.

## Verification ledger

Record exact commands, results, product revisions, evidence paths, and external
blockers here as each milestone becomes testable. A passing XCTest capture is not
a passing scenario or release requirement without the host report gate.

- M1 host contract test: `xcodebuild test -project FoundationEvals/FoundationEvals.xcodeproj
  -scheme FoundationEvals -configuration Debug -destination 'platform=macOS'
  '-only-testing:FoundationEvalsTests/ScenarioContractsTests'
  -disableAutomaticPackageResolution -derivedDataPath
  /private/tmp/intent-lab-host-owner-fresh-derived CODE_SIGNING_ALLOWED=NO`
  passed 45/45 on Xcode 27.0 after v2 identity, importer, release policy,
  recovery, workspace-scheme fingerprinting, and duplicate-name owner binding.
  Result bundle:
  `/private/tmp/intent-lab-host-owner-fresh-derived/Logs/Test/Test-FoundationEvals-2026.09.26_8-34-07-+0100.xcresult`;
  log `/private/tmp/intent-lab-host-contracts-test-owner-incremental.log`.
  An earlier isolated build cache had an incomplete Sparkle artifact; a fresh
  cache resolved it before this successful run.
- M2 package: `swift build --disable-sandbox --target IntentLabContracts` and
  `swift build --disable-sandbox --target IntentLabTesting` passed; the existing
  public `FoundationEvalsDeveloper` product also built. Final contracts tests
  passed 12/12 including direct-timeout and unresolved-Siri process-local
  fences plus query provenance. Logs: `/private/tmp/intentlab-contracts-siri-fence.log`,
  `/private/tmp/intentlab-developer-final.log`, and
  `/private/tmp/intentlab-testing-final.log`. The notes
  consumer passed `xcodebuild build-for-testing -destination 'generic/platform=iOS'
  CODE_SIGNING_ALLOWED=NO`; log `/private/tmp/intentlab-notes-build-for-testing.log`.
  Both the preserved v1 and package-backed v2 notes test targets compiled;
  final v2 log `/private/tmp/intentlab-notes-v2-final2.log`. This confirms
  compilation and linkage. Notes v2 then passed 4/4 Simulator connection and
  bounded-query checks (`/private/tmp/IntentLabNotesV2Queries.xcresult`), a
  direct Behaviour run (`/private/tmp/IntentLabNotesV2Direct.xcresult`), and
  2/2 real entity-query positive/missing-ID checks
  (`/private/tmp/IntentLabNotesV2EntityQueryFixed.xcresult`). Exported direct
  evidence at
  `/private/tmp/IntentLabNotesV2DirectAttachments/2D8B96E0-6750-41E9-A096-1F9BC0C4BEA7.json`
  records a completed, passed lane, execution/return/state claims, and
  `openedNoteID` plus selected-note read-back equal to `packing-001`. The
  positive entity query initially failed with an `NSNull` dynamic-property
  cast (`/private/tmp/IntentLabNotesV2EntityQuery.xcresult`); marking its
  projected `AppEntity` field with `@Property` made that check pass. This is
  Simulator execution, not physical Siri or a host-qualified release report.
  After the Siri fence change, the notes v2 UI-test bundle rebuilt successfully
  (`/private/tmp/intentlab-notes-v2-siri-fence-build.log`); Siri itself still
  has no physical execution evidence.
- M3 task consumer: `xcodebuild -project examples/IntentLabTasks/IntentLabTasks.xcodeproj
  -scheme IntentLabTasks -configuration IntentLabTesting -destination
  'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build-for-testing`
  passed after the generic query and fault-scenario changes. Result bundle:
  `/private/tmp/IntentLabTasksBuild9.xcresult`. A later focused iOS 27.0
  Simulator run passed 12/12 after the task `AppEntity` projected fields gained
  `@Property` metadata and the declaration was bundled as a test resource.
  Result `/private/tmp/IntentLabTasksRuntimeFinalRetry.xcresult`, log
  `/private/tmp/IntentLabTasksRuntimeFinalRetry.log`. The cases cover direct
  Basic output-only evidence, correct persistent Behaviour, plausible return
  with suppressed save, unrelated-task mutation, wrong expected value with
  retained actual state, and old/empty context rejection with app reopen and
  persisted-row inspection. Failed behaviour remains a completed failed
  scenario and does not qualify for release. A normal Release simulator app
  build had passed earlier (`/private/tmp/IntentLabTasksReleaseBuild.log`);
  the final normal Release simulator app rebuild also passed
  (`/private/tmp/IntentLabTasksReleaseAfterQueryFix.log`). Its binary inspection
  found no test-only fault intent or hook symbols, and the project configuration
  links `IntentLabTesting` and `IntentLabContracts` only to the UI-test target.
  Outside-repository consumption used the final local Git snapshot commit
  `d7379790ab4c7694a67071b48a43ff9a6d9ee032`. A clean app-only task
  project with the actual installer-applied integration passed generic Simulator
  `build-for-testing` against that revision; final build log
  `/private/tmp/IntentLabTasksInstallerFinalBuild.log`. An already-integrated
  consumer also built against an earlier, superseded development snapshot. Clean
  baseline `/private/tmp/IntentLabTasksInstallerClean`, installed consumer
  `/private/tmp/IntentLabTasksInstallerBaseline2`, exact consumer diff
  `/private/tmp/IntentLabTasksInstallerApplied.diff`, installer proof
  `/private/tmp/IntentLabTasksInstallerProof.log`, and receipt
  `/private/tmp/IntentLabTasksInstallerBaseline2/IntentLabInstallationProof.json`.
  The diff contains the test target, scheme, pinned package reference,
  declaration, entry point, and app-owned adapter only; no shared runner or Mac
  host edits. Declaration `1.0.0` digest is
  `1298bb534a365adf22e013582849670c50b00a7ee359842ac203310635004624`;
  adapter SHA-256 is
  `94e49656ccd68e726113bbd54ca4a406ab1d463e0e3daf1913eed29d4bd3eace`.
  The installer template has no separate version identifier. The consumer's
  HTTPS origin and exact revision are pinned in `Package.resolved`, and Xcode's
  resolved checkout matches that revision. This development commit exists only
  in a temporary local Git snapshot; the build used a process-scoped Git URL
  rewrite to it. Remote fetching of the unpublished revision is unverified and
  must not be described as a released package.
  A signed device retry using an existing team through a command-line override
  failed because the task app and UI-test runner lack iOS development
  provisioning profiles (`/private/tmp/IntentLabTasksDeviceBuildWithTeam.log`,
  lines 63–64). No signing project settings or portal state were changed.
- M4 installer: `swift test --disable-sandbox --scratch-path
  /private/tmp/intentlab-installer-swiftpm --filter IntentLabProjectInstallerTests`
  passed 18/18 after workspace ownership/recovery, missing build-phase,
  exact-byte declaration, manual-export, and UI-test archive-exclusion tests.
  Final log `/private/tmp/intentlab-installer-tests-archive-flag.log` (the
  initial sandboxed attempt could not write SwiftPM's external Clang cache;
  the approved cache-access rerun passed). The generated-project
  preview returns manual integration guidance; automatic removal is not
  implemented and the removal preview lists exact manual review paths.
  Both installer-produced temporary consumer projects (existing UI-test target
  and dedicated new target) passed generic iOS Simulator `xcodebuild
  build-for-testing` with signing disabled. Logs:
  `/private/tmp/intentlab-installer-existing-build.log` and
  `/private/tmp/intentlab-installer-dedicated-build.log`. They are compilation
  proofs, not executed UI tests.
- Host report CLI gate: `python3 -m unittest -v script.tests.test_intent_lab_cli`
  passed after a loopback-enabled retry. The default sandbox denied local
  socket binding before the test ran. The mocked failed host report exits
  nonzero even when XCTest capture itself supplied no failed test result.
  This is a gate contract test, not a physical device demonstration.

## Acceptance and limits

- Verified in tests: v1 frozen meaning and latest-version restoration; v2
  execution/return/state distinction; direct Basic and Behaviour capture;
  post-action persistence read-back; deliberate suppressed save, unrelated
  mutation, wrong expectation, and stale/unbound context rejection; strict
  failed-outcome release policy; installer preview/apply/recovery/repair and
  compile of both automatic target paths; a clean outside-repository task
  consumer with only package/test integration and app-owned support in its diff.
- Verified in the live Mac interface: Setup/manual fallback and Basic coverage
  editing. The actual UI did not run or import a device scenario report.
- Unverified: physical direct and Siri routes for either app, Mac Run control
  with a signed test product, and live device Results/MCP report parity and
  relaunch. Simulator tests, mock MCP tests, and source inspection do not
  substitute for those checks. Remote resolution was completed later, below.

## External validation status

The sandboxed `xcdevice` probe initially returned no device. An approved
unsandboxed `xcrun xcdevice list --timeout 5 --json` check later found one
available physical iPhone. Its identifier is intentionally excluded here.
Compiling alone has not verified direct or Siri behaviour on the physical
device. The signed notes v2 physical build stopped on missing app and UI-test
runner provisioning profiles (`/private/tmp/intentlab-notes-v2-signed-build.log`,
lines 63–65). Because neither test bundle could be installed, the Mac Run
control, physical query/Siri outcomes, and relaunch of their device reports
remain unverified.

The built Mac app was inspected in the actual interface on 2026-09-26:
Setup displays the installer and dedicated-target choice, a generated Xcode
project produces manual fallback with reviewable file export, and a new v2
check displays Basic/exploratory coverage accurately in the Evidence editor.
Changing the selected intent reset the read-only acknowledgement in the live
UI. The inspection did not run an intent or apply installer changes to a
user's project.

## Delivery verification on 2026-09-26

- The reviewed integration was ported onto PR #52's current remote head and
  committed as `2b02190da849585e41333110e20d383a0bcdd687` on
  `codex/intent-lab-reusable-integration`. The original dirty checkout was
  preserved. An independent review found that the Tasks example required
  its scheme's `IntentLabTesting` Test configuration rather than `Debug`.
  Scheme discovery, explicit overrides, and the Advanced UI were corrected.
  The focused host contract suite passed 50/50 afterward
  (`/private/tmp/intent-lab-port-host-test-after-config.log`). The focused
  scheme/legacy-configuration regressions passed 2/2, and the Notes v2 and
  Tasks unsigned generic Simulator test products built
  (`/private/tmp/intent-lab-port-notes-build.log`,
  `/private/tmp/intent-lab-port-tasks-build.log`). Xcode build settings for
  Tasks `IntentLabTesting` showed its isolated `.integration-tests` app ID and
  `INTENT_LAB_TESTING` compilation condition. The rebuilt Mac UI visibly
  displayed the build-configuration field and reapproval guidance; the app
  was closed after inspection.
- Remote package availability is verified. With local Git URL rewrites and
  system Git configuration disabled, HTTPS `ls-remote` returned that commit.
  A fresh outside-repository Xcode consumer fetched it from GitHub and pinned
  the exact SHA in both its project and `Package.resolved`.
  `/private/tmp/IntentLabRemoteResolve.log` records the fetch and checkout;
  the checkout's HEAD matches the commit. Its generic iOS Simulator
  `build-for-testing` passed with signing disabled
  (`/private/tmp/IntentLabRemoteConsumerBuild.log`). The first build attempt
  was blocked by sandbox access to Swift/Clang caches; the approved
  cache-access rerun passed. This proves remote resolution and compilation,
  not device execution.
- The Mac Results view showed an existing failed run and its release rejection
  again after relaunch. The local MCP connector was stopped and not installed,
  so live Results/MCP parity was not checked. Connecting it would install a
  persistent Codex connector with access to saved evaluations; approval was
  requested before that access change.
- A paired physical iPhone is available. Existing signing assets do not form
  a complete pair for the Notes v2 or Tasks app and UI-test runner: one team
  has development certificates without the needed profiles, while Xcode's
  selected team lacks a development certificate and runner profiles. A
  proposed `-allowProvisioningUpdates` build was rejected by automatic
  approval review before execution because it could change Apple account
  signing assets. Explicit approval to create those assets was requested.
  No physical direct/Siri run, signed Mac Run, or live device report is
  claimed until that prerequisite is resolved and actually tested.

## Follow-up validation on 2026-09-26

- The user approved automatic development provisioning. With a per-command
  `DEVELOPMENT_TEAM` override and `-allowProvisioningUpdates`, signed physical
  `build-for-testing` completed for Notes v2 and Tasks, without editing project
  signing settings (`/private/tmp/IntentLabSignedNotes3Z.log`,
  `/private/tmp/IntentLabSignedTasks3Z.log`). This verifies signing/building,
  not test execution.
- The clean outside-repository task consumer fetched published commit
  `2b02190da849585e41333110e20d383a0bcdd687` over HTTPS with local Git
  URL rewrites disabled. Its project and `Package.resolved` pinned that SHA,
  and generic Simulator `build-for-testing` passed
  (`/private/tmp/IntentLabRemoteResolve.log`,
  `/private/tmp/IntentLabRemoteConsumerBuild.log`).
- The user approved connecting the local Intents MCP service. After backing up
  Codex's configuration, the duplicate unmanaged loopback entry was replaced
  by the app's managed connector. For existing failed run
  `C35E76B5-C392-4317-BF7A-7A01D1B770D2`, the live `scenario-report` CLI
  returned exit 30 and `incompleteOrIncompatibleEvidence` with five release
  failures. Results showed the same outcome and failures before and after an
  app relaunch. This establishes persisted report parity for that failed run;
  it is not evidence of a new physical device result.
- The host now accepts explicit per-run signing overrides for discovery,
  connection checks, and Mac Run. Focused host contracts passed 52/52
  (`/private/tmp/IntentLabSigningOverrideHostTests.log`). In the actual Mac UI,
  the saved Notes v2 scenario selected the reviewed declaration and a paired
  iPhone. Its approved support check signed and built successfully
  (`/private/tmp/IntentLabPhysicalVerification/IntentLab/Executor/Connection-D4B6A69C-F6F4-472E-9F39-2037EC2FE123/xcodebuild.log`). Physical
  `test-without-building` then waited at Xcode destination preflight with
  `Unlock iPhone to Continue`; the device owner was asked to unlock it. The
  support receipt and direct/Siri run remain pending at this checkpoint.
