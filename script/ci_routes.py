"""Select builds and test suites from the complete diff; uncertainty runs everything."""

import json
import os
import re
import subprocess
from pathlib import Path

try:
    from ci_native_routes import declared_suites, select_native_tests
except ModuleNotFoundError:
    from script.ci_native_routes import declared_suites, select_native_tests

ROOT = Path(__file__).resolve().parents[1]
APP = "FoundationEvals/FoundationEvals/"
TESTS = "FoundationEvals/FoundationEvalsTests/"
UI_TESTS = "FoundationEvals/FoundationEvalsUITests/"
UI_TARGET = "FoundationEvalsUITests/"
PRODUCTION_PACKAGE = "Packages/ProductionEvals/"
PRODUCTION_DEVELOPER_SUITES = {
    "DeveloperProtocolTests", "DeveloperFeatureRegistryTests", "DeveloperRunnerHostEngineTests",
}
STANDALONE_PLUGIN_METADATA = {
    ".github/workflows/plugin.yml", ".agents/plugins/marketplace.json",
}
# Keep the existing PR baseline, including the picker once, across independent desktops.
UI_BASELINE = {
    "suite-editor": [UI_TARGET + "FoundationEvalsUITests"],
    "intent-lab": [UI_TARGET + "IntentLabGuidanceUITests", UI_TARGET + "SimplificationUITests",
                   UI_TARGET + "IntentLabFeatureGateUITests"],
    "runs": [UI_TARGET + "FoundationEvalsRunLifecycleUITests/testRunProgressCompletionAndHistoryRestoration"],
    "traces": [UI_TARGET + "WorkflowTraceUITests/testWorkspaceResetConfirmationAndPersistence"],
    "automation": [
        UI_TARGET + "AppAutomationUITests/" + method for method in (
            "testUnpreparedPhysicalSiriFormKeepsSubmissionDisabled",
            "testXcodeDefaultsFollowDestinationAndRestoreWithoutRunOverride",
            "testEmptyAutomationAndPickerCancellationRemainReadOnly",
            "testOwnershipResetConfirmationCanBeCancelledWithoutChangingTheReservation",
            "testPreparationPickersUseStableIdentifiers",
        )
    ] + [UI_TARGET + "AutomationDependencyControlsUITests"],
}
# Feature ownership follows the view composition and store consumers. Shared
# lifecycle, navigation, persistence and unknown app files retain the full baseline.
UI_VIEW_GROUPS = {
    **{"Views/" + name + ".swift": {"intent-lab"} for name in (
        "IntentLabView", "IntentLabHelp", "IntentLabSetupInstallerView",
        "ScenarioEditorView", "ScenarioGuidedCheckEditor", "ScenarioReportView",
        "ScenarioCollectionView", "ScenarioReusableChecksView", "AppleTestConnectionView",
    )},
    **{"Views/" + name + ".swift": {"suite-editor", "runs"} for name in (
        "SuiteCasesView", "SuiteEditorView", "SuiteEditorChrome", "SuiteRunControls",
        "FieldAssertionsEditor", "EvaluationSchemaEditor",
    )},
    **{"Views/" + name + ".swift": {"traces"} for name in (
        "WorkflowTraceView", "WorkflowSpanDetail", "WorkspaceTracesView",
    )},
    **{"Views/" + name + ".swift": {"automation"} for name in (
        "AppAutomationView", "AppAutomationCapsuleView", "AppAutomationDateInput",
        "AutomationSourceRecipeControls", "AutomationSiriControls",
        "AutomationSiriSearchControls", "AutomationRecoveryControls",
        "AutomationFirstRunControls", "AutomationPairedFeatureControls",
        "AutomationSavedSearchesSection", "AutomationSourcePreparationControls",
        "NativeAutomationEvidenceView",
    )},
}
# These views share feature-specific state, rather than the whole workspace.
UI_VIEW_GROUPS.update({
    **{"Views/" + name + ".swift": {"suite-editor"} for name in (
        "ModelControlsSection", "ModelCustomizationSection", "CoreAIModelControls",
        "CustomProviderControls", "FeatureControlsView", "FeatureConfigurationSummary",
        "ConversationConfigurationEditor", "JudgeConfigurationSection", "VisionToolControls",
        "SpotlightSearchToolEditor", "PromptTextEditor",
    )},
    **{"Views/" + name + ".swift": {"runs"} for name in (
        "SuiteResultsView", "RunReportSummary", "RunSummaryDashboard", "SuiteDashboardCards",
        "SuiteExperimentsView", "DeveloperRunPresentation", "DeveloperDevicesView",
    )},
    "Views/RunDetailView.swift": {"runs", "traces", "review"},
    "Views/RunAnalysisSection.swift": {"runs", "traces"},
    **{"Views/" + name + ".swift": {"traces"} for name in (
        "RunWorkflowPanel", "SampleTraceSection", "FeatureTraceSection", "ConversationTraceSection",
        "SpotlightSearchTraceView", "JudgeEvidenceSection", "RefusalExplanationView",
        "LiveResponseSection", "ProductionReviewPane",
    )},
    **{"Views/" + name + ".swift": {"review"} for name in (
        "SuiteReviewView", "ReviewSampleEditor", "ReviewOutputView", "ReviewPatternsPane",
        "ReviewJudgeChecksPane", "TranscriptFeedbackSection",
    )},
    **{"Views/" + name + ".swift": {"settings"} for name in (
        "AppSettingsView", "MCPSettingsView", "JudgeConnectionsSettingsView", "TelemetrySettingsView",
    )},
    "Views/CaseImportView.swift": {"imports"},
})
UI_APP_GROUPS = {
    **UI_VIEW_GROUPS,
    "Services/EvaluationWorkspacePersistence.swift": None,
    "Services/WorkspaceOverviewLoader.swift": None,
    "Services/EvaluationAppControl.swift": None,
    "Services/MCPWorkspaceControl.swift": None,
    "Services/MCPStoreAuthority.swift": None,
    **{"Models/" + name + ".swift": {"suite-editor"} for name in (
        "EvaluationFeatureConfiguration", "EvaluationCoreAIConfiguration",
        "EvaluationModelCustomization", "EvaluationVisionToolConfiguration", "EvaluationSpotlightConfiguration",
    )},
    "Models/EvaluationConversation.swift": {"suite-editor", "traces"},
    **{"Models/" + name + ".swift": {"traces"} for name in (
        "WorkflowTimelineInterval", "WorkflowTracePresentation", "EvaluationWorkflowTrace",
        "EvaluationBuiltinToolTrace", "EvaluationJudgeTrace", "EvaluationRefusalTrace", "EvaluationLiveResponse",
    )},
    "Models/EvaluationTranscriptTrace.swift": {"traces", "review"},
    "Models/EvaluationRunAnalysis.swift": {"runs", "traces"},
    "Models/DevelopmentWorkflowModels.swift": {"runs"},
    **{"Models/" + name + ".swift": {"intent-lab"} for name in (
        "ScenarioModels", "ScenarioExecutionModels", "ScenarioCollectionModels",
    )},
    **{path: {"review"} for path in (
        "Models/EvaluationReviewModels.swift", "Models/EvaluationJudgeCalibration.swift",
        "Stores/EvaluationStore+Review.swift", "Stores/EvaluationReviewDraftStore.swift",
        "Services/EvaluationReviewWorkflow.swift",
    )},
    "Stores/DeveloperRunnerStore.swift": {"runs", "suite-editor"},
    "Services/ScenarioCoordinator.swift": {"intent-lab"},
    "Services/ScenarioPersistence.swift": {"intent-lab"},
    "Services/MetricScorer.swift": {"runs"},
    "MCP/Installer/MCPSettingsController.swift": {"settings"},
    "Services/TelemetryController.swift": {"settings"},
    "Services/IntentLabFeatureGate.swift": {"intent-lab"},
    "Views/Components/RunToolbarProgress.swift": {"runs"},
    "Views/Components/SolidTimelineBar.swift": {"traces"},
    # Batch workspace has native tests but no dedicated authored UI test class.
    **{path: set() for path in (
        "Views/ProductionWorkspaceView.swift", "Views/ProductionWorkspaceSheets.swift",
        "Views/ProductionReportPane.swift", "Stores/ProductionWorkspaceStore.swift",
    )},
}
# FoundationEvalsUITests spans two features and the app menu. Keep its broad class
# in the full baseline, but select only its relevant methods on isolated changes.
UI_FEATURE_TESTS = {
    "suite-editor": [UI_TARGET + "FoundationEvalsUITests/" + method for method in (
        "testRunCommandsMatchInvalidSuiteControls", "testSuiteEditorShowsPrimaryRunControls",
        "testCaseSelectionSurvivesSetupNavigation", "testSameNamedCasesHaveDistinctAccessibilityLabels",
        "testCaseSearchKeepsEditorAndScoringSelectionAligned",
    )],
    "intent-lab": UI_BASELINE["intent-lab"] + [UI_TARGET + "FoundationEvalsUITests/" + method for method in (
        "testIntentLabResultsAndRunControlsFitMinimumWindow", "testDuplicateParameterDraftsRemoveOneAtATime",
    )],
    "settings": [UI_TARGET + "WorkspacePolishUITests/testSettingsTabsKeepTheirPrimaryControlsAccessible"],
    "imports": [UI_TARGET + "WorkspacePolishUITests/testImportIssuesKeepCancelAndImportVisible"],
    "review": [UI_TARGET + "EvaluationReviewUITests"],
}
ALL_UI_GROUPS = set(UI_BASELINE) | set(UI_FEATURE_TESTS)


