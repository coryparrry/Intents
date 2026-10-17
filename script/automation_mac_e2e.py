#!/usr/bin/env python3
"""Run the prepared native Mac CLI contract in the current GUI login session."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import sys
import tempfile
import uuid

try:
    import automation_e2e as shared
except ModuleNotFoundError:
    from script import automation_e2e as shared

ROOT = shared.ROOT
FIXTURE_BUNDLE_ID = shared.FIXTURE_BUNDLE_ID + "Mac"
# Native Mac XCUITest plans cannot transfer IntentFile artifacts between segments.
CODEC_FAMILIES = tuple(family for family in shared.FAMILIES if family != "intentFile")
FILE_REJECTION = 'missingEvidence("Mixed XCUITest file transfer is not supported")'
EXPECTED_CASES = {
    "codec-1": "executedUnassessed", "codec-2": "executedUnassessed",
    "mixed": "passed",
    "wrong-assertion": "assertionFailed", "after-wrong-assertion": "executedUnassessed",
}


def mac_plan(prepared, plan):
    target = prepared["host"]["target"]
    login = target.get("loginSession")
    shared.ensure(target.get("kind") == "nativeMac" and target.get("id") == "host-macos-local"
                  and isinstance(login, str) and login and len(login.encode()) <= 256
                  and "\n" not in login and "\0" not in login,
                  "Preparation did not select a concrete native Mac GUI session")
    plan["id"] = "phase5." + plan["id"].removeprefix("phase3.")
    plan["environmentID"] = "selected-mac-session:" + login
    return plan


def outside_repository(path, label):
    resolved = path.resolve()
    shared.ensure(resolved != ROOT and ROOT not in resolved.parents, label + " must stay outside the repository")
    return resolved


def codec_case(prepared, identity, operations):
    # Host operations require an explicit, approved launch before the first invocation.
    launch = shared.ui_segment("launch", "setup", [shared.ui_step("launch", "launch")])
    launch["effects"] = ["observe", "navigate"]
    return shared.case(prepared, identity, shared.host_segment("subject", "subject", operations), setup=[launch])


def verify_selection(reports):
    shared.ensure([item["case"] for item in reports] == ["phase5." + name for name in EXPECTED_CASES],
                  "Mac scenario coverage differs from the supported contract")
    for item, (name, summary) in zip(reports, EXPECTED_CASES.items()):
        shared.ensure(item["summary"] == summary, "Unexpected summary for " + name)
        if name.startswith("codec-") or name == "after-wrong-assertion":
            shared.ensure(item["exactOutputsCompared"] is True, "Missing exact output comparison for " + name)
    compared = {family for item in reports for family in item["codecFamiliesCompared"]}
    shared.ensure(compared == set(CODEC_FAMILIES), "Mac codec coverage differs from the supported contract")


def verify_file_rejection(commands, cli, support, output, prepared):
    plan = mac_plan(prepared, shared.file_case(prepared))
    attempt = "phase5-" + uuid.uuid4().hex
    envelope = {"schemaVersion": 1, "attemptID": attempt, "allowBootAndInstall": False,
                "disposable": True, "plan": plan}
    plan_path = output / (plan["id"] + ".json")
    plan_path.write_text(json.dumps(envelope, indent=2))
    code, stdout = commands.run([cli, "run", "--plan", plan_path, "--support-root", support],
                                timeout=900, allowed=(1,))
    stderr_path = commands.output / f"{commands.sequence:02d}-{Path(str(cli)).name}.stderr.log"
    error = json.loads(stderr_path.read_text())
    shared.ensure(code == 1 and not stdout.strip() and error == {"error": FILE_REJECTION},
                  "Mac file transfer did not fail with the exact unsupported-transfer error")
    shared.verify_campaigns(support)
    root = support / attempt
    # Runner preflight rejects this plan before creating any attempt or dispatch state.
    shared.ensure(not root.exists(), "Rejected file transfer created attempt or dispatch evidence")
    return {"case": plan["id"], "attemptID": attempt, "outcome": "rejectedUnsupported",
            "error": error["error"], "resourcesReleased": True, "subjectDispatched": False}


def selected_developer(commands):
    developer = commands.env.get("DEVELOPER_DIR")
    if not developer:
        _, developer = commands.run(["xcode-select", "-p"])
    shared.ensure(developer.strip(), "No Xcode developer directory is selected")
    path = Path(developer.strip()).resolve()
    if path.suffix == ".app":
        path = path / "Contents/Developer"
    commands.env["DEVELOPER_DIR"] = str(path)
    return path


def fresh_comparison_case(prepared):
    """The saved oracle stays frozen while the runner expands a fresh name per attempt."""
    plan = mac_plan(prepared, shared.mixed_case(prepared, "source-comparison"))
    prefix = "Phase5Compare"
    create, lookup = plan["setup"]
    create["attemptTextBindings"] = {"approvedText": prefix}
    create["uiProgram"] = {"operations": [
        {"id": "name", "kind": "fillBinding", "locator": {"kind": "testId", "value": "task.title"}, "binding": "approvedText"},
        {"id": "save", "kind": "tap", "locator": {"kind": "testId", "value": "task.add"}},
        {"id": "saved", "kind": "assertEndpoint", "locator": {"kind": "testId", "value": "task.title"}},
    ], "bindings": {}, "timeoutMilliseconds": 120000}
    selection = {"typeID": plan["requirements"][0]["entityProperty"]["selection"]["typeID"],
                 "matchingProperties": {"owner": shared.tagged("text", "Personal")},
                 "attemptProperties": {"title": prefix}}
    query = lookup["hostProgram"]["operations"][0]
    query.pop("queryText")
    query["attemptQueryPrefix"] = prefix
    lookup["effects"] = ["observe"]
    plan["execution"]["inputBindings"][0]["uniqueEntity"] = copy.deepcopy(selection)
    requirement = plan["requirements"][0]
    requirement["entityProperty"]["selection"] = copy.deepcopy(selection)
    setup_check = copy.deepcopy(requirement)
    setup_check.update(checkID="task.initially-open", observationID=lookup["id"],
                       expected=shared.tagged("bool", False), justification="Fresh UI-created task is open before completion")
    plan["setupChecks"] = [setup_check]
    observer = plan["observations"][0]
    observer["effects"] = ["observe"]
    observer["hostProgram"]["operations"][0].pop("queryText")
    observer["inputBindings"] = [{"producerSegmentID": lookup["id"], "outputID": "record",
        "destination": "hostQueryIDs", "operationID": "record", "name": "queryIDs", "uniqueEntity": copy.deepcopy(selection)}]
    plan["budget"]["attempts"] = 10
    return plan


def verify_comparison(result, seed, prepared, broken):
    shared.ensure(result.get("outcome") == "fixed" and result.get("originalAttemptID") == seed,
                  "Source-change comparison did not report fixed for the saved failure")
    report = result["report"]
    shared.ensure(report["requestedAttemptsPerBuild"] == 3 and report.get("stopReason") is None
                  and report.get("interruption") is None, "Source-change comparison is incomplete")
    before, after = report["before"], report["after"]
    shared.ensure(len(before) == len(after) == 3, "Comparison requires three fresh attempts per build")
    ids = [item["attemptID"] for item in before + after]
    shared.ensure(len(set(ids)) == 6 and seed not in ids, "Comparison reused an attempt")
    for item in before:
        shared.verify_report(item, "assertionFailed")
    for item in after:
        shared.verify_report(item, "passed")
    baseline, candidate = report["baseline"], report["candidate"]
    shared.ensure(baseline["contractDigest"] == candidate["contractDigest"]
                  and baseline["oracleDigest"] == candidate["oracleDigest"], "Comparison changed the frozen checks")
    for frozen, app in ((baseline, broken["host"]["app"]), (candidate, prepared["host"]["app"])):
        shared.ensure(frozen["plan"]["app"]["productDigest"] == app["productDigest"],
                      "Comparison report does not identify the separately prepared product")
    shared.ensure(baseline["plan"]["app"]["productDigest"] != candidate["plan"]["app"]["productDigest"],
                  "Source change did not produce a changed product")
    before_source = baseline["plan"]["app"].get("sourceManifestDigest")
    after_source = candidate["plan"]["app"].get("sourceManifestDigest")
    shared.ensure(isinstance(before_source, str) and before_source and isinstance(after_source, str)
                  and after_source and before_source != after_source, "Comparison lacks distinct captured source manifests")


def run_source_comparison(commands, cli, output, support, prepared, developer):
    comparison = output / "source-comparison"
    comparison.mkdir()
    # Logical app identity includes its source-project path. Rebuild both versions
    # at this same disposable path; each preparation retains its own frozen bytes.
    fixture = output / "AutomationFixture"
    source = fixture / "Models/TaskDiskStore.swift"
    correct = source.read_text()
    shared.ensure((ROOT / "examples/AutomationFixture/Models/TaskDiskStore.swift").read_text() == correct,
                  "Fixed staged source differs from the comparison's original source")
    needle = "        document.records[affected].completed = true\n"
    shared.ensure(correct.count(needle) == 1, "Source-change fixture completion statement has drifted")
    broken_source = correct.replace(needle, "        document.records[affected].completed = false\n")
    (comparison / "source-change.json").write_text(json.dumps({
        "file": "Models/TaskDiskStore.swift", "baseline": "completion persists false", "candidate": "completion persists true",
        "baselineSourceSHA256": hashlib.sha256(broken_source.encode()).hexdigest(),
        "candidateSourceSHA256": hashlib.sha256(correct.encode()).hexdigest(),
    }, indent=2))
    baseline_support = comparison / "support"
    preparation = [cli, "prepare", "--project", fixture / "AutomationFixture.xcodeproj",
                   "--scheme", "AutomationFixtureMac", "--destination", "mac", "--xcode", developer]
    try:
        source.write_text(broken_source)
        _, broken = commands.json([*preparation, "--support-root", baseline_support], timeout=1200)
        (comparison / "prepared.json").write_text(json.dumps(broken, indent=2))
        shared.ensure(broken["host"]["target"] == prepared["host"]["target"], "Comparison selected a different Mac session")
        plan = fresh_comparison_case(broken)
        seed, code, report = shared.run_plan(commands, cli, baseline_support, comparison, plan)
        (comparison / "seed-report.json").write_text(json.dumps(report, indent=2))
        shared.ensure(code == 1, "Broken source did not return a failing CLI status")
        shared.verify_report(report, "assertionFailed")
    finally:
        source.write_text(correct)
    candidate_support = comparison / "candidate-support"
    _, candidate = commands.json([*preparation, "--support-root", candidate_support], timeout=1200)
    (comparison / "candidate-prepared.json").write_text(json.dumps(candidate, indent=2))
    shared.ensure(candidate["host"]["target"] == prepared["host"]["target"], "Candidate selected a different Mac session")
    code, result = commands.json([cli, "compare", "--baseline-support", baseline_support,
        "--baseline-attempt", seed, "--support-root", candidate_support, "--attempts", "3"], timeout=3600, allowed=(0, 1))
    (comparison / "comparison.json").write_text(json.dumps(result, indent=2))
    shared.verify_campaigns(baseline_support)
    shared.verify_campaigns(candidate_support)
    shared.verify_campaigns(support)
    shared.ensure(code == 0, "Source comparison did not complete successfully")
    verify_comparison(result, seed, candidate, broken)
    return {"outcome": "fixed", "baselineAttempts": 3, "candidateAttempts": 3,
            "seedAttemptID": seed, "evidence": "source-comparison/comparison.json"}


def run_contract(commands, output, *, cli=None, build_root=None, jobs=2, reports=None, include_comparison=True,
                 unsupported_checks=None):
    shared.ensure(jobs > 0, "Build jobs must be positive")
    reports = reports if reports is not None else []
    developer = selected_developer(commands)
    if cli is None:
        scratch = build_root or output / "swift-build"
        commands.run(["xcrun", "swift", "build", "--jobs", str(jobs), "--scratch-path", scratch,
                      "--product", "intents-automation"], timeout=1200)
        _, bin_path = commands.run(["xcrun", "swift", "build", "--scratch-path", scratch, "--show-bin-path"])
        cli = Path(bin_path.strip()) / "intents-automation"
    fixture = output / "AutomationFixture"
    shutil.copytree(ROOT / "examples/AutomationFixture", fixture)
    commands.run(["xcodegen", "generate", "--spec", fixture / "project.yml"], cwd=fixture)
    support = output / "support"
    flags = ["--support-root", support]
    _, prepared = commands.json([cli, "prepare", "--project", fixture / "AutomationFixture.xcodeproj",
                                 "--scheme", "AutomationFixtureMac", "--destination", "mac",
                                 "--xcode", developer, *flags], timeout=1200)
    (output / "prepared.json").write_text(json.dumps(prepared, indent=2))
    shared.ensure(prepared["host"]["app"]["bundleID"] == FIXTURE_BUNDLE_ID,
                  "Preparation selected a different app than the staged Mac fixture")
    mac_plan(prepared, shared.case(prepared, "identity", {}))
    for selected in (prepared.get("selectedDeveloperDirectoryPath"),
                     ((prepared.get("sourceGraph") or {}).get("platformContext") or {}).get("developerDirectory")):
        shared.ensure(isinstance(selected, str) and selected and Path(selected).resolve() == developer,
                      "Prepared app or source graph used a different Xcode developer directory")
    _, catalog = commands.json([cli, "actions", *flags])
    shared.ensure(catalog == prepared["catalog"], "actions differs from prepared catalog")

    def execute(plan, summary, expected=None):
        plan = mac_plan(prepared, plan)
        attempt, code, report = shared.run_plan(commands, cli, support, output, plan)
        (output / (plan["id"] + ".report.json")).write_text(json.dumps(report, indent=2))
        shared.verify_report(report, summary)
        shared.ensure(code == (1 if summary == "assertionFailed" else 0),
                      "CLI exit status differs from reported assessment")
        if expected is not None:
            shared.verify_echo(report, expected)
        shared.verify_campaigns(support)
        _, saved = commands.json([cli, "show", attempt, *flags])
        shared.ensure(saved == report, "Saved report differs from run output")
        compared = sorted({family.removeprefix("empty.") for family in expected or {}})
        reports.append({"case": plan["id"], "attemptID": attempt, "summary": summary,
                        "exactOutputsCompared": expected is not None,
                        "codecFamiliesCompared": compared})
        (output / "verified-cases.json").write_text(json.dumps(reports, indent=2))
        print(f"Verified {plan['id']}: {summary}", flush=True)

    batches = shared.echo_batches(catalog)
    for index, (operations, expected) in enumerate(batches, 1):
        execute(codec_case(prepared, f"codec-{index}", operations),
                "executedUnassessed", expected)
    rejection = verify_file_rejection(commands, cli, support, output, prepared)
    (output / "unsupported-codec-check.json").write_text(json.dumps(rejection, indent=2))
    if unsupported_checks is not None:
        unsupported_checks.append(rejection)
    execute(shared.mixed_case(prepared, "mixed"), "passed")
    execute(shared.mixed_case(prepared, "wrong-assertion", expected=False), "assertionFailed")
    operations, expected = batches[0]
    execute(codec_case(prepared, "after-wrong-assertion", operations[:1]),
            "executedUnassessed", {operations[0]["id"]: expected[operations[0]["id"]]})
    verify_selection(reports)
    if include_comparison:
        return run_source_comparison(commands, cli, output, support, prepared, developer)
    return None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xcode", type=Path, help="Xcode.app or Contents/Developer")
    parser.add_argument("--output-root", type=Path, help="Fresh evidence directory outside the repository")
    parser.add_argument("--cli", type=Path, help="Existing CLI executable with its SwiftPM resource bundle")
    parser.add_argument("--build-root", type=Path, help="Reusable external Swift build cache")
    parser.add_argument("--jobs", type=int, default=2, help="Swift build jobs (default: 2)")
    args = parser.parse_args(argv)
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    if args.cli and args.build_root:
        parser.error("Choose --cli or --build-root")
    output = outside_repository(args.output_root or Path(tempfile.mkdtemp(prefix="intents-automation-mac-e2e-")), "Artifacts")
    shared.ensure(not output.exists() or not any(output.iterdir()), "Output root must be empty")
    build_root = outside_repository(args.build_root, "Build cache") if args.build_root else None
    cli = args.cli.resolve() if args.cli else None
    if cli:
        shared.ensure(cli.is_file() and os.access(cli, os.X_OK), "--cli must be an executable file")
    output.mkdir(parents=True, exist_ok=True)
    summary = {"schemaVersion": 1, "status": "failed", "destination": "mac",
               "echoAssessment": "executedUnassessed", "cases": [], "unsupportedCodecChecks": [],
               "codecCoverageNote": "Mac compares 15 supported families; IntentFile transfer is rejected. Simulator file coverage remains separate."}
    print(f"Mac automation evidence: {output}", flush=True)

    def interrupted(signum, frame):
        raise KeyboardInterrupt(f"Interrupted by signal {signum}")

    previous_term = signal.signal(signal.SIGTERM, interrupted)
    try:
        summary["sourceComparison"] = run_contract(shared.Commands(output, args.xcode), output, cli=cli, build_root=build_root,
                                                   jobs=args.jobs, reports=summary["cases"],
                                                   unsupported_checks=summary["unsupportedCodecChecks"])
        compared = {family for item in summary["cases"] for family in item["codecFamiliesCompared"]}
        summary.update(status="passed", codecFamiliesCompared=[family for family in CODEC_FAMILIES if family in compared])
        print(f"Mac automation contract passed: {len(summary['cases'])} scenarios, "
              f"{len(summary['codecFamiliesCompared'])} codec families compared.", flush=True)
        return 0
    except (Exception, KeyboardInterrupt) as error:
        summary["error"] = str(error)
        print(str(error), file=sys.stderr)
        return 1
    finally:
        signal.signal(signal.SIGTERM, previous_term)
        (output / "summary.json").write_text(json.dumps(summary, indent=2))


if __name__ == "__main__":
    sys.exit(main())
