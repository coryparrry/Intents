#!/usr/bin/env python3
"""Exercise an already-running isolated Intents MCP server. Never prints its token.

Set MCP_AUTHORIZATION to its existing bearer credential. Requires the caller to
launch the test app with an isolated --evaluation-storage directory first.
The 100-row check retains synthetic captured outputs; --native also performs one
real on-device response. No external judge or remote provider is selected.
"""
import argparse
import base64
import hashlib
import json
import os
import time
import urllib.request
import urllib.error
import urllib.parse
import uuid

class Client:
    def __init__(self, endpoint, token):
        parsed=urllib.parse.urlsplit(endpoint)
        if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1","localhost","::1") or parsed.path != "/mcp":
            raise ValueError("Verification only sends credentials to a localhost /mcp endpoint")
        self.endpoint, self.token, self.sequence, self.checks = endpoint, token, 0, 0

    def rpc(self, method, params):
        self.sequence += 1
        body = json.dumps(dict(jsonrpc="2.0", id=self.sequence, method=method, params=params)).encode()
        request = urllib.request.Request(self.endpoint, data=body, headers={
            "Authorization": "Bearer " + self.token, "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream", "MCP-Protocol-Version": "2025-06-18"})
        with urllib.request.urlopen(request, timeout=60) as response:
            value = json.load(response)
        if "error" in value:
            if method == "tools/call":
                return dict(isError=True,structuredContent=dict(error=value["error"]))
            raise AssertionError(value["error"])
        return value["result"]

    def call(self, name, fields=None, failure=False):
        value = self.rpc("tools/call", dict(name=name, arguments=fields or {}))
        self.check(bool(value.get("isError", False)) == failure, name + " error expectation")
        return value.get("structuredContent", {})

    def write(self, name, fields=None, **kw):
        fields = dict(fields or {})
        fields.setdefault("operationID", str(uuid.uuid4()))
        return self.call(name, fields, **kw)

    def check(self, condition, label):
        if not condition:
            raise AssertionError(label)
        self.checks += 1

    def state(self):
        return self.call("eval_workspace_state")

    def workspace(self, extra=None):
        state = self.state()
        fields = dict(expectedWorkspaceRevision=state["workspaceRevision"])
        fields.update(extra or {})
        return fields

    def target(self):
        state = self.state()
        return dict(projectID=state["projectID"], suiteID=state["suiteID"], expectedRevision=state["revision"])

    def wait_job(self, job_id, expected, operation):
        deadline = time.monotonic() + 240
        while time.monotonic() < deadline:
            value = self.call("eval_production_job_get", dict(jobID=job_id))
            status = self.call("eval_operation_status", dict(operationID=operation))
            self.check(not status["interrupted"], "active/completed batch is not interrupted")
            if not value["runningOnThisMac"] and status["receipt"]["phase"] in ("completed", "failed"):
                self.check(value["report"]["completed"] == expected, "all planned outputs retained")
                self.check(status["receipt"]["phase"] == "completed", "successful terminal receipt")
                self.check(value["executionError"] is None, "no batch executor failure")
                return value
            time.sleep(0.25)
        raise AssertionError("batch timeout")