def app_ui_groups(relative):
    if relative in UI_APP_GROUPS:
        return UI_APP_GROUPS[relative]
    if relative == "Services/EvaluationRunner.swift" or relative.startswith("Services/EvaluationRunner+"):
        return {"runs"}
    if relative.startswith(("Stores/AppAutomation", "Stores/AutomationNative")) or relative in {
        "Stores/AutomationCommandHistory.swift", "Stores/AutomationCapsuleExportSelection.swift",
    }:
        return {"automation"}
    # Service-only changes still receive native unit tests, without unrelated UI.
    if relative.startswith(("Services/", "MCP/", "Support/Telemetry")):
        return set()
    return None

UI_FEATURE_CLASSES = {
    "intent-lab": {"IntentLabArrayEntryUITests", "IntentLabFeatureGateUITests"},
    "runs": {"FoundationEvalsRunLifecycleUITests"},
    "traces": {"WorkflowTraceUITests"},
    "automation": {"AppAutomationUITests"},
    "review": {"EvaluationReviewUITests"},
}
NATIVE_UI_HELPERS = {
    "script/ci_native_tests.py": "script.tests.test_ci_native_tests",
    "script/ci_ui_display.py": "script.tests.test_ci_ui_display",
    "script/ci_ui_xctestrun.py": "script.tests.test_ci_ui_xctestrun",
}


