#!/usr/bin/env python3
"""Write a data-only, explicitly scoped seeded-control engineering profile.

No build, device selection, installation, execution or imported-case approval occurs
here. The caller supplies the actual prepared simulator identity and runtime.
"""
import argparse
import json
import os
import re
from pathlib import Path
import uuid


def value(kind, value):
    return {"kind": kind, "value": value}


def segment(identifier, kind, phase, effects):
    return {"id": identifier, "kind": kind, "phase": phase, "operation": identifier,
            "inputs": {}, "requiredCapabilities": [], "effects": effects,
            "lifecycle": "persistedStateAcrossSegments"}


def requirement(identifier, observation, owner, property_name, expected):
    return {"checkID": identifier, "observationID": observation, "expected": expected,
            "proof": "appState", "justification": "Explicitly approved positive property of one actual owned query entity",
            "entityProperty": {"operationID": "tasks", "property": property_name,
                               "selection": {"typeID": "TaskEntity", "matchingProperties": {
                                   "title": value("text", "Send invoice"), "owner": value("text", owner)}}}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepared", required=True, type=Path)
    parser.add_argument("--support-root", required=True, type=Path)
    parser.add_argument("--runtime-app", required=True, type=Path)
    parser.add_argument("--runtime-team-id", required=True)
    parser.add_argument("--attempt-id", required=True)
    parser.add_argument("--mode", choices=["correct", "wrong-record", "missing-save", "intermittent"], required=True)
    parser.add_argument("--revision", type=int, default=3)
    parser.add_argument("--keep-control", action="store_true", help="Verify the existing intermittent mode without restarting its counter")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 3 <= args.revision <= 100000 or not re.fullmatch(r"[A-Za-z0-9-]{1,128}", args.attempt_id):
        parser.error("Use a bounded attempt ID and a new case revision (3 or later).")
    if not re.fullmatch(r"[A-Z0-9]{10}", args.runtime_team_id) or (args.keep_control and args.mode != "intermittent"):
        parser.error("Use the exact runtime team; --keep-control only applies to intermittent repetitions.")
    try:
        if args.prepared.stat().st_size > 16 * 1024 * 1024:
            raise ValueError("Prepared application is oversized")
        prepared = json.loads(args.prepared.read_text())
        app, target = prepared["host"]["app"], prepared["host"]["target"]
        if app["bundleID"] != "com.coryparry.IntentsAutomation.DuplicateTasks" or app["platform"] != "ios" or target["kind"] != "simulator":
            raise ValueError("Select the actual prepared seeded iOS simulator app")
        uuid.UUID(target["id"])
        if not any(action["id"] == "CompleteTaskIntent" and action["compiled"] is True for action in prepared["catalog"]["systemActions"]):
            raise ValueError("Compiled CompleteTaskIntent is unavailable")
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.error(str(error))
    environment = "owned-seeded-duplicate-tasks:" + target["id"]
    effects = ["observe", "navigate", "fixtureWrite", "reset"]
    setup = segment("create-fixtures", "ui", "setup", effects)
    def tap(identifier, kind, label):
        return {"id": identifier, "kind": "tap", "locator": {"kind": kind, "value": label}}
    operations = [tap("reset", "testId", "fixture.reset")]
    if not args.keep_control:
        title = {"correct": "Correct", "wrong-record": "Wrong record", "missing-save": "Missing save", "intermittent": "Intermittent"}[args.mode]
        selected = tap("choose-control", "label", title)
        selected["locator"]["role"] = "button"
        operations += [tap("open-control", "testId", "fixture.control"), selected]
    operations += [{"id": "title", "kind": "fillBinding", "locator": {"kind": "testId", "value": "task.title"}, "binding": "title"},
                   tap("work", "label", "Work"), tap("add-work", "testId", "task.add"),
                   tap("personal", "label", "Personal"), tap("add-personal", "testId", "task.add")]
    setup["uiProgram"] = {"operations": operations, "bindings": {"title": "Send invoice"}, "timeoutMilliseconds": 120000}
    query = {"id": "tasks", "kind": "query", "typeID": "TaskEntity", "parameters": {}, "queryText": "Send invoice",
             "properties": {"title": "text", "owner": "text", "completed": "bool", "control": "text"}}
    lookup = segment("lookup-fixture", "systemQuery", "setup", ["observe", "navigate"])
    lookup["hostProgram"] = {"operations": [query]}
    subject = segment("subject", "systemIntent", "subject", ["observe", "navigate", "fixtureWrite"])
    subject["requiredCapabilities"] = ["apple.intent.invoke"]
    subject["hostProgram"] = {"operations": [{"id": "complete", "kind": "invoke", "typeID": "CompleteTaskIntent", "parameters": {}, "resultCodec": "noValue"}]}
    subject["inputBindings"] = [{"producerSegmentID": lookup["id"], "outputID": "tasks", "destination": "hostParameter",
                                  "operationID": "complete", "name": "task", "uniqueEntity": {
                                      "typeID": "TaskEntity", "matchingProperties": {
                                          "title": value("text", "Send invoice"), "owner": value("text", "Personal"), "completed": value("bool", False)}}}]
    observer = segment("independent-state", "systemQuery", "observe", ["observe", "navigate"])
    observer["hostProgram"] = {"operations": [query]}
    checks = [requirement("fixture." + owner.lower(), lookup["id"], owner, "completed", value("bool", False)) for owner in ["Personal", "Work"]]
    checks.append(requirement("fixture.control", lookup["id"], "Personal", "control", value("text", args.mode)))
    requirements = [requirement("business.personal.completed", observer["id"], "Personal", "completed", value("bool", True)),
                    requirement("business.work.unchanged", observer["id"], "Work", "completed", value("bool", False))]
    plan = {"schemaVersion": 3, "id": "seeded.duplicate-tasks." + args.mode + (".continuation" if args.keep_control else ""), "revision": args.revision,
            "app": app, "target": target, "environmentID": environment, "setup": [setup, lookup],
            "execution": subject, "observations": [observer], "requirements": requirements, "setupChecks": checks,
            "cleanup": [], "budget": {"subjectOperations": 1, "attempts": 1, "uiActions": 30, "controllerCalls": 0, "wallClockSeconds": 540},
            "provenance": {"purpose": "Seeded engineering control; same independent assertions across modes; no broad app qualification",
                           "control": args.mode, "ui.locale": "en_GB"}}
    approval = {"runID": args.attempt_id + "-run", "app": app, "target": target, "environmentID": environment,
                "effects": effects, "maximumActions": 30, "disposable": True}
    profile = {"preparedPath": str(args.prepared.resolve()), "actionID": "CompleteTaskIntent", "inputs": {},
               "declaredEffects": {"app": app, "actionID": "CompleteTaskIntent", "effects": effects,
                                   "developerConfirmation": "Approved synthetic owned tasks only"},
               "approval": approval, "capabilities": {"records": {"apple.intent.invoke": {
                   "state": "available", "reason": "Genuine associated host built; runtime invocation remains to be proved",
                   "probeVersion": "host-v2", "evidence": [prepared["host"]["xctestrunDigest"]]}}},
               "attemptID": args.attempt_id, "supportRoot": str(args.support_root.resolve()),
               "developerDirectory": "/Applications/Xcode.app/Contents/Developer", "allowBootAndInstall": True,
               "plan": plan, "runtimeBundlePath": str(args.runtime_app.resolve()), "runtimeTeamID": args.runtime_team_id,
               "approveExactCase": True}
    with os.fdopen(os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
        json.dump(profile, output, indent=2)


if __name__ == "__main__":
    main()
