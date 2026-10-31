"""Select builds and test suites from the complete diff; uncertainty runs everything."""

import json
import os
import re
import subprocess
from pathlib import Path

try:
    from ci_native_routes import declared_suites, select_native_tests
    from ci_native_tests import CI_EXCLUDED_UI_TESTS
except ModuleNotFoundError:
    from script.ci_native_routes import declared_suites, select_native_tests
    from script.ci_native_tests import CI_EXCLUDED_UI_TESTS

ROOT = Path(__file__).resolve().parents[1]
# Canonical plugin files also compile directly into the desktop app. Retain their
# former app paths as logical ownership keys for native and UI test selection.
SHARED_APP_SOURCES = json.loads((ROOT / "script/shared_app_sources.json").read_text())
APP = "FoundationEvals/FoundationEvals/"
TESTS = "FoundationEvals/FoundationEvalsTests/"
UI_TESTS = "FoundationEvals/FoundationEvalsUITests/"
UI_TARGET = "FoundationEvalsUITests/"
# These require staged fixtures and explicit live-run opt-in. Ordinary full
# coverage excludes them, including when their source files change.
OPT_IN_UI_SUITES = set()
OPT_IN_UI_METHODS = {}
UI_TIMINGS = json.loads(Path(__file__).with_name("ci_ui_timings.json").read_text())
SDK_CONSUMER_PATHS = set()
SDK_CONSUMER_PREFIXES = (
    "Sources/MacIntentTesting/", "Sources/FoundationEvalsDeveloper/",
    "Tests/MacIntentTestingTests/", "Tests/FoundationEvalsDeveloperTests/",
)
PRODUCTION_PACKAGE = "Packages/ProductionEvals/"
PRODUCTION_QUALIFICATION_PATHS = {
    ".github/workflows/production-evals.yml", "script/ci_production_evals.sh",
    "script/test_production_evals.py",
    "Sources/FoundationEvalsDeveloper/DeveloperProductionCapture.swift",
}
DOCUMENT_REPORT_TESTS = {
    "script.tests.test_document_quality_report", "script.tests.test_document_semantic_report",
}
DOCUMENT_REPORT_INPUTS = {
    APP + "Services/EvaluationDocumentDraftPipeline.swift",
    APP + "Services/EvaluationDocumentSemanticReviewer.swift",
    APP + "Models/EvaluationDocumentModels.swift",
    TESTS + "EvaluationDocumentQualityTests.swift",
}
PRODUCTION_DEVELOPER_SUITES = {
    "DeveloperProtocolTests", "DeveloperFeatureRegistryTests", "DeveloperRunnerHostEngineTests",
}
STANDALONE_PLUGIN_METADATA = {
    ".github/workflows/plugin.yml", ".agents/plugins/marketplace.json",
}
# Keep ordinary UI coverage spread across independent desktops.
UI_BASELINE = {
    "suite-editor": [UI_TARGET + "FoundationEvalsUITests"],
    "runs": [UI_TARGET + "FoundationEvalsRunLifecycleUITests/testRunProgressCompletionAndHistoryRestoration"],
    "traces": [UI_TARGET + "WorkflowTraceUITests/testWorkspaceResetConfirmationAndPersistence"],
}
# Feature ownership follows the view composition and store consumers. Shared
# lifecycle, navigation, persistence and unknown app files retain the full baseline.
UI_VIEW_GROUPS = {
    **{"Views/" + name + ".swift": {"suite-editor", "runs"} for name in (
        "SuiteCasesView", "SuiteEditorView", "SuiteEditorChrome", "SuiteRunControls",
        "FieldAssertionsEditor", "EvaluationSchemaEditor",
    )},
    **{"Views/" + name + ".swift": {"traces"} for name in (
        "WorkflowTraceView", "WorkflowSpanDetail", "WorkspaceTracesView",
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
    **{path: {"review"} for path in (
        "Models/EvaluationReviewModels.swift", "Models/EvaluationJudgeCalibration.swift",
        "Stores/EvaluationStore+Review.swift", "Stores/EvaluationReviewDraftStore.swift",
        "Services/EvaluationReviewWorkflow.swift",
    )},
    "Stores/DeveloperRunnerStore.swift": {"runs", "suite-editor"},
    "Services/MetricScorer.swift": {"runs"},
    "MCP/Installer/MCPSettingsController.swift": {"settings"},
    "Services/TelemetryController.swift": {"settings"},
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
    "settings": [UI_TARGET + "WorkspacePolishUITests/testSettingsTabsKeepTheirPrimaryControlsAccessible"],
    "imports": [UI_TARGET + "WorkspacePolishUITests/testImportIssuesKeepCancelAndImportVisible"],
    "review": [UI_TARGET + "EvaluationReviewUITests"],
}
ALL_UI_GROUPS = set(UI_BASELINE) | set(UI_FEATURE_TESTS)


def app_ui_groups(relative):
    """Map known app sources to owning UI groups, return no groups for service-only changes, and return None for unclassified app sources."""
    if relative in UI_APP_GROUPS:
        return UI_APP_GROUPS[relative]
    if relative == "Services/EvaluationRunner.swift" or relative.startswith("Services/EvaluationRunner+"):
        return {"runs"}
    # Service-only changes still receive native unit tests, without unrelated UI.
    if relative.startswith(("Services/", "MCP/", "Support/Telemetry")):
        return set()
    return None

UI_FEATURE_CLASSES = {
    "runs": {"FoundationEvalsRunLifecycleUITests"},
    "traces": {"WorkflowTraceUITests"},
    "review": {"EvaluationReviewUITests"},
}
NATIVE_UI_HELPERS = {
    "script/ci_native_tests.py": "script.tests.test_ci_native_tests",
    "script/ci_ui_display.py": "script.tests.test_ci_ui_display",
    "script/ci_ui_xctestrun.py": "script.tests.test_ci_ui_xctestrun",
}


# Include shared dependencies, not just the file named after a suite.
SWIFT_DEPENDENCIES = {
    "MCP/Installer/CodexMCPInstaller.swift": {"CodexMCPInstallerTests"},
    "Models/EvaluationFieldAssertion.swift": {"EvaluationFieldAssertionTests"},
    "Models/EvaluationScoringTypes.swift": {
        "EvaluationFieldAssertionTests",
        "MetricScorerTests",
    },
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
    "script.tests.test_foundation_evals_cli",
}
RELEASE_VALIDATION = {
    "script.tests.test_release_validation",
    "script.tests.test_update_feed",
    "script.tests.test_release_dispatch",
}
PYTHON_DEPENDENCIES = {
    "script/changed_function_docs.py": {"script.tests.test_changed_function_docs", "script.tests.test_docstring_coverage"},
    "script/tests/test_changed_function_docs.py": {"script.tests.test_changed_function_docs"},
    "script/docstring_coverage.py": {"script.tests.test_docstring_coverage", "script.tests.test_changed_function_docs"},
    "Tools/DocstringCoverage/parse.mjs": {"script.tests.test_docstring_coverage", "script.tests.test_changed_function_docs"},
    ".github/workflows/docstrings.yml": {"script.tests.test_changed_function_docs", "script.tests.test_docstring_coverage"},
    "script/document_quality_report.py": DOCUMENT_REPORT_TESTS,
    "script/document_semantic_report.py": DOCUMENT_REPORT_TESTS,
    "script/ci_production_evals.sh": {"script.tests.test_ci_production_evals"},
    ".github/workflows/production-evals.yml": {
        "script.tests.test_ci_production_evals", "script.tests.test_ci_workflow",
    },
    "script/foundation-evals": {"script.tests.test_foundation_evals_cli"},
    "script/upload_posthog_symbols.sh": {"script.tests.test_upload_posthog_symbols"},
    "script/update_homebrew.py": {"script.tests.test_update_homebrew"},
    ".github/workflows/update-homebrew.yml": {"script.tests.test_update_homebrew"},
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
    "script/ci_macos_signing.py": {"script.tests.test_ci_macos_signing"},
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
    | {"script.tests.test_package_installer_workflow"}
    | {"script.tests.test_wait_release_ci", "script.tests.test_update_homebrew"},
    ".github/workflows/release.yml": RELEASE_VALIDATION,
}
FULL_COVERAGE_PATHS = {
    "script/shared_app_sources.json",
    ".github/workflows/ci.yml",
    ".github/workflows/ui-stability.yml",
    "script/ci_routes.py",
    "script/ci_gate.py",
    "script/tests/test_ci_gate.py",
    "script/tests/test_ci_route_outputs.py",
    "script/ci_run_tests.py",
    "script/ci_native_cache.py",
    "script/tests/test_ci_routes.py",
    "script/tests/test_ci_run_tests.py",
    "script/tests/test_ci_native_cache.py",
    "script/ci_native_routes.py",
    "script/ci_ui_timings.json",
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
    """Discover top-level script test modules beneath root, excluding the separate macOS-only inventory."""
    return {
        ".".join(path.relative_to(root).with_suffix("").parts)
        for path in (root / "script/tests").glob("test_*.py")
    } - MACOS_TESTS


def standalone_plugin_path(path):
    """Recognize standalone plugin sources and metadata that belong to the dedicated plugin workflow."""
    return path.startswith("plugins/apple-foundation-evals/") or path in STANDALONE_PLUGIN_METADATA


def production_package_runtime(path):
    """Identify production package runtime paths while excluding tests, documentation, licenses, and notices."""
    if not path.startswith(PRODUCTION_PACKAGE):
        return False
    relative = path.removeprefix(PRODUCTION_PACKAGE)
    return not (
        relative.startswith(("Tests/", "docs/", "Documentation/"))
        or Path(relative).suffix.lower() in {".md", ".rst"}
        or Path(relative).name in {"LICENSE", "LICENSE.txt", "NOTICE"}
    )


def package_test_suites(path, root):
    """Select explicitly declared Swift test suites from an existing source file, falling back to the whole package for ambiguous or missing files."""
    source = root / path
    if not path.endswith(".swift") or not source.is_file():
        return {"*"}
    # Explicit test-suite declarations only; extension/helper/fixture edits select
    # the full package instead of guessing which suite consumes them.
    return declared_suites(source.read_text()) or {"*"}


def package_ui_groups(path):
    """Map known package source prefixes to affected app UI groups, using an empty set for sources without UI ownership and None otherwise."""
    if path.startswith("Sources/MacIntentTesting/"):
        return set()
    if path.startswith("Sources/FoundationEvalsDeveloper/"):
        return {"suite-editor", "runs"}
    if path.startswith("Sources/ProductionEvalsCLI/"):
        return set()
    return None


def ordinary_ui_classes(root=ROOT):
    """Discover XCTestCase subclasses under UI sources and omit suites requiring explicit runtime opt-in."""
    return {
        suite
        for source in (root / UI_TESTS).rglob("*.swift")
        for suite in re.findall(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b", source.read_text())
    } - OPT_IN_UI_SUITES


def ui_duration(selector):
    """Estimate selector duration from recorded timings, using the suite or method fallback when no measurement exists."""
    kind = "method" if selector.count("/") == 2 else "suite"
    return UI_TIMINGS["seconds"].get(selector, UI_TIMINGS["fallback_seconds"][kind])


def ui_matrix(groups, extra_classes=(), targeted=False, root=ROOT):
    """Exclude manual fixtures, expand mixed suites, deduplicate selectors, and deterministically balance feature groups across at most three duration-weighted UI shards."""
    catalog = {**UI_BASELINE, **UI_FEATURE_TESTS}
    selections = {
        name: {test for test in (catalog[name] if targeted or name not in UI_BASELINE else UI_BASELINE[name])
               if not any(test == excluded or test.startswith(excluded + "/") for excluded in CI_EXCLUDED_UI_TESTS)}
        for name in sorted(groups)
    }
    # New or edited classes include methods outside the baseline; mixed suites
    # are expanded below to exclude live fixtures even when their file changes.
    # A whole-class selector supersedes partial selectors everywhere, avoiding repeats.
    for suite in sorted(set(extra_classes) - OPT_IN_UI_SUITES):
        selector = UI_TARGET + suite
        if selector in CI_EXCLUDED_UI_TESTS:
            continue
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
    # Mixed suites need method selectors so ordinary coverage cannot silently
    # select live fixtures. Discover methods each run, including newly added ones.
    for suite, excluded in OPT_IN_UI_METHODS.items():
        selector = UI_TARGET + suite
        for tests in selections.values():
            tests.difference_update(selector + "/" + method for method in excluded)
            if selector in tests:
                source = root / UI_TESTS / (suite + ".swift")
                methods = set(re.findall(r"\bfunc\s+(test\w+)\s*\(", source.read_text()))
                tests.remove(selector)
                tests.update(selector + "/" + method for method in methods - excluded)
    # Normalize overlaps globally: a suite supersedes each of its methods,
    # including methods owned by a different feature group.
    whole_suites = {test for tests in selections.values() for test in tests if test.count("/") == 1}
    seen = set()
    for name in sorted(selections):
        unique = {
            test for test in selections[name]
            if test not in seen and not any(test.startswith(suite + "/") for suite in whole_suites)
        }
        selections[name] = unique
        seen.update(unique)
    # Recorded CI durations, rather than selector counts, keep slow feature
    # groups apart. Longest-first placement is deterministic on every runner.
    weights = {name: sum(ui_duration(test) for test in tests) for name, tests in selections.items() if tests}
    jobs = [{"groups": [], "tests": set(), "seconds": 0} for _ in range(min(3, len(weights)))]
    for name in sorted(weights, key=lambda name: (-weights[name], name)):
        target = min(jobs, key=lambda job: (job["seconds"], len(job["groups"])))
        target["groups"].append(name)
        target["tests"].update(selections[name])
        target["seconds"] += weights[name]
    return sorted([
        {"name": "+".join(sorted(job["groups"])), "tests": sorted(job["tests"])}
        for job in jobs
    ], key=lambda job: job["name"])


def changed_ui_classes(paths, root):
    """Collect XCTestCase class names from existing changed Swift UI test files while ignoring removed or unrelated paths."""
    classes = set()
    for path in paths or ():
        if path.startswith(UI_TESTS) and path.endswith(".swift") and (root / path).is_file():
            classes.update(re.findall(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b", (root / path).read_text()))
    return classes


def with_matrices(plan, groups=(), extra_classes=(), targeted=False, root=ROOT):
    """Attach UI shards to the mutable plan and disable its UI flag when selection produces no runnable shard."""
    plan["ui_matrix"] = ui_matrix(groups, extra_classes, targeted, root) if plan["ui"] else []
    plan["ui"] = bool(plan["ui_matrix"])
    return plan


def full_coverage(reason, root=ROOT, extra_classes=(), extra_groups=()):
    """Build the conservative ordinary coverage plan including discovered tests and UI classes, with the supplied fallback reason."""
    return with_matrices({
        "full_coverage": True,
        "native": True,
        "ui": True,
        "input_conversion": False,
        "sdk_consumer": True,
        "production_evals": True,
        "swift_suites": ["*"],
        "python_tests": sorted(python_test_inventory(root)),
        "macos_tests": sorted(MACOS_TESTS),
        "reasons": [reason],
    }, ALL_UI_GROUPS | set(extra_groups), set(extra_classes) | ordinary_ui_classes(root),
        root=root)


def coverage_plan(paths, root=ROOT):
    """Route changed paths to dependent portable, native, and UI checks, falling back to full coverage for unavailable history or unclassified dependencies."""
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
    native = ui = input_conversion = sdk_consumer = production_evals = False
    ui_groups, ui_fallback = set(), False
    swift, python, macos, reasons = set(), set(), set(), set()
    for path in paths:
        if path in DOCUMENT_REPORT_INPUTS:
            python.update(DOCUMENT_REPORT_TESTS)
        production_evals |= path in PRODUCTION_QUALIFICATION_PATHS or path.startswith(
            (PRODUCTION_PACKAGE, "Sources/ProductionEvalsCLI/")
        )
        sdk_consumer |= path in SDK_CONSUMER_PATHS or path.startswith(SDK_CONSUMER_PREFIXES) or production_package_runtime(path)

        if path in FULL_COVERAGE_PATHS:
            return full_coverage(
                f"Full coverage: {path} changes CI, dependencies, or the release candidate.",
                root, extra_classes, affected_groups,
            )
        if path in PYTHON_DEPENDENCIES:
            python.update(PYTHON_DEPENDENCIES[path] - MACOS_TESTS)
            macos.update(PYTHON_DEPENDENCIES[path] & MACOS_TESTS)
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
                    "Production package tests and documentation run production qualification without unrelated root runtime checks."
                )
        elif path.startswith("Tests/"):
            swift.update(package_test_suites(path, root))
            reasons.add("Package test changes select declared suites; helper and fixture changes select the full package.")
        elif path.startswith("Sources/MacIntentTestingCLI/"):
            swift.update({"NativeTestsCLITests", "NativeTestsSignalTests"})
            reasons.add("Native intent CLI changes run parser, manifest, and signal cleanup contracts.")
        elif package_ui_groups(path) is not None:
            groups = package_ui_groups(path)
            swift.add("*")
            if path.startswith("Sources/MacIntentTesting/"):
                native = True
            if groups:
                native = ui = True
                ui_groups.update(groups)
            reasons.add("Package source changes run portable contracts and only the owning app feature's UI.")
        elif path.startswith(APP):
            native = True
            relative = path.removeprefix(APP)
            swift.update(SWIFT_DEPENDENCIES.get(relative, set()))
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
            # Keep the edited UI bundle compiled and use ordinary coverage when
            # its only declared suites need unavailable manual fixtures. This
            # avoids selecting unsupported tests or emitting an empty UI matrix.
            if not (changed_ui_classes([path], root) - OPT_IN_UI_SUITES):
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
    if production_evals:
        reasons.add("Production changes run storage/recovery and real CLI worker qualification in the required regression worker.")
    return with_matrices({
        "native": native,
        "ui": ui,
        "input_conversion": input_conversion,
        "sdk_consumer": sdk_consumer,
        "production_evals": production_evals,
        "swift_suites": ["*"] if "*" in swift else sorted(swift),
        "python_tests": sorted(python),
        "macos_tests": sorted(macos),
        "reasons": sorted(reasons),
    }, ALL_UI_GROUPS | ui_groups if ui_fallback else ui_groups,
        extra_classes | ordinary_ui_classes(root) if ui_fallback else extra_classes,
        not ui_fallback, root)


def coverage(paths, root=ROOT):
    """Route shared canonical sources through their app owners, then select native suites while excluding plugin-only and nonruntime package paths."""
    shared = {SHARED_APP_SOURCES[path] for path in paths or () if path in SHARED_APP_SOURCES}
    if shared:
        paths = list(dict.fromkeys([*paths, *sorted(shared)]))
    plan = coverage_plan(paths, root)
    if shared:
        plan["python_tests"] = sorted(set(plan["python_tests"]) | {"script.tests.test_shared_app_sources"})
        plan["reasons"].append("Shared plugin engine sources also build the app and run their native, UI, and source-membership checks.")
    full_native = plan.get("full_coverage", False) or any(production_package_runtime(path) for path in paths or ())
    native_paths = None if paths is None else [
        path for path in paths
        if not standalone_plugin_path(path)
        and not (path.startswith(PRODUCTION_PACKAGE) and not production_package_runtime(path))
    ]
    plan["native_tests"] = select_native_tests(native_paths, plan["native"], root, full=full_native)
    return plan


def changed_paths(event_name, event, root):
    """Validate event SHAs and read NUL-separated Git diff paths, returning None for unsupported events, malformed identities, or failed history lookup."""
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
    """Read the Actions event, force full ordinary coverage for main pushes, and append selected outputs and coverage explanations to GitHub files."""
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    except (ValueError, OSError):
        event = None
    paths = changed_paths(os.environ["GITHUB_EVENT_NAME"], event, Path.cwd())
    if os.environ["GITHUB_EVENT_NAME"] == "push":
        # The workflow restricts pushes to main. This catches dependency edges
        # intentionally not inferred by the faster pull-request router.
        plan = coverage(None)
        plan["reasons"] = ["Full coverage: main push verifies the complete ordinary suite after affected PR checks."]
    else:
        plan = coverage(paths)
    outputs = {key: str(plan[key]).lower() for key in ("native", "ui", "input_conversion", "sdk_consumer", "production_evals")}
    outputs["regression"] = str(
        bool(plan["swift_suites"] or plan["macos_tests"] or plan["native_tests"]
             or plan["sdk_consumer"] or plan["input_conversion"] or plan["production_evals"])
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
            f"Native build: **{plan['native']}**. UI test bundle: **{plan['ui']}**. "
            f"Production qualification: **{plan['production_evals']}**.\n\n"
        )
        summary.write("### UI suites excluded from CI\n\n")
        summary.writelines(f"- `{test}`: {reason}\n" for test, reason in CI_EXCLUDED_UI_TESTS.items())
        summary.write("\n")
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
