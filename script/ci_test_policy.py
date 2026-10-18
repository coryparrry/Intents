"""Explicit runtime opt-ins omitted by ordinary CI dispatch, retained for manual runs."""

# Xcode Swift Testing exclusions require the complete function signature.
NATIVE_MANUAL_METHODS = frozenset({
    "FoundationEvalsTests/CoreAIModelLoaderTests/configuredResourcesLoadAndGenerate()",
    "FoundationEvalsTests/IntentLabProjectInstallerTests/generatedMacUITestTargetBuildsWithXcode()",
})

# The input-probe method has its own provisioned CI job, outside this dispatcher.
SWIFT_MANUAL_METHODS = frozenset({
    "AutomationAppleFileDeclarationBuildTests/testActualFileDeclarationsBuildWithoutRuntimeWhenRequested",
    "AutomationAppleNestedArrayBuildTests/testSelectedToolchainRejectsAuthoredNestedArrayMetadataWhenRequested",
    "AutomationFreshWorkflowLiveTests/testApprovedFreshDuplicateRecordsThroughProductionRunner",
    "AutomationIntakeBreadthTests/testActualOwnedServerDisposalAfterOperationFailureAndWrongBytes",
    "AutomationMacGUIIdentityTests/testCurrentSessionReadOnlyOptIn",
    "AutomationMacHostPreparationTests/testExplicitActualMacPreparationBuildsWithoutLaunching",
    "AutomationMacHostPreparationTests/testExplicitIntegerEntityPreparationBuildsAndCapturesMetadataWithoutLaunching",
    "AutomationMacHostPreparationTests/testExplicitStopDuringSyntaxPreparationCannotFallBackIntoBuilding",
    "AutomationMacInputProbeFixtureTests/testAuthoredInputProbeFixtureWhenRequested",
    "AutomationMacPackagePlatformFixtureTests/testActualLiteralPlatformPackageBuildWithoutLaunchingWhenRequested",
    "AutomationMacProductionHostTests/testProductionMacHostExecutesAndReleasesTwiceWhenRequested",
    "AutomationMacSourceIntegrityBuildTests/testBuildMutationCannotProducePreparedCatalogWhenRequested",
    "AutomationMultiRootPreparationTests/testActualGrantedLocalPackageClosureBuildsAndReloadsWithoutRuntimeWhenRequested",
    "AutomationPhysicalDeviceInventoryTests/testActualReadOnlyXcodeInventoryWhenExplicitlyProvided",
    "AutomationPhysicalReadOnlyTests/testOfficialInventoryChildrenAreDurablyTrackedAndDrained",
    "AutomationProcessTests/testActualOwnedSimulatorInventoryDrainsBothPipes",
    "AutomationReleaseTests/testActualOwnedSimulatorRetainedRunnerCannotBeReportedReleased",
    "AutomationRepositoryCheckoutTests/testActualPublicHTTPSFetchRetainsRevision",
    "AutomationRepositoryIntakeTests/testActualRepositoryFolderFindsAppWithoutProjectChangesWhenRequested",
    "AutomationSourceGraphTests/testExplicitTrustedLocalPackageBuildFixtureMatchesRetainedGraph",
    "AutomationSourcePlatformPredicateBuildTests/testActualSelectedMacPlatformBranchesReconcileWithoutRuntimeWhenRequested",
    "AutomationSourceRecipeTests/testActualPinnedXcodeGenGenerationPreservesSource",
    "AutomationSourceRecipeTests/testActualSwiftPMPackagingAndWriteIsolation",
    "AutomationSourceSyntaxTests/testActualSelectedXcodeParserHandlesExtensionsNestedTypesAndLiteralBodies",
    "AutomationSynchronizedSourceBuildTests/testActualSynchronizedSwiftMembershipBuildsAndReloadsWithoutRuntimeWhenRequested",
    "AutomationWorkspaceBuildContextTests/testActualWorkspaceBuildAndRetainedReloadWhenRequested",
})

INSTALLER_METHOD = "IntentLabProjectInstallerTests/generatedMacUITestTargetBuildsWithXcode"


def swift_manual_methods(include_installer=False):
    return SWIFT_MANUAL_METHODS if include_installer else SWIFT_MANUAL_METHODS | {INSTALLER_METHOD}
