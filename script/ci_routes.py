"""Select builds and test suites from the complete diff; uncertainty runs everything."""

import json
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = "FoundationEvals/FoundationEvals/"
TESTS = "FoundationEvals/FoundationEvalsTests/"
UI_SUITES = {
    "NavigationInteractionTests",
    "TimelineRenderingTests",
    "RunToolbarProgressTests",
}

# Include shared dependencies, not just the file named after a suite.
SWIFT_DEPENDENCIES = {
    "MCP/Installer/CodexMCPInstaller.swift": {"CodexMCPInstallerTests"},
    "Models/EvaluationFieldAssertion.swift": {"EvaluationFieldAssertionTests"},
    "Models/EvaluationScoringTypes.swift": {
        "EvaluationFieldAssertionTests",
        "MetricScorerTests",
    },
    "Models/ScenarioModels.swift": {"ScenarioContractsTests"},
    "Services/ScenarioComparison.swift": {"ScenarioContractsTests"},
    "Services/ScenarioExecutionRecovery.swift": {"ScenarioContractsTests"},
    "Services/ScenarioPersistence.swift": {"ScenarioContractsTests"},
    "Services/ScenarioValidation.swift": {"ScenarioContractsTests"},
    "Services/XCTestEvidenceImporter.swift": {"ScenarioContractsTests"},
    "Services/XCTestRunInvocationTransport.swift": {"ScenarioContractsTests"},
    "Services/XcodeConnectionDiscovery.swift": {"ScenarioContractsTests"},
    "Services/XcodeTestExecutor.swift": {"ScenarioContractsTests"},
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
MACOS_TESTS = {"script.tests.test_update_signature"}
RELEASE_VALIDATION = {
    "script.tests.test_release_validation",
    "script.tests.test_update_feed",
    "script.tests.test_release_dispatch",
}
PYTHON_DEPENDENCIES = {
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
    | {"script.tests.test_wait_release_ci"},
    ".github/workflows/release.yml": RELEASE_VALIDATION,
}
FULL_COVERAGE_PATHS = {
    ".github/workflows/ci.yml",
    "script/ci_routes.py",
    "script/ci_run_tests.py",
    "script/tests/test_ci_routes.py",
    "script/tests/test_ci_run_tests.py",
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


def full_coverage(reason, root=ROOT):
    return {
        "native": True,
        "ui": True,
        "swift_suites": ["*"],
        "python_tests": sorted(python_test_inventory(root)),
        "macos_tests": sorted(MACOS_TESTS),
        "reasons": [reason],
    }


def coverage(paths, root=ROOT):
    if paths is None:
        return full_coverage(
            "Full coverage: unsupported event, malformed payload, or unavailable Git history.",
            root,
        )
    native = ui = False
    swift, python, macos, reasons = set(), set(), set(), set()
    for path in paths:
        if path in FULL_COVERAGE_PATHS:
            return full_coverage(
                f"Full coverage: {path} changes CI, dependencies, or the release candidate.",
                root,
            )
        if path in PYTHON_DEPENDENCIES:
            python.update(PYTHON_DEPENDENCIES[path])
            if path in {"script/release.sh", "script/verify_installer.sh"}:
                macos.update(MACOS_TESTS)
            if path == "script/ci_core_scheme.py":
                native = True
            reasons.add("Release/tooling changes select their dependent script tests.")
        elif path == "script/verify_update_signature.swift":
            macos.update(MACOS_TESTS)
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
            reasons.add("Test-only changes select the changed suites.")
        elif path.startswith(APP):
            native = True
            relative = path.removeprefix(APP)
            swift.update(SWIFT_DEPENDENCIES.get(relative, set()))
            ui |= relative in {
                "MCP/Installer/MCPSettingsController.swift",
                "Services/TelemetryController.swift",
            } or not relative.startswith(("Services/", "MCP/"))
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
            reasons.add(
                "Native test changes build their target and run the affected portable suite, when available."
            )
        elif path.startswith("FoundationEvals/FoundationEvalsUITests/"):
            native = ui = True
            reasons.add(
                "App UI tests require the UI test bundle to compile; unrelated portable suites are omitted."
            )
        elif path.startswith("FoundationEvals/"):
            return full_coverage(
                f"Full coverage: native project/configuration change in {path}.", root
            )
        elif path in METADATA_PATHS or path.startswith(
            ("docs/", ".github/assets/", "demo-video/")
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
            return full_coverage(f"Full coverage: unclassified path {path}.", root)
    return {
        "native": native,
        "ui": ui,
        "swift_suites": sorted(swift),
        "python_tests": sorted(python),
        "macos_tests": sorted(macos),
        "reasons": sorted(reasons),
    }


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
    outputs = {key: str(plan[key]).lower() for key in ("native", "ui")}
    outputs["regression"] = str(
        bool(plan["swift_suites"] or plan["macos_tests"])
    ).lower()
    outputs.update(
        {
            key: json.dumps(plan[key])
            for key in ("swift_suites", "python_tests", "macos_tests")
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
