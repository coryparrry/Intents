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
import uuid

ROOT = Path(__file__).resolve().parents[1]
ARRAYS = ("textArray", "boolArray", "integerArray", "decimalArray", "dateArray")
FAMILIES = ("text", "bool", "integer", "decimal", "date", "enum", "entity", "duration",
            "calendarComponents", "url", "intentFile", *ARRAYS)
INTENTS = {f: "Echo" + f[0].upper() + f[1:] + "Intent" for f in FAMILIES}
INTENTS["url"] = "EchoURLIntent"
FILE_SHA = hashlib.sha256(b"phase3 fixture").hexdigest()


def ensure(condition, message):
    if not condition:
        raise AssertionError(message)


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
              "operation": identity, "inputs": {}, "effects": ["observe"] if query else ["observe", "fixtureWrite"],
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
        stdout = stem.with_suffix(".stdout.log").read_text()
        ensure(code in allowed, f"Command exited {code}: {arguments[0]}; see {stem}.stderr.log")
        return code, stdout

    def json(self, arguments, **options):
        code, raw = self.run(arguments, **options)
        return code, json.loads(raw)


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


def run_contract(commands, output, build_root=None):
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
        commands.run(["xcrun", "simctl", "boot", simulator])
        commands.run(["xcrun", "simctl", "bootstatus", simulator, "-b"], timeout=300)
        fixture = output / "AutomationFixture"
        shutil.copytree(ROOT / "examples/AutomationFixture", fixture)
        commands.run(["xcodegen", "generate", "--spec", fixture / "project.yml"], cwd=fixture)
        scratch = build_root or output / "swift-build"
        commands.run(["swift", "build", "--jobs", "2", "--scratch-path", scratch, "--product", "intents-automation"], timeout=900)
        _, bin_path = commands.run(["swift", "build", "--scratch-path", scratch, "--show-bin-path"])
        cli = Path(bin_path.strip()) / "intents-automation"
        support, reports = output / "support", []
        flags = ["--support-root", support]
        _, prepared = commands.json([cli, "prepare", "--project", fixture / "AutomationFixture.xcodeproj",
                                     "--scheme", "AutomationFixture", "--destination", "sim:" + simulator, *flags], timeout=1200)
        (output / "prepared.json").write_text(json.dumps(prepared, indent=2))
        _, catalog = commands.json([cli, "actions", *flags])
        ensure(catalog == prepared["catalog"], "actions differs from prepared catalog")
        def execute(plan, summary, expected=None, file=False):
            attempt = "phase3-" + uuid.uuid4().hex
            envelope = {"schemaVersion": 1, "attemptID": attempt, "allowBootAndInstall": True,
                        "disposable": True, "plan": plan}
            plan_path = output / (plan["id"] + ".json")
            plan_path.write_text(json.dumps(envelope, indent=2))
            code, report = commands.json([cli, "run", "--plan", plan_path, *flags], timeout=900, allowed=(0, 1))
            ensure(code == (0 if summary in ("passed", "executedUnassessed") else 1), "CLI exit status differs from assessment")
            verify_report(report, summary, completed=summary != "timedOut")
            if expected is not None:
                verify_echo(report, expected)
            if file:
                verify_file(report)
            verify_campaigns(support)
            _, saved = commands.json([cli, "show", attempt, *flags])
            ensure(saved == report, "Saved report differs from run output")
            reports.append({"case": plan["id"], "attemptID": attempt, "summary": summary,
                            "exactOutputsCompared": expected is not None or file})
        for index, (operations, expected) in enumerate(echo_batches(catalog), 1):
            execute(case(prepared, f"codec-{index}", host_segment("subject", "subject", operations)),
                    "executedUnassessed", expected)
        execute(file_case(prepared), "executedUnassessed", file=True)
        execute(mixed_case(prepared, "mixed"), "passed")
        commands.run(["xcrun", "simctl", "launch", simulator, prepared["host"]["app"]["bundleID"]])
        commands.run(["xcrun", "simctl", "io", simulator, "screenshot", output / "fixture.png"])
        execute(mixed_case(prepared, "wrong-assertion", expected=False), "assertionFailed")
        execute(timeout_case(prepared), "timedOut")
        operations, expected = echo_batches(catalog)[0]
        execute(case(prepared, "after-timeout", host_segment("subject", "subject", operations[:1])),
                "executedUnassessed", {operations[0]["id"]: expected[operations[0]["id"]]})
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
    args = parser.parse_args(argv)
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
    summary = {"schemaVersion": 1, "status": "failed", "echoAssessment": "executedUnassessed"}
    def interrupted(signum, frame):
        raise KeyboardInterrupt(f"Interrupted by signal {signum}")
    previous_term = signal.signal(signal.SIGTERM, interrupted)
    try:
        summary["cases"] = run_contract(Commands(output, developer), output, build_root=build_root)
        summary.update(status="passed", codecFamiliesCompared=list(FAMILIES))
        print("Automation contract passed: 16 codec families, mixed assessment, failure and timeout recovery.")
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