# Include shared dependencies, not just the file named after a suite.
PHYSICAL_SCENARIO_SUITES = {
    "ScenarioPhysicalLeaseTests",
    "ScenarioPhysicalFailureTests",
}
SCENARIO_EXECUTION_SUITES = {"ScenarioContractsTests"} | PHYSICAL_SCENARIO_SUITES
SWIFT_DEPENDENCIES = {
    "Services/IntentLabFeatureGate.swift": {"IntentLabFeatureGateTests"},
    "MCP/Installer/CodexMCPInstaller.swift": {"CodexMCPInstallerTests"},
    "Models/EvaluationFieldAssertion.swift": {"EvaluationFieldAssertionTests"},
    "Models/EvaluationScoringTypes.swift": {
        "EvaluationFieldAssertionTests",
        "MetricScorerTests",
    },
    "Models/ScenarioModels.swift": {
        "ScenarioContractsTests", "ScenarioActionParityTests", "ScenarioV3HarnessBridgeTests",
        *PHYSICAL_SCENARIO_SUITES, "ScenarioAutomationEvidenceTests", "XcodeBundleLayoutTests",
    },
    "Models/ScenarioExecutionModels.swift": {
        "ScenarioExecutionPlanTests", "ScenarioExecutionComparisonTests",
    },
    "Models/ScenarioCollectionModels.swift": {"ScenarioCollectionTests"},
    "Services/ScenarioComparison.swift": {"ScenarioContractsTests"},
    "Services/ScenarioExecutionComparison.swift": {"ScenarioExecutionComparisonTests"},
    "Services/ScenarioExecutionRecovery.swift": {"ScenarioContractsTests"},
    "Services/ScenarioExpectationAuthoring.swift": {
        "ScenarioExpectationAuthoringTests", "ScenarioV3HarnessBridgeTests",
    },
    "Services/ScenarioCollectionService.swift": {"ScenarioCollectionTests"},
    "Services/ScenarioCollectionStore.swift": {"ScenarioCollectionTests"},
    "Services/IntentEvidenceBundle.swift": {"IntentEvidenceBundleTests"},
    "Services/IntentEvidenceQualification.swift": {
        "IntentEvidenceBundleTests", "ScenarioActionParityTests",
    },
    "Services/ScenarioPersistence.swift": SCENARIO_EXECUTION_SUITES | {"ScenarioAutomationEvidenceTests"},
    "Services/ScenarioValidation.swift": {
        "ScenarioContractsTests", "ScenarioNoMutationTests", "ScenarioV3HarnessBridgeTests",
    },
    "Services/IntentLabProjectInstaller.swift": {"IntentLabProjectInstallerTests"},
    "Services/OpenStepProjectDocument.swift": {"IntentLabProjectInstallerTests"},
    "Services/XCTestEvidenceImporter.swift": {
        "ScenarioContractsTests", "ScenarioV3HarnessBridgeTests", *PHYSICAL_SCENARIO_SUITES,
    },
    "Services/XCTestRunInvocationTransport.swift": SCENARIO_EXECUTION_SUITES,
    "Services/XcodeConnectionDiscovery.swift": SCENARIO_EXECUTION_SUITES,
    "Services/XcodeTestExecutor.swift": {
        "ScenarioContractsTests", "ExecutorSimplificationTests", "XcodeBundleLayoutTests", "XcodeSyntheticReadinessTests", *PHYSICAL_SCENARIO_SUITES,
    },
    "Services/ScenarioPersistence+AutomationEvidence.swift": {"ScenarioAutomationEvidenceTests"},
    "Services/ScenarioPhysicalRunnerLease.swift": PHYSICAL_SCENARIO_SUITES,
    "Services/ScenarioRunnerReceiptImporter.swift": PHYSICAL_SCENARIO_SUITES,
    "Services/EvaluationFieldAssertions.swift": {"EvaluationFieldAssertionTests"},
    "Services/MetricScorer.swift": {"MetricScorerTests"},
    "Models/WorkflowTimelineInterval.swift": {
        "WorkflowTimelineIntervalTests",
        "TimelineRenderingTests",
    },
    "Views/Components/SidebarNavigationList.swift": {"NavigationInteractionTests"},
    "Views/Components/FullWidthDisclosureStyle.swift": {"NavigationInteractionTests"},
    "Views/Components/SolidTimelineBar.swift": {"TimelineRenderingTests"},
    "Views/Components/RunToolbarProgress.swift": {"RunToolbarProgressTests"},
}
SWIFT_SUITES = set().union(*SWIFT_DEPENDENCIES.values())
MACOS_TESTS = {
    "script.tests.test_update_signature",
    "script.tests.test_fixture_shortcut_routing",
}
RELEASE_VALIDATION = {
    "script.tests.test_release_validation",
    "script.tests.test_update_feed",
    "script.tests.test_release_dispatch",
}
PYTHON_DEPENDENCIES = {
    "script/upload_posthog_symbols.sh": {"script.tests.test_upload_posthog_symbols"},
    "script/update_homebrew.py": {"script.tests.test_update_homebrew"},
    ".github/workflows/update-homebrew.yml": {"script.tests.test_update_homebrew"},
    "script/check_fixture_shortcut_metadata.py": {"script.tests.test_fixture_shortcut_metadata"},
    "script/release_pr.py": {"script.tests.test_release_pr"},
    "script/release_notes.py": {"script.tests.test_release_notes"},
    ".github/workflows/pr-metadata.yml": {"script.tests.test_release_notes", "script.tests.test_ci_workflow"},
    "script/wait_release_ci.sh": {"script.tests.test_wait_release_ci"},
    "script/release_validation.py": RELEASE_VALIDATION,
    "script/release_dispatch.sh": RELEASE_VALIDATION,
    "script/verify_release_source.sh": RELEASE_VALIDATION,
    "script/verify_release.sh": RELEASE_VALIDATION,
    "script/release.sh": RELEASE_VALIDATION,
    "script/verify_installer.sh": RELEASE_VALIDATION,
    "script/ci_core_scheme.py": {"script.tests.test_ci_core_scheme"},
    "script/automation_e2e.py": {"script.tests.test_automation_e2e", "script.tests.test_ci_automation_build"},
    "script/ci_automation_build.py": {"script.tests.test_ci_automation_build", "script.tests.test_automation_e2e"},
    **{path: {module} for path, module in NATIVE_UI_HELPERS.items()},
    "release-please-config.json": {
        "script.tests.test_release_notes",
        "script.tests.test_release_pr",
        "script.tests.test_release_dispatch",
    },
    ".github/workflows/release-me.yml": {
        "script.tests.test_release_pr",
        "script.tests.test_release_dispatch",
        "script.tests.test_release_validation",
        "script.tests.test_wait_release_ci",
    },
    ".github/workflows/package-installer.yml": RELEASE_VALIDATION
    | {"script.tests.test_wait_release_ci", "script.tests.test_update_homebrew"},
    ".github/workflows/release.yml": RELEASE_VALIDATION,
}
FULL_COVERAGE_PATHS = {
    ".github/workflows/ci.yml",
    ".github/workflows/ui-stability.yml",
    "script/ci_routes.py",
    "script/ci_run_tests.py",
    "script/ci_native_cache.py",
    "script/tests/test_ci_routes.py",
    "script/tests/test_ci_run_tests.py",
    "script/tests/test_ci_native_cache.py",
    "script/ci_native_routes.py",
    "script/tests/test_ci_native_routes.py",
    "script/build_and_run.sh",
    "Package.swift",
    "Package.resolved",
    # A release candidate must still satisfy the installer's full source-CI gate.
    "version.txt",
    ".release-please-manifest.json",
}
METADATA_PATHS = {
    "README.md",
    "CHANGELOG.md",
    "LICENSE",
    ".gitignore",
    "worklog.md",
    "SECURITY.md",
    "CONTRIBUTING.md",
    "CODE_OF_CONDUCT.md",
    ".github/FUNDING.yml",
    ".github/CODEOWNERS",
    ".github/release-notes.md",
}


