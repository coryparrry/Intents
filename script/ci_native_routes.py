"""Select native unit suites only where source dependencies are known."""

from pathlib import Path
import re

APP = "FoundationEvals/FoundationEvals/"
TESTS = "FoundationEvals/FoundationEvalsTests/"
UI_TESTS = "FoundationEvals/FoundationEvalsUITests/"
TARGET = "FoundationEvalsTests"

# These tests directly exercise the named views or the models they present.
SETTINGS_TESTS = {
    "MCPDebugLaunchConfigurationTests", "JudgeCredentialBindingTests",
    "TelemetryControllerTests", "TelemetryTransportTests", "TelemetryUsageTests",
    "TelemetryPayloadFilterTests", "TelemetryDiagnosticsTests",
}
DEPENDENCIES = {
    "Views/MCPSettingsView.swift": {"MCPDebugLaunchConfigurationTests"},
    "Views/JudgeConnectionsSettingsView.swift": {"JudgeCredentialBindingTests"},
    "Views/TelemetrySettingsView.swift": SETTINGS_TESTS - {
        "MCPDebugLaunchConfigurationTests", "JudgeCredentialBindingTests",
    },
    "Views/AppSettingsView.swift": SETTINGS_TESTS,
    "Views/RunAnalysisSection.swift": {"RunBaselineSelectionTests"},
    "Views/DeveloperRunPresentation.swift": {
        "DeveloperRunPresentationTests", "WorkspacePresentationTests",
    },
    "Models/WorkflowTracePresentation.swift": {"WorkflowTracePresentationTests"},
}
SHARED_BUILD_PATHS = {
    "Package.swift", "Package.resolved", "version.txt", ".release-please-manifest.json",
    ".github/workflows/ci.yml", ".github/workflows/ui-stability.yml",
    "script/ci_routes.py", "script/ci_native_routes.py", "script/ci_native_cache.py",
    "script/ci_native_tests.py", "script/ci_core_scheme.py", "script/ci_run_tests.py",
    "script/build_and_run.sh",
}


def declared_suites(text):
    """Ambiguous helpers or top-level functions retain the complete native target."""
    names = set(re.findall(r"\b(?:struct|class|actor|enum)\s+(\w+)", text))
    if not names or any(not name.endswith("Tests") for name in names):
        return None
    if re.search(r"\bextension\s+\w", text):
        return None
    if re.search(r"^(?:@\w+(?:\([^)]*\))?\s+)*@Test\b", text, re.MULTILINE):
        return None
    return names


def select_native_tests(paths, native, root, full=False):
    if not native:
        return []
    if full or paths is None:
        return [TARGET]
    selected = set()
    for path in paths:
        if path in SHARED_BUILD_PATHS or path.startswith(("Sources/", "Integration/", "Tools/")):
            return [TARGET]
        if path.startswith(UI_TESTS):
            # Editing an XCUITest doesn't change native unit behavior.
            continue
        if path.startswith(TESTS):
            source = Path(root) / path
            suites = declared_suites(source.read_text()) if source.is_file() else None
            if not suites:
                return [TARGET]
            selected.update(suites)
        elif path.startswith(APP):
            suites = DEPENDENCIES.get(path.removeprefix(APP))
            if suites is None:
                return [TARGET]
            selected.update(suites)
        elif path.startswith("FoundationEvals/"):
            return [TARGET]
    return [f"{TARGET}/{suite}" for suite in sorted(selected)]
