#!/usr/bin/env python3
"""Validate the real process protocol; --infer also requires successful model access."""
import json
import subprocess
import sys

binary = sys.argv[1]
require_inference = "--infer" in sys.argv[2:]


def invoke(payload):
    result = subprocess.run([binary], input=json.dumps(payload), text=True,
                            capture_output=True, timeout=60, check=True)
    assert len(result.stdout.strip().splitlines()) == 1, result.stdout
    return json.loads(result.stdout), result.stderr


availability, diagnostics = invoke({"operation": "availability"})
assert isinstance(availability["available"], bool)
assert availability["model"] == "Apple Foundation Models"
assert availability["osVersion"]
assert not diagnostics
if not availability["available"]:
    assert availability["reason"]

invalid, diagnostics = invoke({"operation": "evaluate"})
assert invalid["status"] == "failed"
assert invalid["error"]["kind"] == "invalidInput"
assert invalid["results"] == []
assert "invalidInput" in diagnostics

request = {"operation": "evaluate", "instructions": "Follow the prompt precisely.",
           "cases": [{"id": "smoke", "prompt": "Reply with exactly READY",
                      "expected": "READY", "scoring": "exact"}],
           "repetitions": 2, "temperature": 0, "maxTokens": 16}
run, diagnostics = invoke(request)
assert not diagnostics
assert run["status"] in ("completed", "failed")
assert run["durationMs"] >= 0
assert run["startedAt"] and run["finishedAt"]
if not availability["available"]:
    assert run["status"] == "failed"
    assert run["error"]["kind"] == "modelUnavailable"
    assert run["results"] == []
else:
    # Both repetitions are recorded even if a real model service error occurs.
    assert len(run["results"]) == 2
    for repetition, result in enumerate(run["results"], 1):
        assert result["caseId"] == "smoke" and result["repetition"] == repetition
        assert isinstance(result["trace"]["transcript"], list)
        if "error" in result["trace"]:
            assert result["passed"] is False and result["score"] == 0
        else:
            roles = [entry.get("role") for entry in result["trace"]["transcript"]]
            assert roles == ["instructions", "user", "response"], roles
            user = result["trace"]["transcript"][1]
            assert user["options"]["greedy"] is True
            assert result["passed"] == (result["response"] == "READY")
            assert result["score"] == int(result["passed"])
    if require_inference:
        assert run["status"] == "completed", run.get("error")
        assert all(result["passed"] for result in run["results"]), run["results"]
print("Native process protocol: passed; availability=" + str(availability["available"])
      + "; inference=" + run["status"])
