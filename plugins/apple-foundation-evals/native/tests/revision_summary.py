#!/usr/bin/env python3
"""Pure-data regression checks against the actual native engine; no inference.

Historical runs here are synthetic policy fixtures, never model evidence.
"""
import argparse
import copy
import hashlib
import json
import subprocess
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("binary")
parser.add_argument("--only", choices=("all", "reference", "summary"), default="all")
args = parser.parse_args()
checks = 0

def check(condition, detail=""):
    global checks
    assert condition, detail
    checks += 1

def uid(): return str(uuid.uuid4())
def invoke(request):
    process = subprocess.run([args.binary], input=json.dumps(request), text=True,
                             capture_output=True, timeout=60, check=True)
    check(len(process.stdout.strip().splitlines()) == 1, process.stdout[:500])
    return json.loads(process.stdout)

def base():
    suite = invoke({"operation": "suite-defaults"})
    suite.update(name="Synthetic native workflow regression", instructions="Use the reference.",
                 scoringMode="exactMatch", criteria="", repetitions=1,
                 cases=[{"id": uid(), "name": "Reference", "prompt": "Return the release code.", "expected": "ORANGE"}])
    suite["modelConfiguration"].update(samplingMode="greedy", maximumResponseTokens=128)
    suite["releasePolicy"].update(required=True, criticalCaseIDs=[suite["cases"][0]["id"]],
                                 requireApprovedBaseline=False, maximumErrorCount=0)
    return suite

def historical_run(suite, revision="synthetic", passed=True):
    return {"id": uid(), "suiteID": suite["id"], "suiteName": suite["name"], "suiteVersion": suite["version"],
            "instructions": suite["instructions"], "criteria": suite["criteria"], "scoringMode": suite["scoringMode"],
            "repetitions": suite["repetitions"], "plannedSampleCount": len(suite["cases"]),
            "suiteRevision": revision, "plannedCases": copy.deepcopy(suite["cases"]),
            "startedAt": "2026-10-15T00:00:00Z", "completedAt": "2026-10-15T00:00:01Z", "cancelled": False,
            "environment": {"operatingSystem": "Synthetic fixture", "locale": "en_GB", "model": "Synthetic fixture", "modelContextSize": 4096},
            "attachments": [{key: attachment[key] for key in ("name", "kind", "byteCount", "sha256")} for attachment in suite["attachments"]],
            "results": [{"id": uid(), "caseID": case["id"], "caseName": case["name"], "repetition": 1,
                         "prompt": case["prompt"], "expected": case["expected"], "response": case["expected"] if passed else "WRONG",
                         "status": "passed" if passed else "failed", "durationMilliseconds": 1,
                         "usage": {"inputTokens": 0, "cachedInputTokens": 0, "outputTokens": 0, "reasoningTokens": 0}}
                        for case in suite["cases"]]}

def rejected_summary(current, candidate):
    value = invoke({"operation": "summarize-experiment", "current": current, "candidate": candidate})
    check(value.get("status") == "failed" and value.get("error", {}).get("kind") == "invalidInput", value)

if args.only in ("all", "reference"):
    suite = base()
    text = "The release code is ORANGE."
    original_bytes = b"Synthetic original PDF bytes before extraction"
    digest = hashlib.sha256(original_bytes).hexdigest()
    suite["attachments"] = [{"id": uid(), "name": "reference.pdf", "kind": "text", "text": text,
                             "storedFilename": digest + ".pdf", "byteCount": len(original_bytes), "sha256": digest}]
    before = invoke({"operation": "validate-suite", "suite": suite})
    check(before.get("valid"), before)
    edited = copy.deepcopy(suite)
    edited["attachments"][0]["text"] = "The release code is PURPLE."
    after = invoke({"operation": "validate-suite", "suite": edited})
    check(after.get("valid"), after)
    check(before["revision"] != after["revision"], "Executed extracted text must change native revision independently of original-file metadata")
    run = historical_run(suite, before["revision"])
    project_id = uid()
    control = invoke({"operation": "release-check", "projectID": project_id, "suite": suite, "run": run})
    stale = invoke({"operation": "release-check", "projectID": project_id, "suite": edited, "run": run})
    check(control["report"]["outcome"] == 0, control)
    check(stale["report"]["outcome"] == 20, stale)
    check(any("stale" in reason for reason in stale["report"]["failures"]), stale)
    project = invoke({"operation": "project-release-check", "projectID": project_id,
                      "suites": [{"suiteID": suite["id"], "suiteName": suite["name"], "required": True, "report": stale["report"]}]})
    check(project["report"]["outcome"] == 20, project)
    # Re-run against the changed grounding is valid; original byte metadata is
    # deliberately not a hash/size of extracted (possibly truncated/PDF) text.
    refreshed = historical_run(edited, after["revision"])
    fresh_report = invoke({"operation": "release-check", "projectID": project_id, "suite": edited, "run": refreshed})
    check(fresh_report["report"]["outcome"] == 0, fresh_report)