def python_test_inventory(root=ROOT):
    return {
        ".".join(path.relative_to(root).with_suffix("").parts)
        for path in (root / "script/tests").glob("test_*.py")
    } - MACOS_TESTS


def standalone_plugin_path(path):
    return path.startswith("plugins/apple-foundation-evals/") or path in STANDALONE_PLUGIN_METADATA


def production_package_runtime(path):
    if not path.startswith(PRODUCTION_PACKAGE):
        return False
    relative = path.removeprefix(PRODUCTION_PACKAGE)
    return not (
        relative.startswith(("Tests/", "docs/", "Documentation/"))
        or Path(relative).suffix.lower() in {".md", ".rst"}
        or Path(relative).name in {"LICENSE", "LICENSE.txt", "NOTICE"}
    )


def package_test_suites(path, root):
    source = root / path
    if not path.endswith(".swift") or not source.is_file():
        return {"*"}
    # Explicit test-suite declarations only; extension/helper/fixture edits select
    # the full package instead of guessing which suite consumes them.
    return declared_suites(source.read_text()) or {"*"}


def package_ui_groups(path):
    if path.startswith((
        "Sources/IntentsAutomationCore/", "Sources/IntentsAutomationTool/",
        "Integration/AutomationHost/", "Tools/IntentsAutomationApplicationProbe/",
        "examples/AutomationFixture/",
    )) or path == "Integration/AutomationCLIResources.swift":
        return {"automation"}
    if path.startswith("Sources/IntentLabContracts/"):
        return {"intent-lab", "automation"}
    if path.startswith(("Sources/IntentLabTesting/", "Sources/IntentLabCoreTesting/", "Sources/IntentLabSiriBridge/")):
        return {"intent-lab"}
    if path.startswith("Sources/FoundationEvalsDeveloper/"):
        return {"suite-editor", "runs"}
    if path.startswith(("Sources/IntentsEvidenceCLI/", "Sources/ProductionEvalsCLI/")):
        return set()
    return None


