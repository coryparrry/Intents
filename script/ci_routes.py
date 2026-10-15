"""Select builds and test suites from the complete diff; uncertainty runs everything."""

import json
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = "FoundationEvals/FoundationEvals/"
TESTS = "FoundationEvals/FoundationEvalsTests/"
UI_TESTS = "FoundationEvals/FoundationEvalsUITests/"
UI_TARGET = "FoundationEvalsUITests/"
# Keep the existing PR baseline, including the picker once, across independent desktops.
UI_BASELINE = {
    "suite-editor": [UI_TARGET + "FoundationEvalsUITests"],
    "intent-lab": [UI_TARGET + "IntentLabGuidanceUITests", UI_TARGET + "SimplificationUITests"],
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
# Narrow only leaf views whose UI contracts have dedicated feature tests. Shared
# models, stores, components, navigation and unknown views retain the full baseline.
UI_VIEW_GROUPS = {
    **{"Views/" + name + ".swift": {"intent-lab", "suite-editor"} for name in (
        "IntentLabView", "IntentLabHelp", "IntentLabSetupInstallerView",
        "ScenarioEditorView", "ScenarioGuidedCheckEditor", "ScenarioReportView",
        "ScenarioCollectionView", "ScenarioReusableChecksView",
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
UI_FEATURE_CLASSES = {
    "intent-lab": {"IntentLabArrayEntryUITests"},
    "runs": {"FoundationEvalsRunLifecycleUITests"},
    "traces": {"WorkflowTraceUITests"},
    "automation": {"AppAutomationUITests"},
}
NATIVE_UI_HELPERS = {
    "script/ci_native_tests.py": "script.tests.test_ci_native_tests",
    "script/ci_ui_display.py": "script.tests.test_ci_ui_display",
    "script/ci_ui_xctestrun.py": "script.tests.test_ci_ui_xctestrun",
}
UI_SUITES = {
    "NavigationInteractionTests",
    "TimelineRenderingTests",
    "RunToolbarProgressTests",
}

# Include shared dependencies, not just the file named after a suite.
PHYSICAL_SCENARIO_SUITES = {
    "ScenarioPhysicalLeaseTests",
    "ScenarioPhysicalFailureTests",
}
SCENARIO_EXECUTION_SUITES = {"ScenarioContractsTests"} | PHYSICAL_SCENARIO_SUITES
SWIFT_DEPENDENCIES = {
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
    "script/update_homebrew.py": {"script.tests.test_update_homebrew"},
    ".github/workflows/update-homebrew.yml": {"script.tests.test_update_homebrew"},
    "script/check_fixture_shortcut_metadata.py": {"script.tests.test_fixture_shortcut_metadata"},
    "script/release_pr.py": {"script.tests.test_release_pr"},
    "script/release_notes.py": {"script.tests.test_release_notes"},
    "script/wait_release_ci.sh": {"script.tests.test_wait_release_ci"},
    "script/release_validation.py": RELEASE_VALIDATION,
    "script/release_dispatch.sh": RELEASE_VALIDATION,
    "script/verify_release_source.sh": RELEASE_VALIDATION,
    "script/verify_release.sh": RELEASE_VALIDATION,
    "script/release.sh": RELEASE_VALIDATION,
    "script/verify_installer.sh": RELEASE_VALIDATION,
    "script/ci_core_scheme.py": {"script.tests.test_ci_core_scheme"},
    "script/automation_e2e.py": {"script.tests.test_automation_e2e"},
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


def python_matrix(selection):
    """Spread selected modules deterministically across at most four Linux jobs."""
    names = sorted(set(selection))
    count = min(4, len(names))
    return [
        {"name": f"scripts-{index + 1}", "tests": names[index::count]}
        for index in range(count)
    ]


def ui_matrix(groups, extra_classes=()):
    selections = {name: set(UI_BASELINE[name]) for name in sorted(groups)}
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
    return [{"name": name, "tests": sorted(tests)} for name, tests in sorted(selections.items()) if tests]


def changed_ui_classes(paths, root):
    classes = set()
    for path in paths or ():
        if path.startswith(UI_TESTS) and path.endswith(".swift") and (root / path).is_file():
            classes.update(re.findall(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b", (root / path).read_text()))
    return classes


def with_matrices(plan, groups=(), extra_classes=()):
    plan["ui_matrix"] = ui_matrix(groups, extra_classes) if plan["ui"] else []
    plan["python_matrix"] = python_matrix(plan["python_tests"])
    return plan


def full_coverage(reason, root=ROOT, extra_classes=()):
    return with_matrices({
        "native": True,
        "ui": True,
        "automation_e2e": True,
        "swift_suites": ["*"],
        "python_tests": sorted(python_test_inventory(root)),
        "macos_tests": sorted(MACOS_TESTS),
        "reasons": [reason],
    }, UI_BASELINE, extra_classes)


def coverage(paths, root=ROOT):
    extra_classes = changed_ui_classes(paths, root)
    # Gather affected feature classes before any full-coverage early return.
    for path in paths or ():
        if path.startswith(APP + "Views/"):
            for group in UI_VIEW_GROUPS.get(path.removeprefix(APP), ()):
                extra_classes.update(UI_FEATURE_CLASSES.get(group, ()))
    if paths is None:
        return full_coverage(
            "Full coverage: unsupported event, malformed payload, or unavailable Git history.",
            root,
        )
    native = ui = automation_e2e = False
    ui_groups, ui_fallback = set(), False
    swift, python, macos, reasons = set(), set(), set(), set()
    for path in paths:
        automation_e2e |= path.startswith((
            "Sources/IntentsAutomationCore/", "Sources/IntentsAutomationTool/",
            "Integration/AutomationHost/", "examples/AutomationFixture/",
            "Tools/IntentsAutomationApplicationProbe/",
            "FoundationEvals/FoundationEvals/Stores/AppAutomation",
            "FoundationEvals/FoundationEvals/Stores/AutomationNative",
        )) or path in {"script/automation_e2e.py", "script/tests/test_automation_e2e.py"}
        if path in FULL_COVERAGE_PATHS:
            return full_coverage(
                f"Full coverage: {path} changes CI, dependencies, or the release candidate.",
                root, extra_classes,
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
        elif path.startswith(APP):
            native = True
            relative = path.removeprefix(APP)
            swift.update(SWIFT_DEPENDENCIES.get(relative, set()))
            needs_ui = relative in {
                "MCP/Installer/MCPSettingsController.swift",
                "Services/TelemetryController.swift",
            } or not relative.startswith(("Services/", "MCP/"))
            ui |= needs_ui
            if needs_ui:
                groups = UI_VIEW_GROUPS.get(relative)
                if groups is None:
                    ui_fallback = True
                else:
                    ui_groups.update(groups)
            reasons.add(
                "App changes build the native target; portable tests follow their production dependencies."
            )
        elif path.startswith(TESTS):
            native = True
            suite = Path(path).stem
            if suite in SWIFT_SUITES:
                swift.add(suite)
                ui |= suite in UI_SUITES
                python.add(
                    "script.tests.test_ci_routes"
                )  # Check suite names against the package catalog.
            else:
                # These tests only compile on the macOS 27 app target, not the portable package.
                ui = True
            ui_fallback |= suite not in SWIFT_SUITES or suite in UI_SUITES
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
                f"Full coverage: native project/configuration change in {path}.", root, extra_classes
            )
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
            return full_coverage(f"Full coverage: unclassified path {path}.", root, extra_classes)
    return with_matrices({
        "native": native,
        "ui": ui,
        "automation_e2e": automation_e2e,
        "swift_suites": sorted(swift),
        "python_tests": sorted(python),
        "macos_tests": sorted(macos),
        "reasons": sorted(reasons),
    }, UI_BASELINE if ui_fallback else ui_groups, extra_classes)


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
    outputs = {key: str(plan[key]).lower() for key in ("native", "ui", "automation_e2e")}
    outputs["regression"] = str(
        bool(plan["swift_suites"] or plan["macos_tests"])
    ).lower()
    outputs.update(
        {
            key: json.dumps(plan[key])
            for key in ("swift_suites", "python_tests", "macos_tests", "ui_matrix", "python_matrix")
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
            + f". Script test jobs: {len(plan['python_matrix'])}.\n\n"
        )
        summary.writelines(
            f"- {label}: {', '.join(plan[key]) or 'none'}\n"
            for label, key in (
                ("Portable Swift suites", "swift_suites"),
                ("Linux unit tests", "python_tests"),
                ("macOS script tests", "macos_tests"),
            )
        )


if __name__ == "__main__":
    main()