if args.only in ("all", "summary"):
    suite = base()
    suite["cases"] = [{"id": uid(), "name": str(index), "prompt": "Return code " + str(index), "expected": "READY"} for index in range(8)]
    current = historical_run(suite, passed=False)
    candidate = historical_run(suite, passed=True)
    candidate["instructions"] = "Candidate instructions may legitimately differ."
    summary = invoke({"operation": "summarize-experiment", "current": current, "candidate": candidate})
    check(summary.get("suggestedDecision") == "adoptCandidate", summary)
    check(summary["distinctCaseCoverage"] == 8)
    for field, changed in (("prompt", "Changed test"), ("expected", "Changed expected answer")):
        incompatible = copy.deepcopy(candidate)
        for case, sample in zip(incompatible["plannedCases"], incompatible["results"]):
            case[field] = changed
            sample[field] = changed
        rejected_summary(current, incompatible)
    incompatible = copy.deepcopy(candidate)
    incompatible["scoringMode"] = "containsExpected"
    rejected_summary(current, incompatible)
    incompatible = copy.deepcopy(candidate)
    incompatible["plannedCases"][0]["conversation"] = {"setupTurns": [{"id": uid(), "prompt": "Changed setup"}], "historyPolicy": "keepAll", "retainedTurnCount": 2}
    rejected_summary(current, incompatible)
    incompatible = copy.deepcopy(candidate)
    incompatible["plannedCases"][0]["fieldAssertions"] = [{"id": uid(), "pointer": "/answer", "operation": "equals", "expectedValue": '"READY"'}]
    rejected_summary(current, incompatible)
    incompatible = copy.deepcopy(candidate)
    incompatible["suiteID"] = uid()
    rejected_summary(current, incompatible)
    missing = copy.deepcopy(candidate)
    missing.pop("plannedCases")
    rejected_summary(current, missing)
    # Same-suite model rubric runs also allow instruction tuning; changes to
    # rubric, judge prompt policy, or passing threshold must reject comparison.
    judged_current = copy.deepcopy(current)
    judged_candidate = copy.deepcopy(candidate)
    legacy_judge = {"mode": "sameModel", "connectionName": "Same model", "requestedModelID": "synthetic", "provider": "onDevice", "providerOrder": []}
    for run in (judged_current, judged_candidate):
        run.update(scoringMode="modelJudge", criteria="The requested word is supplied.", judgePromptVersion="policy-v1", judgePassingScore=3)
        for sample in run["results"]:
            sample["judgeIdentity"] = copy.deepcopy(legacy_judge)
    control = invoke({"operation": "summarize-experiment", "current": judged_current, "candidate": judged_candidate})
    check(control.get("suggestedDecision") == "adoptCandidate", control)
    for field, value in (("criteria", "A different rubric."), ("judgePromptVersion", "policy-v2"), ("judgePassingScore", 4)):
        incompatible = copy.deepcopy(judged_candidate)
        incompatible[field] = value
        rejected_summary(judged_current, incompatible)
    # Reassessed instruction variants use their selected scoring policy, even
    # when that policy differs from the original run's rubric.
    selected_current = copy.deepcopy(judged_current)
    selected_candidate = copy.deepcopy(judged_candidate)
    for run in (selected_current, selected_candidate):
        assessment_id = uid()
        judge = copy.deepcopy(legacy_judge)
        run["selectedAssessmentID"] = assessment_id
        run["assessments"] = [{"id": assessment_id, "runID": run["id"], "createdAt": "2026-10-15T00:00:02Z", "origin": "reassessment",
                               "judge": judge, "promptVersion": "reassessed-policy", "rubric": "The response follows the requested format.", "passingScore": 3,
                               "samples": [{"id": uid(), "sampleID": sample["id"], "status": sample["status"]} for sample in run["results"]],
                               "durationMilliseconds": 0, "cost": {"availability": "known", "usd": 0, "explanation": "Synthetic fixture"}}]
    control = invoke({"operation": "summarize-experiment", "current": selected_current, "candidate": selected_candidate})
    check(control.get("suggestedDecision") == "adoptCandidate", control)
    incompatible = copy.deepcopy(selected_candidate)
    incompatible["assessments"][0]["rubric"] = "A different selected rubric."
    rejected_summary(selected_current, incompatible)
    incompatible = copy.deepcopy(selected_candidate)
    incompatible["assessments"][0]["judge"]["requestedModelID"] = "another-judge"
    rejected_summary(selected_current, incompatible)
    # Reassessment can legitimately attach a modelJudge score set to a run
    # originally collected under deterministic scoring. Compare selected policy
    # on both sides, including the implicit last-assessment selection path.
    deterministic_selected_current = copy.deepcopy(selected_current)
    deterministic_selected_candidate = copy.deepcopy(selected_candidate)
    selected_approval = invoke({"operation": "approve-baseline", "suite": suite, "run": selected_current})
    check(selected_approval["scoringContract"]["scoringMode"] == "modelJudge", selected_approval)
    for run in (deterministic_selected_current, deterministic_selected_candidate):
        run["scoringMode"] = "exactMatch"
        run["assessments"][0]["scoringContract"] = copy.deepcopy(selected_approval["scoringContract"])
    rejected_summary(current, deterministic_selected_candidate)
    control = invoke({"operation": "summarize-experiment", "current": deterministic_selected_current,
                      "candidate": deterministic_selected_candidate})
    check(control.get("suggestedDecision") == "adoptCandidate", control)
    implicit_current = copy.deepcopy(deterministic_selected_current)
    implicit_candidate = copy.deepcopy(deterministic_selected_candidate)
    implicit_current.pop("selectedAssessmentID")
    implicit_candidate.pop("selectedAssessmentID")
    control = invoke({"operation": "summarize-experiment", "current": implicit_current, "candidate": implicit_candidate})
    check(control.get("suggestedDecision") == "adoptCandidate", control)
    rejected_summary(current, implicit_candidate)
    unavailable_selection = copy.deepcopy(candidate)
    unavailable_selection["selectedAssessmentID"] = uid()
    rejected_summary(current, unavailable_selection)
    # The original deterministic scoring contract is valid by itself, but
    # contradicts the selected rubric assessment and must not be trusted there.
    approval = invoke({"operation": "approve-baseline", "suite": suite, "run": current})
    check(approval["scoringContract"]["scoringMode"] == "exactMatch", approval)
    contradictory_capture = copy.deepcopy(deterministic_selected_candidate)
    contradictory_capture["assessments"][0]["scoringContract"] = approval["scoringContract"]
    rejected_summary(deterministic_selected_current, contradictory_capture)
    # Original legacy score sets and selected assessments must resolve the
    # same effective judge; known conflicts cannot hide behind missing wrappers.
    incompatible = copy.deepcopy(judged_candidate)
    for sample in incompatible["results"]:
        sample["judgeIdentity"]["requestedModelID"] = "different-legacy-judge"
    rejected_summary(judged_current, incompatible)
    mixed = copy.deepcopy(judged_candidate)
    mixed["results"][0]["judgeIdentity"]["requestedModelID"] = "one-conflicting-judge"
    rejected_summary(judged_current, mixed)
    unknown = copy.deepcopy(judged_candidate)
    unknown["results"][0].pop("judgeIdentity")
    rejected_summary(judged_current, unknown)
    unsupported = copy.deepcopy(judged_candidate)
    for sample in unsupported["results"]:
        sample["judgeIdentity"]["provider"] = "customHTTP"
    rejected_summary(judged_current, unsupported)
    hybrid = copy.deepcopy(selected_candidate)
    hybrid_assessment = hybrid["assessments"][0]
    hybrid_assessment.update(rubric=judged_current["criteria"], promptVersion=judged_current["judgePromptVersion"], passingScore=judged_current["judgePassingScore"])
    control = invoke({"operation": "summarize-experiment", "current": judged_current, "candidate": hybrid})
    check(control.get("suggestedDecision") == "adoptCandidate", control)
    hybrid_assessment["judge"]["requestedModelID"] = "different-selected-judge"
    rejected_summary(judged_current, hybrid)
    # Explicit objective rubrics legitimately have no model judge identity.
    no_model_current = copy.deepcopy(judged_current)
    no_model_candidate = copy.deepcopy(judged_candidate)
    no_model_judge = {"mode": "sameModel", "connectionName": "Deterministic checks", "requestedModelID": "none", "provider": "local", "providerOrder": []}
    for run in (no_model_current, no_model_candidate):
        run["criteria"] = 'exact: "READY"'
        for sample in run["results"]:
            sample["judgeIdentity"] = copy.deepcopy(no_model_judge)
    control = invoke({"operation": "summarize-experiment", "current": no_model_current, "candidate": no_model_candidate})
    check(control.get("suggestedDecision") == "adoptCandidate", control)
    contradiction = copy.deepcopy(no_model_candidate)
    contradiction["criteria"] = judged_current["criteria"]
    contradictory_current = copy.deepcopy(no_model_current)
    contradictory_current["criteria"] = judged_current["criteria"]
    rejected_summary(contradictory_current, contradiction)
    # Incomplete matching variants retain the analyzer's collect-more decision.
    incomplete = copy.deepcopy(candidate)
    incomplete["results"].pop()
    summary = invoke({"operation": "summarize-experiment", "current": current, "candidate": incomplete})
    check(summary.get("suggestedDecision") == "collectMoreEvidence", summary)

print(f"Native revision/summary protocol: {checks} assertions passed; scope={args.only}; inference=False")
