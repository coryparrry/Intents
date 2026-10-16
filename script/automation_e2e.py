#!/usr/bin/env python3
"""Reproduce prepared-app automation on an owned simulator, with raw evidence outside Git."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
ARRAYS = ("textArray", "boolArray", "integerArray", "decimalArray", "dateArray")
FAMILIES = ("text", "bool", "integer", "decimal", "date", "enum", "entity", "duration",
            "calendarComponents", "url", "intentFile", *ARRAYS)
INTENTS = {f: "Echo" + f[0].upper() + f[1:] + "Intent" for f in FAMILIES}
INTENTS["url"] = "EchoURLIntent"
FILE_SHA = hashlib.sha256(b"phase3 fixture").hexdigest()
SCENARIO_GROUPS = {
    "codec-1": ("codec-1",),
    "codec-2": ("codec-2",),
    "codec-file": ("codec-file",),
    "mixed": ("mixed",),
    "wrong-assertion": ("wrong-assertion",),
    "timeout-recovery": ("timeout", "after-timeout"),
}
SCENARIO_SUMMARIES = {
    "codec-1": "executedUnassessed", "codec-2": "executedUnassessed",
    "codec-file": "executedUnassessed", "mixed": "passed",
    "wrong-assertion": "assertionFailed", "timeout": "timedOut",
    "after-timeout": "executedUnassessed",
}


def ensure(condition, message):
    if not condition:
        raise AssertionError(message)


def scenario_cases(group):
    ensure(group == "all" or group in SCENARIO_GROUPS, "Unknown scenario group: " + str(group))
    return tuple(case for cases in SCENARIO_GROUPS.values() for case in cases) if group == "all" else SCENARIO_GROUPS[group]


def verify_scenario_selection(reports, group):
    selected = scenario_cases(group)
    ensure(isinstance(reports, list) and all(isinstance(report, dict) for report in reports),
           "Scenario reports must be an array of objects")
    ensure([report.get("case") for report in reports] == ["phase3." + case for case in selected],
           "Scenario coverage differs from selected group " + group)
    for case, report in zip(selected, reports):
        ensure(report.get("summary") == SCENARIO_SUMMARIES[case], "Scenario summary differs for " + case)
        if case.startswith("codec-") or case == "after-timeout":
            ensure(report.get("exactOutputsCompared") is True, "Missing exact output comparison for " + case)


def tagged(kind, value, **extra):
    return {"kind": kind, "value": value, **extra}


def integer(value):
    return tagged("integer", str(value))


def object_value(**fields):
    return tagged("object", fields)


def action(catalog, name):
    matches = [a for a in catalog["systemActions"] if a["id"] == name]
    ensure(len(matches) == 1, f"Missing or duplicate captured action {name}")
    item = matches[0]
    ensure(item["compiled"] and item["parametersComplete"], f"Incomplete action {name}")
    return item


def echo_batches(catalog):
    """Two ten-operation batches, including all five empty collection setters."""
    date = tagged("date", "2026-10-13T12:34:56.000Z", timeZone="UTC")
    values = {
        "text": tagged("text", "Phase 3 · exact echo"), "bool": tagged("bool", True),
        "integer": integer(9007199254740993), "decimal": tagged("decimal", "123.125"),
        "date": date, "enum": tagged("enum", "second", typeId="FixtureChoice"),
        "entity": tagged("entity", "reference-1", typeId="FixtureReference"),
        "duration": object_value(seconds=integer(2), attoseconds=integer(125000000000000000)),
        "calendarComponents": object_value(components=object_value(month=integer(-2), day=integer(3))),
        "url": object_value(url=tagged("text", "https://example.invalid/phase3?value=exact")),
        "textArray": tagged("array", [tagged("text", "one"), tagged("text", "two")]),
        "boolArray": tagged("array", [tagged("bool", True), tagged("bool", False)]),
        "integerArray": tagged("array", [integer(9007199254740993), integer(-7)]),
        "decimalArray": tagged("array", [tagged("decimal", "1.125"), tagged("decimal", "-2.5")]),
        "dateArray": tagged("array", [date]),
    }
    groups = [list(FAMILIES[:7]) + list(ARRAYS[:3]),
              list(ARRAYS[3:]) + ["duration", "calendarComponents", "url"] + ["empty." + f for f in ARRAYS]]
    batches = []
    for families in groups:
        operations, expected = [], {}
        for identity in families:
            family = identity.removeprefix("empty.")
            declared = action(catalog, INTENTS[family])
            parameter = next(p for p in declared["parameters"] if p["name"] == "value")
            ensure(parameter["family"] == family, f"Wrong family for {declared['id']}")
            value = copy.deepcopy(tagged("array", []) if identity.startswith("empty.") else values[family])
            if family in ("enum", "entity"):
                value["typeId"] = parameter["typeID"]
            operation = {"id": identity, "kind": "invoke", "typeID": declared["id"],
                         "parameters": {"value": value}, "resultCodec": declared["resultFamily"]}
            if family in (*ARRAYS, "duration", "calendarComponents", "url"):
                operation["parameterCodecs"] = {"value": family}
            operations.append(operation)
            expected[identity] = tagged("text", value["value"]) if family in ("enum", "entity") else value
        ensure(len(operations) == 10, "Codec batches must contain ten operations")
        batches.append((operations, expected))
    return batches


def host_segment(identity, phase, operations, bindings=None):
    query = operations[0]["kind"] == "query"
    codecs = set()
    for op in operations:
        if op["kind"] == "invoke":
            codecs.update(op.get("parameterCodecs", {}).get(n, v["kind"]) for n, v in op["parameters"].items())
            if op.get("resultCodec") != "noValue":
                codecs.add(op["resultCodec"])
    for binding in bindings or []:
        codecs.add(binding.get("parameterCodec", "entity"))
    result = {"id": identity, "kind": "systemQuery" if query else "systemIntent", "phase": phase,
              "operation": identity, "inputs": {}, "effects": ["observe", "navigate"] if query else ["observe", "navigate", "fixtureWrite"],
              "lifecycle": "persistedStateAcrossSegments",
              "requiredCapabilities": ["apple.entity.query" if query else "apple.intent.invoke"] +
                                      sorted("apple.codec." + c for c in codecs),
              "hostProgram": {"operations": operations}}
    if bindings:
        result["inputBindings"] = bindings
    return result


def ui_step(identity, kind, **fields):
    return {"id": identity, "segmentID": "", "kind": kind, **fields}


def ui_segment(identity, phase, steps):
    return {"id": identity, "kind": "ui", "phase": phase, "operation": identity, "inputs": {},
            "effects": ["observe", "navigate", "fixtureWrite"], "lifecycle": "persistedStateAcrossSegments",
            "requiredCapabilities": [], "uiProgram": {"operations": [], "bindings": {},
                                                         "timeoutMilliseconds": 120000, "steps": steps}}


def case(prepared, identity, execution, setup=None, observations=None, requirements=None):
    return {"schemaVersion": 3, "id": "phase3." + identity, "revision": 1,
            "app": prepared["host"]["app"], "target": prepared["host"]["target"],
            "environmentID": "selected-simulator:" + prepared["host"]["target"]["id"],
            "setup": setup or [], "execution": execution, "observations": observations or [],
            "requirements": requirements or [], "cleanup": [],
            "budget": {"subjectOperations": 20, "attempts": 1, "uiActions": 100, "controllerCalls": 100,
                       "wallClockSeconds": 600}, "provenance": {"ui.backend": "xcuitest"}}


def file_case(prepared):
    producer = action(prepared["catalog"], "MakeFixtureFileIntent")
    consumer = action(prepared["catalog"], INTENTS["intentFile"])
    ensure(producer["resultFamily"] == consumer["resultFamily"] == "intentFile", "File codecs missing")
    setup = host_segment("file.producer", "setup", [{"id": "file", "kind": "invoke", "typeID": producer["id"],
                                                    "parameters": {}, "resultCodec": "intentFile"}])
    execution = host_segment("subject", "subject", [{"id": "file.echo", "kind": "invoke", "typeID": consumer["id"],
                                                      "parameters": {}, "resultCodec": "intentFile"}],
                             [{"producerSegmentID": setup["id"], "outputID": "file", "destination": "hostParameter",
                               "operationID": "file.echo", "name": "value", "parameterCodec": "intentFile"}])
    return case(prepared, "codec-file", execution, setup=[setup])


def mixed_case(prepared, identity, expected=True):
    title = "Phase 3 task " + uuid.uuid4().hex
    declared = action(prepared["catalog"], "CompleteTaskIntent")
    entity_id = next(p["typeID"] for p in declared["parameters"] if p["name"] == "task")
    entities = [e for e in prepared["catalog"]["entities"] if e["typeID"] == entity_id]
    ensure(len(entities) == 1, "Missing captured Task query")
    properties = {k: entities[0]["properties"][k] for k in ("title", "owner", "completed")}
    selection = {"typeID": entity_id, "matchingProperties": {"title": tagged("text", title),
                                                            "owner": tagged("text", "Personal")}}
    def query(segment, phase):
        return host_segment(segment, phase, [{"id": "record", "kind": "query", "typeID": entity_id,
                                              "parameters": {}, "queryText": title, "properties": properties}])
    create = ui_segment("create", "setup", [ui_step("launch", "launch"),
        ui_step("title.ready", "waitFor", query={"identifier": "task.title", "elementType": "textField"}, property="exists", timeout=30),
        ui_step("title.fill", "clearAndType", query={"identifier": "task.title", "elementType": "textField"}, text=title),
        ui_step("save", "tap", query={"identifier": "task.add", "elementType": "button"}),
        ui_step("saved", "waitFor", query={"labelContains": title, "elementType": "staticText"}, property="exists", timeout=30),
        ui_step("screenshot", "screenshot")])
    execution = host_segment("subject", "subject", [{"id": "complete", "kind": "invoke", "typeID": declared["id"],
                                                      "parameters": {}, "resultCodec": "noValue"}],
        [{"producerSegmentID": "before", "outputID": "record", "destination": "hostParameter",
          "operationID": "complete", "name": "task", "uniqueEntity": selection}])
    requirement = {"checkID": "task.completed", "observationID": "after", "expected": tagged("bool", expected),
                   "proof": "appState", "justification": "Independent entity query reads the UI-created task after intent completion",
                   "entityProperty": {"operationID": "record", "selection": selection, "property": "completed"}}
    return case(prepared, identity, execution, setup=[create, query("before", "setup")],
                observations=[query("after", "observe")], requirements=[requirement])


def timeout_case(prepared):
    return case(prepared, "timeout", ui_segment("subject", "subject", [ui_step("launch", "launch"),
        ui_step("missing", "waitFor", query={"identifier": "phase3.deliberately.missing", "elementType": "any"},
                property="exists", timeout=2)]))


def verify_report(report, summary, completed=True):
    ensure(report["resourcesReleased"] is True, "Run did not release its resources")
    result = report["result"]
    ensure(result["summary"] == summary, f"Expected {summary}, got {result['summary']}")
    if completed:
        ensure(result["subjectDispatched"] and result["subjectCompleted"] and result["evidenceComplete"],
               "Run lacks completed subject/evidence")
        ensure(not result.get("subjectDispatchUncertain", False), "Subject dispatch remains uncertain")
    if summary == "executedUnassessed":
        ensure(result["assessed"] is False, "Echo execution must remain unassessed")
    elif summary in ("passed", "assertionFailed"):
        ensure(result["assessed"] is True, "Business assertion must be assessed by the app")


def outputs(report, segment_id):
    receipts = [r for r in report["receipts"] if r["segmentID"] == segment_id]
    ensure(len(receipts) == 1 and receipts[0]["dispatched"] and receipts[0]["completed"],
           f"Missing completed receipt for {segment_id}")
    return receipts[0]["verifiedOutputs"]


def verify_echo(report, expected):
    verify_report(report, "executedUnassessed")
    ensure(outputs(report, "subject") == expected, "Exact echo outputs differ from expected tagged values")


def verify_file(report):
    verify_report(report, "executedUnassessed")
    for segment, operation in (("file.producer", "file"), ("subject", "file.echo")):
        value = outputs(report, segment)[operation]
        ensure(value["kind"] == "artifact" and value["sha256"] == FILE_SHA and value["value"],
               "File receipt does not contain the exact known byte digest")


def verify_campaigns(support_root):
    state = json.loads((support_root / "target-leases.json").read_text())
    ensure(state["campaigns"] == {}, "Run left an active or quarantined campaign")


class Commands:
    """Bounded subprocesses with a separate process group and preserved raw output."""
    def __init__(self, output, developer=None):
        self.output, self.env, self.sequence = output, dict(os.environ), 0
        if developer:
            self.env["DEVELOPER_DIR"] = str(developer)

    def run(self, arguments, *, timeout=180, cwd=ROOT, allowed=(0,)):
        self.sequence += 1
        stem = self.output / f"{self.sequence:02d}-{Path(str(arguments[0])).name}"
        stem.with_suffix(".command.json").write_text(json.dumps([str(a) for a in arguments], indent=2))
        with stem.with_suffix(".stdout.log").open("wb") as out, stem.with_suffix(".stderr.log").open("wb") as err:
            started = time.monotonic()
            process = subprocess.Popen([str(a) for a in arguments], cwd=cwd, env=self.env,
                                       stdout=out, stderr=err, start_new_session=True)
            try:
                code = process.wait(timeout=timeout)
            except BaseException:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)
                except ProcessLookupError:
                    pass
                raise
        elapsed = time.monotonic() - started
        command = " ".join(str(a) for a in arguments[:2])
        print(f"Completed {command}: {elapsed:.1f}s (exit {code})", flush=True)
        stdout = stem.with_suffix(".stdout.log").read_text()
        ensure(code in allowed, f"Command exited {code}: {arguments[0]}; see {stem}.stderr.log")
        return code, stdout

    def json(self, arguments, **options):
        code, raw = self.run(arguments, **options)
        try:
            return code, json.loads(raw)
        except json.JSONDecodeError as error:
            stem = self.output / f"{self.sequence:02d}-{Path(str(arguments[0])).name}"
            stderr_path = stem.with_suffix(".stderr.log")
            with stderr_path.open("rb") as diagnostics:
                detail = diagnostics.read(4096).decode("utf-8", errors="replace").strip()
            raise AssertionError(f"Command returned invalid JSON (exit {code}): {arguments[0]}; "
                                 f"stderr: {detail or '(empty)'}; "
                                 f"see {stem}.stdout.log and {stderr_path}") from error


def run_plan(commands, cli, support, output, plan):
    attempt = "phase3-" + uuid.uuid4().hex
    envelope = {"schemaVersion": 1, "attemptID": attempt, "allowBootAndInstall": False,
                "disposable": True, "plan": plan}
    plan_path = output / (plan["id"] + ".json")
    plan_path.write_text(json.dumps(envelope, indent=2))
    code, report = commands.json([cli, "run", "--plan", plan_path, "--support-root", support],
                                 timeout=900, allowed=(0, 1))
    verify_campaigns(support)
    return attempt, code, report


def registration_pending(report, support, attempt, bundle_id):
    # Retry only the harmless readiness echo's exact metadata error after resources drain.
    if (report["resourcesReleased"] is not True or report["result"]["summary"] not in ("timedOut", "unresolved")
            or report["result"]["subjectDispatched"] or report["result"]["subjectCompleted"] or report["receipts"]):
        return False
    marker = f'Error Domain=AppIntentsServicesMetadataErrorDomain Code=400 "{bundle_id} is not present"'
    return any(marker in path.read_text()
               for pattern in ("apple-command-failure-*.txt", "apple-log-*.txt")
               for path in (support / attempt / "artifacts").glob(pattern))


def wait_for_registration(commands, cli, support, output, prepared):
    # This authored fixture echo has no writes; never retry customer/business actions.
    declared = action(prepared["catalog"], "EchoTextIntent")
    value = tagged("text", "registration-ready")
    operation = {"id": "registration", "kind": "invoke", "typeID": declared["id"],
                 "parameters": {"value": value}, "resultCodec": declared["resultFamily"]}
    plan = case(prepared, "registration", host_segment("subject", "subject", [operation]))
    attempts = []
    for index in range(3):
        attempt, code, report = run_plan(commands, cli, support, output, plan)
        attempts.append({"attemptID": attempt, "summary": report["result"]["summary"]})
        (output / "registration-readiness.json").write_text(json.dumps(attempts, indent=2))
        if index < 2 and code == 1 and registration_pending(report, support, attempt, prepared["host"]["app"]["bundleID"]):
            print("Fixture metadata is still indexing; retrying the harmless registration echo.", flush=True)
            continue
        verify_echo(report, {"registration": value})
        ensure(code == 0, "Registration echo exit status differs from successful report")
        print("Verified fixture registration readiness.", flush=True)
        return


def simulator_configuration(runtimes, device_types, sdk_version=None):
    available = [r for r in runtimes["runtimes"] if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]
    if sdk_version is not None:
        sdk = tuple(int(v) for v in sdk_version.strip().split(".")[:2])
        ensure(len(sdk) == 2, "Simulator SDK version lacks major/minor")
        available = [r for r in available if tuple(int(v) for v in r["version"].split(".")[:2]) == sdk]
    ensure(available, "No available iOS simulator runtime matching the selected simulator SDK")
    runtime = max(available, key=lambda r: tuple(int(v) for v in r["version"].split(".")))
    supported = {d["identifier"] for d in runtime.get("supportedDeviceTypes", [])}
    iphones = [d for d in device_types["devicetypes"] if d["name"].startswith("iPhone") and
               (not supported or d["identifier"] in supported)]
    ensure(iphones, "No iPhone device type for selected runtime")
    # Prefer a large supported phone so the fixture's save control stays visible with the keyboard.
    phone = max(iphones, key=lambda d: (
        "Max" in d["name"] or "Plus" in d["name"],
        tuple(int(n) for n in re.findall(r"\d+", d["name"])), d["name"],
    ))
    return runtime["identifier"], phone["identifier"]


def run_contract(commands, output, build_root=None, build_jobs=None, record_build_cache=False, scenario_group="all"):
    selected = scenario_cases(scenario_group)
    github_output = os.environ.get("GITHUB_OUTPUT")
    if record_build_cache:
        ensure(build_root is not None, "--record-build-cache requires --build-root")
        ensure(github_output and Path(github_output).is_file(),
               "--record-build-cache requires an existing GITHUB_OUTPUT file")
    jobs = build_jobs if build_jobs is not None else (os.cpu_count() or 1)
    ensure(jobs > 0, "Build jobs must be positive")
    selected_developer = commands.env.get("DEVELOPER_DIR")
    if not selected_developer:
        _, selected_developer = commands.run(["xcode-select", "-p"])
    ensure(selected_developer.strip(), "No Xcode developer directory is selected")
    developer = Path(selected_developer.strip()).resolve()
    if developer.suffix == ".app":
        developer = developer / "Contents/Developer"
    commands.env["DEVELOPER_DIR"] = str(developer)
    scratch = build_root or output / "swift-build"
    build_arguments = ["xcrun", "swift", "build", "--jobs", str(jobs), "--scratch-path", scratch, "--product", "intents-automation"]
    cli, build_fingerprint = None, None
    if record_build_cache:
        # Collect optional identity before any simulator activity.
        try:
            from ci_native_cache import capture
        except ModuleNotFoundError:
            from script.ci_native_cache import capture
        try:
            from ci_automation_build import build_fingerprint as fingerprint_build, cached_cli, record_cli
        except ModuleNotFoundError:
            from script.ci_automation_build import build_fingerprint as fingerprint_build, cached_cli, record_cli
        build_fingerprint = fingerprint_build(commands, ROOT, scratch, build_arguments)
        cli, damaged_products = cached_cli(scratch, build_fingerprint)
        if damaged_products:
            runner_temp = Path(commands.env.get("RUNNER_TEMP", "")).resolve()
            ensure(commands.env.get("RUNNER_TEMP") and scratch.resolve() == scratch.absolute()
                   and runner_temp in scratch.resolve().parents and not scratch.is_symlink()
                   and scratch.resolve() != ROOT.resolve() and ROOT.resolve() not in scratch.resolve().parents,
                   "Refusing to clean a damaged CLI cache outside the owned runner scratch directory")
            shutil.rmtree(scratch)
    _, runtimes = commands.json(["xcrun", "simctl", "list", "runtimes", "--json"])
    _, types = commands.json(["xcrun", "simctl", "list", "devicetypes", "--json"])
    _, sdk_version = commands.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"])
    runtime, device_type = simulator_configuration(runtimes, types, sdk_version)
    simulator = None
    try:
        _, raw = commands.run(["xcrun", "simctl", "create", "Automation e2e " + uuid.uuid4().hex[:8], device_type, runtime])
        created = raw.strip()
        ensure(re.fullmatch(r"[A-Fa-f0-9-]{36}", created), "Invalid owned simulator UUID")
        simulator = created
        (output / "owned-simulator.json").write_text(json.dumps({"id": simulator, "runtime": runtime}))
        fixture = output / "AutomationFixture"
        shutil.copytree(ROOT / "examples/AutomationFixture", fixture)
        commands.run(["xcodegen", "generate", "--spec", fixture / "project.yml"], cwd=fixture)
        if cli is None:
            commands.run(build_arguments, timeout=900)
            _, bin_path = commands.run(["xcrun", "swift", "build", "--scratch-path", scratch, "--show-bin-path"])
            cli = Path(bin_path.strip()) / "intents-automation"
            if record_build_cache:
                if build_fingerprint is not None and build_fingerprint != fingerprint_build(commands, ROOT, scratch, build_arguments):
                    build_fingerprint = None
                record_cli(scratch, build_fingerprint, cli)
        else:
            print("Reusing verified automation CLI and resources; compiled inputs and toolchain are unchanged.", flush=True)
        if record_build_cache:
            capture(ROOT, scratch)
            with Path(github_output).open("a") as state:
                state.write("cli_built=true\n")
        support, reports = output / "support", []
        flags = ["--support-root", support]
        _, prepared = commands.json([cli, "prepare", "--project", fixture / "AutomationFixture.xcodeproj",
                                     "--scheme", "AutomationFixture", "--destination", "sim:" + simulator,
                                     "--xcode", developer, *flags], timeout=1200)
        (output / "prepared.json").write_text(json.dumps(prepared, indent=2))
        prepared_developer = prepared.get("selectedDeveloperDirectoryPath")
        ensure(isinstance(prepared_developer, str) and prepared_developer
               and Path(prepared_developer).resolve() == developer,
               "Prepared app used a different Xcode developer directory than the selected simulator SDK")
        graph_developer = ((prepared.get("sourceGraph") or {}).get("platformContext") or {}).get("developerDirectory")
        ensure(isinstance(graph_developer, str) and graph_developer
               and Path(graph_developer).resolve() == developer,
               "Prepared run context is missing or uses a different Xcode developer directory")
        _, catalog = commands.json([cli, "actions", *flags])
        ensure(catalog == prepared["catalog"], "actions differs from prepared catalog")
        def execute(plan, summary, expected=None, file=False):
            attempt, code, report = run_plan(commands, cli, support, output, plan)
            verify_report(report, summary, completed=summary != "timedOut")
            ensure(code == (0 if summary in ("passed", "executedUnassessed") else 1), "CLI exit status differs from assessment")
            if expected is not None:
                verify_echo(report, expected)
            if file:
                verify_file(report)
            verify_campaigns(support)
            _, saved = commands.json([cli, "show", attempt, *flags])
            ensure(saved == report, "Saved report differs from run output")
            print(f"Verified {plan['id']}: {summary}", flush=True)
            reports.append({"case": plan["id"], "attemptID": attempt, "summary": summary,
                            "exactOutputsCompared": expected is not None or file,
                            "codecFamiliesCompared": ["intentFile"] if file else sorted({
                                family.removeprefix("empty.") for family in expected or {}
                            })})
        # Generic simulator builds and toolchain validation need no running device.
        commands.run(["xcrun", "simctl", "boot", simulator])
        commands.run(["xcrun", "simctl", "bootstatus", simulator, "-b"], timeout=300)
        # Install once: reinstalling before each case invalidates the metadata index again.
        commands.run(["xcrun", "simctl", "install", simulator, prepared["host"]["subjectProductPath"]], timeout=180)
        wait_for_registration(commands, cli, support, output, prepared)
        for index, (operations, expected) in enumerate(echo_batches(catalog), 1):
            if f"codec-{index}" in selected:
                execute(case(prepared, f"codec-{index}", host_segment("subject", "subject", operations)),
                        "executedUnassessed", expected)
        if "codec-file" in selected:
            execute(file_case(prepared), "executedUnassessed", file=True)
        if "mixed" in selected:
            execute(mixed_case(prepared, "mixed"), "passed")
        if "wrong-assertion" in selected:
            execute(mixed_case(prepared, "wrong-assertion", expected=False), "assertionFailed")
        if "timeout" in selected:
            execute(timeout_case(prepared), "timedOut")
            operations, expected = echo_batches(catalog)[0]
            execute(case(prepared, "after-timeout", host_segment("subject", "subject", operations[:1])),
                    "executedUnassessed", {operations[0]["id"]: expected[operations[0]["id"]]})
        verify_scenario_selection(reports, scenario_group)
        return reports
    finally:
        if simulator:
            errors = []
            for verb in ("shutdown", "delete"):
                try:
                    commands.run(["xcrun", "simctl", verb, simulator], timeout=120,
                                 allowed=(0, 149) if verb == "shutdown" else (0,))
                except Exception as error:
                    errors.append(str(error))
            try:
                _, inventory = commands.json(["xcrun", "simctl", "list", "devices", "--json"])
                ensure(not any(d["udid"] == simulator for devices in inventory["devices"].values() for d in devices),
                       "Owned simulator remains after deletion")
            except Exception as error:
                errors.append(str(error))
            ensure(not errors, "Owned simulator cleanup failed: " + "; ".join(errors))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xcode", type=Path, help="Xcode.app or Contents/Developer")
    parser.add_argument("--output-root", type=Path, help="Fresh artifact directory outside the repository")
    parser.add_argument("--build-root", type=Path, help="Reusable Swift build cache outside the repository")
    parser.add_argument("--jobs", type=int, help="Swift build jobs (defaults to the runner CPU count)")
    parser.add_argument("--record-build-cache", action="store_true",
                        help="Checkpoint a successful CLI build for GitHub Actions cache saving")
    parser.add_argument("--scenario-group", choices=("all", *SCENARIO_GROUPS), default="all",
                        help="Independent scenario group; timeout and recovery always run together")
    args = parser.parse_args(argv)
    if args.jobs is not None and args.jobs < 1:
        parser.error("--jobs must be positive")
    output = (args.output_root or Path(tempfile.mkdtemp(prefix="intents-automation-e2e-"))).resolve()
    ensure(output != ROOT and ROOT not in output.parents, "Artifacts must stay outside the repository")
    ensure(not output.exists() or not any(output.iterdir()), "Output root must be empty")
    build_root = args.build_root.resolve() if args.build_root else None
    if build_root:
        ensure(build_root != ROOT and ROOT not in build_root.parents, "Build cache must stay outside the repository")
    output.mkdir(parents=True, exist_ok=True)
    developer = args.xcode
    if developer and developer.suffix == ".app":
        developer = developer / "Contents/Developer"
    print(f"Automation evidence: {output}", flush=True)
    summary = {"schemaVersion": 1, "status": "failed", "scenarioGroup": args.scenario_group,
               "echoAssessment": "executedUnassessed"}
    def interrupted(signum, frame):
        raise KeyboardInterrupt(f"Interrupted by signal {signum}")
    previous_term = signal.signal(signal.SIGTERM, interrupted)
    try:
        summary["cases"] = run_contract(Commands(output, developer), output, build_root=build_root,
                                        build_jobs=args.jobs, record_build_cache=args.record_build_cache,
                                        scenario_group=args.scenario_group)
        verify_scenario_selection(summary["cases"], args.scenario_group)
        compared = {family for report in summary["cases"] for family in report.get("codecFamiliesCompared", [])}
        summary.update(status="passed", codecFamiliesCompared=[family for family in FAMILIES if family in compared])
        print(f"Automation contract passed: {args.scenario_group}, {len(summary['cases'])} scenarios, "
              f"{len(summary['codecFamiliesCompared'])} codec families compared.")
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