def verify(client, native=False):
    deadline = time.monotonic() + 20
    while True:
        try:
            init = client.rpc("initialize", dict(protocolVersion="2025-06-18", capabilities={}, clientInfo=dict(name="mcp-control-verification", version="1")))
            break
        except urllib.error.URLError as error:
            if not isinstance(error.reason, ConnectionRefusedError) or time.monotonic() >= deadline:
                raise
            time.sleep(0.25)
    tools = client.rpc("tools/list", {})["tools"]
    names = {tool["name"] for tool in tools}
    client.check(len(names) == len(tools), "unique tool discovery")
    for name in ("eval_project_create", "eval_suite_configure", "eval_production_upload_begin", "eval_production_job_start", "eval_runner_select", "eval_intent_install_preview", "eval_intent_run"):
        client.check(name in names, "workflow discovery: " + name)
    client.check("eval_production_upload_begin" in init["instructions"], "batch instructions")
    # Retry identity and stale revision through the actual HTTP connector.
    request = client.workspace(dict(name="MCP verification", operationID=str(uuid.uuid4())))
    first = client.call("eval_project_create", request)
    replay = client.call("eval_project_create", request)
    client.check(first["createdProjectID"] == replay["createdProjectID"] and replay["duplicate"], "one project after lost-reply retry")
    client.call("eval_project_create", dict(request, operationID=str(uuid.uuid4())), failure=True)
    rename=client.target();rename.pop("expectedRevision")
    client.write("eval_suite_rename", client.workspace(dict(rename, name="MCP controlled suite")))
    client.write("eval_workspace_navigate", client.workspace(dict(section="batchRuns", pane="jobs")))
    client.call("eval_production_upload_chunk", dict(operationID=str(uuid.uuid4()), uploadID=str(uuid.uuid4()), index=0.5, dataBase64="YQ=="), failure=True)
    # 100 different original outputs, split across byte chunks, with exact source hash.
    source = b"".join(json.dumps(dict(id=f"case-{i}", sourceID=f"source-{i}", prompt=f"Different task {i}", capturedOutput=f"original-output-{i}", metadata={"task":f"task-{i % 5}"}), separators=(",", ":")).encode() + b"\n" for i in range(100))
    upload, sha = str(uuid.uuid4()), hashlib.sha256(source).hexdigest()
    client.write("eval_production_upload_begin", dict(uploadID=upload, name="100 distinct captured outputs", version="1", chunks=2, bytes=len(source), sha256=sha))
    split = len(source) // 2
    chunk = dict(uploadID=upload, index=0, dataBase64=base64.b64encode(source[:split]).decode(), operationID=str(uuid.uuid4()))
    client.call("eval_production_upload_chunk", chunk)
    client.check(client.call("eval_production_upload_chunk", chunk)["duplicate"], "identical chunk receipt")
    client.write("eval_production_upload_finish", dict(uploadID=upload, previewDigest=sha), failure=True)
    client.write("eval_production_upload_chunk", dict(uploadID=upload, index=1, dataBase64=base64.b64encode(source[split:]).decode()))
    preview = client.write("eval_production_upload_preview", dict(uploadID=upload))
    client.check(len(preview["examples"]) == 3 and preview["previewDigest"] == sha, "verified bounded preview")
    dataset = client.write("eval_production_upload_finish", dict(uploadID=upload, previewDigest=sha))["dataset"]
    client.check(dataset["count"] == 100, "100 imported examples")
    job_id = str(uuid.uuid4())
    create = client.write("eval_production_job_create", dict(client.target(), jobID=job_id, datasetRevision=dataset["revision"], name="MCP 100 captured", kind="captured"))
    revision = create["jobRevision"]
    operation = str(uuid.uuid4())
    client.call("eval_production_job_start", dict(jobID=job_id, expectedJobRevision=revision, operationID=operation))
    job = client.wait_job(job_id, 100, operation)
    client.check(job["report"]["counts"]["unscored"] == 100, "captured outputs do not manufacture pass labels")
    rows = client.call("eval_production_results", dict(jobID=job_id, limit=100))["records"]
    client.check(len({r["response"]["output"] for r in rows}) == 100, "100 distinct original outputs")
    detail = client.call("eval_production_result_get", dict(jobID=job_id, slot=99))
    client.check(detail["record"]["response"]["output"] == "original-output-99", "exact final output")
    client.write("eval_production_job_control", dict(jobID=job_id, expectedJobRevision=revision, expectedControlRevision=job["controlRevision"], paused=True))
    client.write("eval_production_job_control", dict(jobID=job_id, expectedJobRevision=revision, expectedControlRevision=job["controlRevision"], paused=False), failure=True)
    current = client.call("eval_production_job_get", dict(jobID=job_id))
    client.write("eval_production_job_control", dict(jobID=job_id, expectedJobRevision=revision, expectedControlRevision=current["controlRevision"], paused=False))
    clone = client.write("eval_production_job_clone", dict(jobID=job_id, expectedJobRevision=revision, newJobID=str(uuid.uuid4()), name="MCP repeat"))
    schedule = dict(id=str(uuid.uuid4()), templateJobID=clone["jobID"], intervalSeconds=60, nextRun=int(time.time()*1000)-1000, remainingRuns=1, paused=False)
    client.write("eval_production_schedule_save", dict(scheduleJSON=json.dumps(schedule), expectedScheduleRevision="absent", confirm=True))
    client.check(len(client.write("eval_production_schedule_tick")["createdJobIDs"]) == 1, "schedule creates one job")
    client.check(not client.write("eval_production_schedule_tick")["createdJobIDs"], "schedule tick retry has no duplicate")
    bad_schedule = dict(schedule, id=str(uuid.uuid4()), nextRun=1e30)
    client.write("eval_production_schedule_save", dict(scheduleJSON=json.dumps(bad_schedule), expectedScheduleRevision="absent", confirm=True), failure=True)
    exported = client.write("eval_production_export", dict(jobID=job_id, expectedJobRevision=revision))["exportID"]
    files = []
    while True:
        page = client.call("eval_production_export_list", dict(exportID=exported, offset=len(files), limit=100))
        files.extend(page["files"])
        if len(files) >= page["count"]:
            break
        client.check(bool(page["files"]), "export pagination makes progress")
    client.check(len(files) == page["count"] and len(set(files)) == len(files), "complete export manifest")
    client.check("report.json" in files, "export report manifest")
    part = client.call("eval_production_export_read", dict(exportID=exported, path="report.json"))
    client.check(json.loads(base64.b64decode(part["dataBase64"]))["completed"] == 100, "downloaded coherent report")
    client.call("eval_production_export_read", dict(exportID=exported, path="../.store.lock"), failure=True)
    client.call("eval_runner_state")
    lab = client.call("eval_intent_state")
    client.write("eval_intent_new", dict(expectedIntentRevision=lab["intentRevision"]))
    lab = client.call("eval_intent_state")
    # Approval denial reaches a durable failed receipt; no project build occurs.
    op = str(uuid.uuid4())
    client.call("eval_intent_build", dict(expectedIntentRevision=lab["intentRevision"], confirm=False, operationID=op))
    deadline = time.monotonic()+10
    while time.monotonic()<deadline:
        receipt=client.call("eval_operation_status",dict(operationID=op))["receipt"]
        if receipt["phase"] == "failed":
            break
        time.sleep(0.1)
    client.check(receipt["phase"] == "failed", "unapproved build fails durably")
    if native:
        state = client.state()
        suite = state["suite"]
        case = suite["cases"][0]
        case.update(id=str(uuid.uuid4()), name="Real Apple smoke", prompt="Reply with the single word Friday.", expected="Friday")
        suite.update(cases=[case], repetitions=1, scoringMode="containsExpected")
        suite["modelConfiguration"]["provider"] = "onDevice"
        client.write("eval_suite_configure", client.workspace(dict(client.target(), suiteJSON=json.dumps(suite), confirmDeletes=True)))
        snapshot = client.write("eval_production_dataset_snapshot", client.target())["dataset"]
        real_id = str(uuid.uuid4())
        frozen = client.write("eval_production_job_create",dict(client.target(),jobID=real_id,datasetRevision=snapshot["revision"],name="MCP real Apple smoke",kind="native"))
        real_op = str(uuid.uuid4())
        client.call("eval_production_job_start",dict(jobID=real_id,expectedJobRevision=frozen["jobRevision"],operationID=real_op))
        real = client.wait_job(real_id,1,real_op)
        client.check(real["report"]["counts"]["passed"]==1,"real Apple response passes exact retained criterion")
        client.write("eval_workspace_navigate",client.workspace(dict(section="batchRuns",pane="reports",jobID=real_id)))
    print(json.dumps(dict(checks=client.checks, tools=len(tools), capturedOutputs=100, realAppleResponses=1 if native else 0, capturedJobID=job_id, datasetRevision=dataset["revision"]),indent=2))

if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint",default="http://127.0.0.1:17873/mcp")
    parser.add_argument("--native",action="store_true")
    args=parser.parse_args()
    token=os.environ.get("MCP_AUTHORIZATION")
    if not token:
        parser.error("MCP_AUTHORIZATION must contain the existing test-app credential")
    verify(Client(args.endpoint,token),args.native)
