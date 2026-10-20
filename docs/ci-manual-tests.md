# Manual test qualifications

Automatic CI excludes methods whose required fixture, profile, model assets, or activation is absent from that worker. These methods remain available for explicit qualification. Some could run on hosted machines after their prerequisites are provisioned; exclusion does not classify them as inherently impossible.

Ordinary methods in the same suites remain selected. The SDK-selected worker still runs the installer integration, and the regression worker’s input-conversion step still runs its live calibration.

## Swift package methods

Configure the prerequisites required by the linked source, then use `swift test --filter` with the exact identifier below. The ordinary CI wrapper excludes these methods before execution.

| Identifier | Required activation | Qualification |
|---|---|---|
| [IntentsAutomationCoreTests.AutomationAppleFileDeclarationBuildTests/testActualFileDeclarationsBuildWithoutRuntimeWhenRequested](../Tests/IntentsAutomationCoreTests/AutomationAppleFileDeclarationBuildTests.swift#L61) | `INTENTS_APPLE_FILE_DECLARATION_BUILD`, `INTENTS_APPLE_FILE_DECLARATION_ROOT` | Authored IntentFile declaration build-only check is opt-in |
| [IntentsAutomationCoreTests.AutomationFreshWorkflowLiveTests/testApprovedFreshDuplicateRecordsThroughProductionRunner](../Tests/IntentsAutomationCoreTests/AutomationFreshWorkflowLiveTests.swift#L10) | `INTENTS_FRESH_WORKFLOW_LIVE_PROFILE`, `INTENTS_FRESH_WORKFLOW_HOST_TEMPLATES` | Requires the approved disposable fixture/simulator profile and generated-host template directory |
| [IntentsAutomationCoreTests.AutomationIntakeBreadthTests/testActualOwnedServerDisposalAfterOperationFailureAndWrongBytes](../Tests/IntentsAutomationCoreTests/AutomationIntakeBreadthTests.swift#L140) | `INTENTS_SERVED_JS_LIVE`, `INTENTS_SERVED_JS_NODE` | Opt-in sealed Node 24 supervision qualification; no app launch or native-consumption claim |
| [IntentsAutomationCoreTests.AutomationMacGUIIdentityTests/testCurrentSessionReadOnlyOptIn](../Tests/IntentsAutomationCoreTests/AutomationMacGUIIdentityTests.swift#L45) | `INTENTS_MAC_GUI_IDENTITY_PROBE` | Read-only current GUI identity opt-in |
| [IntentsAutomationCoreTests.AutomationMacHostPreparationTests/testExplicitActualMacPreparationBuildsWithoutLaunching](../Tests/IntentsAutomationCoreTests/AutomationMacHostPreparationTests.swift#L190) | `INTENTS_MAC_HOST_SOURCE`, `INTENTS_MAC_HOST_PREPARATION_ROOT` | Opt in to an owned build-only Mac fixture; no app or intent is launched |
| [IntentsAutomationCoreTests.AutomationMacHostPreparationTests/testExplicitIntegerEntityPreparationBuildsAndCapturesMetadataWithoutLaunching](../Tests/IntentsAutomationCoreTests/AutomationMacHostPreparationTests.swift#L166) | `INTENTS_ENTITY_INTEGER_SOURCE`, `INTENTS_ENTITY_INTEGER_ROOT` | Opt in to the controlled integer-entity SDK fixture; no app or intent is launched |
| [IntentsAutomationCoreTests.AutomationMacHostPreparationTests/testExplicitStopDuringSyntaxPreparationCannotFallBackIntoBuilding](../Tests/IntentsAutomationCoreTests/AutomationMacHostPreparationTests.swift#L137) | `INTENTS_MAC_HOST_SOURCE`, `INTENTS_MAC_HOST_PREPARATION_ROOT` | Opt in to an owned cancellation fixture; no app or intent is launched |
| [IntentsAutomationCoreTests.AutomationMacInputProbeFixtureTests/testAuthoredInputProbeFixtureWhenRequested](../Tests/IntentsAutomationCoreTests/AutomationMacInputProbeFixtureTests.swift#L60) | `INTENTS_MAC_INPUT_PROBE_FIXTURE_LIVE`, `INTENTS_MAC_INPUT_PROBE_FIXTURE_BUILD` | Authored input probe build/live calibration is opt-in; retained in dedicated `input-conversion` CI |
| [IntentsAutomationCoreTests.AutomationMacPackagePlatformFixtureTests/testActualLiteralPlatformPackageBuildWithoutLaunchingWhenRequested](../Tests/IntentsAutomationCoreTests/AutomationMacPackagePlatformFixtureTests.swift#L55) | `INTENTS_MAC_PACKAGE_PLATFORM_BUILD`, `INTENTS_MAC_PACKAGE_PLATFORM_ROOT` | Authored local-package platform build-only check is opt-in |
| [IntentsAutomationCoreTests.AutomationMacProductionHostTests/testProductionMacHostExecutesAndReleasesTwiceWhenRequested](../Tests/IntentsAutomationCoreTests/AutomationMacProductionHostTests.swift#L7) | `INTENTS_MAC_PRODUCTION_HOST_LIVE` | Owned disposable Mac host execution is opt-in |
| [IntentsAutomationCoreTests.AutomationMacSourceIntegrityBuildTests/testBuildMutationCannotProducePreparedCatalogWhenRequested](../Tests/IntentsAutomationCoreTests/AutomationMacSourceIntegrityBuildTests.swift#L7) | `INTENTS_MAC_SOURCE_INTEGRITY_BUILD`, `INTENTS_MAC_SOURCE_INTEGRITY_ROOT` | Authored private-source mutation build-only check is opt-in |
| [IntentsAutomationCoreTests.AutomationMultiRootPreparationTests/testActualGrantedLocalPackageClosureBuildsAndReloadsWithoutRuntimeWhenRequested](../Tests/IntentsAutomationCoreTests/AutomationMultiRootPreparationTests.swift#L59) | `INTENTS_MULTI_ROOT_BUILD`, `INTENTS_MULTI_ROOT_ROOT` | Authored explicit additional-root SDK build-only check is opt-in |
| [IntentsAutomationCoreTests.AutomationPhysicalReadOnlyTests/testOfficialInventoryChildrenAreDurablyTrackedAndDrained](../Tests/IntentsAutomationCoreTests/AutomationPhysicalReadOnlyTests.swift#L8) | `INTENTS_READ_ONLY_PHYSICAL_TARGET` | Requires an explicitly selected connected physical device for read-only inspection |
| [IntentsAutomationCoreTests.AutomationProcessTests/testActualOwnedSimulatorInventoryDrainsBothPipes](../Tests/IntentsAutomationCoreTests/AutomationProcessTests.swift#L188) | `INTENTS_AUTOMATION_INVENTORY_TEST_TARGET` | No explicit owned simulator command profile |
| [IntentsAutomationCoreTests.AutomationReleaseTests/testActualOwnedSimulatorRetainedRunnerCannotBeReportedReleased](../Tests/IntentsAutomationCoreTests/AutomationReleaseTests.swift#L13) | `INTENTS_AUTOMATION_RELEASE_TEST_TARGET` | No explicit owned simulator inventory profile |
| [IntentsAutomationCoreTests.AutomationRepositoryCheckoutTests/testActualPublicHTTPSFetchRetainsRevision](../Tests/IntentsAutomationCoreTests/AutomationRepositoryCheckoutTests.swift#L7) | `INTENTS_REPOSITORY_FETCH_LIVE` | Opt-in public HTTPS source fetch |
| [IntentsAutomationCoreTests.AutomationRepositoryIntakeTests/testActualRepositoryFolderFindsAppWithoutProjectChangesWhenRequested](../Tests/IntentsAutomationCoreTests/AutomationRepositoryIntakeTests.swift#L117) | `INTENTS_INTAKE_REPOSITORY` | No explicit repository intake profile |
| [IntentsAutomationCoreTests.AutomationSourcePlatformPredicateBuildTests/testActualSelectedMacPlatformBranchesReconcileWithoutRuntimeWhenRequested](../Tests/IntentsAutomationCoreTests/AutomationSourcePlatformPredicateBuildTests.swift#L7) | `INTENTS_SOURCE_PLATFORM_BUILD`, `INTENTS_SOURCE_PLATFORM_ROOT` | Authored platform-condition build-only qualification is opt-in |
| [IntentsAutomationCoreTests.AutomationSourceRecipeTests/testActualPinnedXcodeGenGenerationPreservesSource](../Tests/IntentsAutomationCoreTests/AutomationSourceRecipeTests.swift#L96) | `INTENTS_SOURCE_RECIPE_LIVE` | Opt-in actual isolated generator qualification |
| [IntentsAutomationCoreTests.AutomationSourceRecipeTests/testActualSwiftPMPackagingAndWriteIsolation](../Tests/IntentsAutomationCoreTests/AutomationSourceRecipeTests.swift#L121) | `INTENTS_SOURCE_RECIPE_LIVE` | Opt-in actual SwiftPM app packaging qualification |
| [IntentsAutomationCoreTests.AutomationSourceSyntaxTests/testActualSelectedXcodeParserHandlesExtensionsNestedTypesAndLiteralBodies](../Tests/IntentsAutomationCoreTests/AutomationSourceSyntaxTests.swift#L97) | `INTENTS_SOURCE_SYNTAX_TEST` | Explicit local Xcode source-scanner qualification |
| [IntentsAutomationCoreTests.AutomationSynchronizedSourceBuildTests/testActualSynchronizedSwiftMembershipBuildsAndReloadsWithoutRuntimeWhenRequested](../Tests/IntentsAutomationCoreTests/AutomationSynchronizedSourceBuildTests.swift#L7) | `INTENTS_SYNC_SOURCE_BUILD`, `INTENTS_SYNC_SOURCE_ROOT` | Authored synchronized-folder SDK build-only check is opt-in |
| [IntentsAutomationCoreTests.AutomationWorkspaceBuildContextTests/testActualWorkspaceBuildAndRetainedReloadWhenRequested](../Tests/IntentsAutomationCoreTests/AutomationWorkspaceBuildContextTests.swift#L59) | `INTENTS_WORKSPACE_BUILD` | Opt-in Xcode build, without launching the subject |

## Native app methods

Use the project’s normal Xcode test command with `-only-testing:<identifier>` after supplying the required input. Other methods in both suites stay in automatic native coverage.

| Identifier | Required input | CI treatment |
|---|---|---|
| `FoundationEvalsTests/CoreAIModelLoaderTests/configuredResourcesLoadAndGenerate()` | `FOUNDATION_EVALS_COREAI_TEST_RESOURCES` | Requires external Core AI LanguageBundle; no workflow provisions it. |
| `FoundationEvalsTests/IntentLabProjectInstallerTests/generatedMacUITestTargetBuildsWithXcode()` | `INTENT_LAB_RUN_MAC_INSTALLER_BUILD_TEST` | Exclude native duplicate; shared Swift SDK-selected lane provisions XcodeGen, the immutable remote revision and a receipt for both public products. |

## Live app UI methods

Follow the [app automation fixture setup](wiki/App-automation.md) before using these exact Xcode selectors. Each requires `INTENTS_AUTOMATION_LIVE_UI=1` and the staged generated fixture described there. The two simulator cases additionally require `INTENTS_AUTOMATION_SIMULATOR_UUID` for an owned simulator. These selectors stay excluded from automatic CI even when their source files change.

- `FoundationEvalsUITests/FreshRecordAutomationUITests/testFreshDuplicateRecordsPreserveTheOtherOwner` — owned simulator required.
- `FoundationEvalsUITests/MacPreparationUITests/testSelectedToolchainPreparesMacCopyAndRunsApprovedWorkflows` — selected Xcode and staged Mac fixture.
- `FoundationEvalsUITests/AppAutomationUITests/testPreparedPureEchoShowsUnassessedNativeEvidence` — owned simulator required.

## End-to-end automation

Prepared simulator and signed Mac acceptance are excluded from GitHub CI, including
PR, main, scheduled, and manually dispatched runs. The blocking simulator inventory
and app-launch checks can stall locally as well. Core app UI and regression checks
remain automatic; a passing CI run does not qualify live device automation.

For an explicit qualification run, use the [simulator fixture instructions](wiki/App-automation.md)
or [signed Mac workflow instructions](wiki/Mac-workflows.md). The standalone
`script/automation_e2e.py` and `script/automation_mac_e2e.py` harnesses retain their
scenario assertions, codec comparisons, and resource-release checks. They are
not prerequisites for merging a PR. The MacPreparation app UI fixture also stays
manual while its App Intents metadata admission fails with error 400.