def ui_matrix(groups, extra_classes=(), targeted=False):
    catalog = {**UI_BASELINE, **UI_FEATURE_TESTS}
    selections = {
        name: set(catalog[name] if targeted or name not in UI_BASELINE else UI_BASELINE[name])
        for name in sorted(groups)
    }
    # New or edited test classes run in full, including methods outside the baseline.
    # A whole-class selector supersedes partial selectors everywhere, avoiding repeats.
    for suite in sorted(extra_classes):
        selector = UI_TARGET + suite
        owner = next((
            name for name, tests in UI_BASELINE.items()
            if any(test == selector or test.startswith(selector + "/") for test in tests)
        ), None)
        if owner is None:
            owner = next((name for name, classes in UI_FEATURE_CLASSES.items() if suite in classes),
                         "suite-editor")
        selections.setdefault(owner, set()).add(selector)
        for tests in selections.values():
            tests.difference_update(test for test in list(tests) if test.startswith(selector + "/"))
    # Three desktops bound runner demand while retaining every selected test.
    jobs = [{"groups": [], "tests": set()} for _ in range(min(3, len(selections)))]
    for name, tests in sorted(selections.items(), key=lambda item: (-len(item[1]), item[0])):
        if tests:
            target = min(jobs, key=lambda job: (len(job["tests"]), len(job["groups"])))
            target["groups"].append(name)
            target["tests"].update(tests)
    return sorted([
        {"name": "+".join(sorted(job["groups"])), "tests": sorted(job["tests"])}
        for job in jobs if job["tests"]
    ], key=lambda job: job["name"])


def changed_ui_classes(paths, root):
    classes = set()
    for path in paths or ():
        if path.startswith(UI_TESTS) and path.endswith(".swift") and (root / path).is_file():
            classes.update(re.findall(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b", (root / path).read_text()))
    return classes


def with_matrices(plan, groups=(), extra_classes=(), targeted=False):
    plan["ui_matrix"] = ui_matrix(groups, extra_classes, targeted) if plan["ui"] else []
    return plan


def full_coverage(reason, root=ROOT, extra_classes=(), extra_groups=()):
    return with_matrices({
        "full_coverage": True,
        "native": True,
        "ui": True,
        "automation_e2e": True,
        "input_conversion": True,
        "swift_suites": ["*"],
        "python_tests": sorted(python_test_inventory(root)),
        "macos_tests": sorted(MACOS_TESTS),
        "reasons": [reason],
    }, ALL_UI_GROUPS | set(extra_groups), extra_classes)


def coverage_plan(paths, root=ROOT):
    extra_classes = changed_ui_classes(paths, root)
    affected_groups = set()
    # Gather affected feature classes before any full-coverage early return.
    for path in paths or ():
        groups = app_ui_groups(path.removeprefix(APP)) if path.startswith(APP) else package_ui_groups(path)
        affected_groups.update(groups or ())
        for group in groups or ():
            extra_classes.update(UI_FEATURE_CLASSES.get(group, ()))
    if paths is None:
        return full_coverage(
            "Full coverage: unsupported event, malformed payload, or unavailable Git history.",
            root,
        )
    native = ui = automation_e2e = input_conversion = False
    ui_groups, ui_fallback = set(), False
    swift, python, macos, reasons = set(), set(), set(), set()
    for path in paths:
        automation_e2e |= not path.startswith("Integration/AutomationHost/NativeMac/") and path.startswith((
            "Sources/IntentsAutomationCore/", "Sources/IntentsAutomationTool/",
            "Integration/AutomationHost/", "examples/AutomationFixture/",
            "Tools/IntentsAutomationApplicationProbe/",
        )) or path in {"script/automation_e2e.py", "script/ci_automation_build.py", "script/tests/test_automation_e2e.py"}
        input_conversion |= path.startswith((
            "Sources/IntentsAutomationCore/", "Integration/AutomationHost/",
        )) or path in {
            "Tests/IntentsAutomationCoreTests/AutomationMacInputProbeFixtureTests.swift",
        }
        if path in FULL_COVERAGE_PATHS:
            return full_coverage(
                f"Full coverage: {path} changes CI, dependencies, or the release candidate.",
                root, extra_classes, affected_groups,
            )
        if path in PYTHON_DEPENDENCIES:
            python.update(PYTHON_DEPENDENCIES[path])
            if path in {"script/release.sh", "script/verify_installer.sh"}:
                macos.update(MACOS_TESTS)
            if path == "script/ci_core_scheme.py":
                native = True
            if path in NATIVE_UI_HELPERS:
                native = ui = ui_fallback = True
            reasons.add("Release/tooling changes select their dependent script tests.")
        elif path == "script/verify_update_signature.swift":
            macos.add("script.tests.test_update_signature")
            reasons.add(
                "Signature verification runs on macOS, where CryptoKit is available."
            )
        elif path.startswith("script/tests/test_") and path.endswith(".py"):
            module = path.removesuffix(".py").replace("/", ".")
            if not (root / path).is_file():
                python.update(python_test_inventory(root))
                macos.update(MACOS_TESTS)
                reasons.add(
                    "A removed script test selects the remaining script suites."
                )
            elif module in MACOS_TESTS:
                macos.add(module)
            else:
                python.add(module)
            if module == "script.tests.test_ci_core_scheme":
                native = True
            if module in NATIVE_UI_HELPERS.values():
                native = ui = ui_fallback = True
            reasons.add("Test-only changes select the changed suites.")
        elif standalone_plugin_path(path):
            reasons.add(
                "Standalone plugin changes use the dedicated plugin workflow for Node, native-engine, protocol and package coverage."
            )
        elif path.startswith(PRODUCTION_PACKAGE):
            if production_package_runtime(path):
                native = True
                swift.update(PRODUCTION_DEVELOPER_SUITES)
                reasons.add(
                    "Production package code builds its native consumers and Developer bridge; its dedicated workflow runs package and worker-protocol tests."
                )
            else:
                reasons.add(
                    "Production package tests and documentation use the dedicated production-evals workflow without unrelated root runtime checks."
                )
        elif path.startswith("Tests/"):
            swift.update(package_test_suites(path, root))
            reasons.add("Package test changes select declared suites; helper and fixture changes select the full package.")
        elif package_ui_groups(path) is not None:
            groups = package_ui_groups(path)
            swift.add("*")
            if groups:
                native = ui = True
                ui_groups.update(groups)
            if path.startswith("Sources/IntentLabContracts/"):
                automation_e2e = input_conversion = True
            if path == "Integration/AutomationCLIResources.swift":
                automation_e2e = input_conversion = True
            reasons.add("Package source changes run portable contracts and only the owning app feature's UI.")
        elif path.startswith(APP):
            native = True
            relative = path.removeprefix(APP)
            swift.update(SWIFT_DEPENDENCIES.get(relative, set()))
            if relative.startswith(("Stores/AppAutomation", "Stores/AutomationNative")) or relative in {
                "Stores/AutomationCommandHistory.swift", "Stores/AutomationCapsuleExportSelection.swift",
            }:
                # These stores belong to IntentsAutomationNativeUI, not the CLI
                # exercised by simulator and input-conversion canaries.
                swift.add("*")
            groups = app_ui_groups(relative)
            if groups is None:
                ui = ui_fallback = True
            elif groups:
                ui = True
                ui_groups.update(groups)
            reasons.add(
                "App changes build the native target; portable tests follow their production dependencies."
            )
        elif path.startswith(TESTS):
            native = True
            suite = Path(path).stem
            if suite in SWIFT_SUITES:
                swift.add(suite)
                python.add(
                    "script.tests.test_ci_routes"
                )  # Check suite names against the package catalog.
            # App unit-test edits never require unrelated user-interface tests.
            reasons.add(
                "Native test changes build their target and run the affected portable suite, when available."
            )
        elif path.startswith(UI_TESTS):
            native = ui = True
            if not changed_ui_classes([path], root):
                ui_fallback = True
            reasons.add(
                "App UI tests require the UI test bundle to compile; unrelated portable suites are omitted."
            )
        elif path.startswith("FoundationEvals/"):
            return full_coverage(
                f"Full coverage: native project/configuration change in {path}.", root, extra_classes, affected_groups
            )
        elif path.startswith("website/"):
            reasons.add("Website changes use Linux website checks without native app tests.")
        elif path in METADATA_PATHS or path.startswith(
            ("docs/", ".github/assets/")
        ):
            reasons.add(
                "Documentation, media, and repository metadata need no unit tests or native build."
            )
        elif path.startswith("examples/") and path.endswith(".py"):
            reasons.add(
                "Python examples receive syntax checks without unrelated unit tests."
            )
        elif path.startswith("script/") and path.endswith((".py", ".sh")):
            python.update(python_test_inventory(root))
            macos.update(MACOS_TESTS)
            reasons.add(
                "Unmapped tooling changes conservatively select all script suites."
            )
        else:
            return full_coverage(f"Full coverage: unclassified path {path}.", root, extra_classes, affected_groups)
    return with_matrices({
        "native": native,
        "ui": ui,
        "automation_e2e": automation_e2e,
        "input_conversion": input_conversion,
        "swift_suites": ["*"] if "*" in swift else sorted(swift),
        "python_tests": sorted(python),
        "macos_tests": sorted(macos),
        "reasons": sorted(reasons),
    }, ALL_UI_GROUPS | ui_groups if ui_fallback else ui_groups, extra_classes, not ui_fallback)


def coverage(paths, root=ROOT):
    plan = coverage_plan(paths, root)
    full_native = plan.get("full_coverage", False) or any(production_package_runtime(path) for path in paths or ())
    native_paths = None if paths is None else [
        path for path in paths
        if not standalone_plugin_path(path)
        and not (path.startswith(PRODUCTION_PACKAGE) and not production_package_runtime(path))
    ]
    plan["native_tests"] = select_native_tests(native_paths, plan["native"], root, full=full_native)
    return plan


def changed_paths(event_name, event, root):
    try:
        if event_name == "pull_request":
            pull = event["pull_request"]
            base, head = pull["base"]["sha"], pull["head"]["sha"]
            separator = "..."
        elif event_name == "push":
            base, head = event["before"], event["after"]
            separator = ".."
        else:
            return None
        if not all(
            isinstance(sha, str)
            and re.fullmatch(r"[0-9a-f]{40}", sha)
            and sha != "0" * 40
            for sha in (base, head)
        ):
            return None
    except (KeyError, TypeError):
        return None
    try:
        result = subprocess.run(
            [
                "git",
                "diff",
                "--no-renames",
                "--name-only",
                "-z",
                f"{base}{separator}{head}",
                "--",
            ],
            cwd=root,
            check=True,
            capture_output=True,
        )
    except subprocess.CalledProcessError:
        return None
    return [os.fsdecode(path) for path in result.stdout.split(b"\0") if path]


def main():
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    except (ValueError, OSError):
        event = None
    paths = changed_paths(os.environ["GITHUB_EVENT_NAME"], event, Path.cwd())
    plan = coverage(paths)
    outputs = {key: str(plan[key]).lower() for key in ("native", "ui", "automation_e2e", "input_conversion")}
    outputs["regression"] = str(
        bool(plan["swift_suites"] or plan["macos_tests"])
    ).lower()
    outputs.update(
        {
            key: json.dumps(plan[key])
            for key in ("swift_suites", "python_tests", "macos_tests", "ui_matrix", "native_tests")
        }
    )
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write("".join(f"{key}={value}\n" for key, value in outputs.items()))
    print(json.dumps(plan, indent=2))
    with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as summary:
        summary.write(
            "## CI coverage\n\n"
            + "\n".join(f"- {reason}" for reason in plan["reasons"])
            + "\n\n"
        )
        summary.write(
            f"Native build: **{plan['native']}**. UI test bundle: **{plan['ui']}**.\n\n"
        )
        summary.write(
            "UI groups: " + (", ".join(group["name"] for group in plan["ui_matrix"]) or "none")
            + f". Script test jobs: {int(bool(plan['python_tests']))}.\n\n"
        )
        summary.writelines(
            f"- {label}: {', '.join(plan[key]) or 'none'}\n"
            for label, key in (
                ("Native unit suites", "native_tests"),
                ("Portable Swift suites", "swift_suites"),
                ("Linux unit tests", "python_tests"),
                ("macOS script tests", "macos_tests"),
            )
        )


if __name__ == "__main__":
    main()
