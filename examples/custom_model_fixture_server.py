#!/usr/bin/env python3
"""Deterministic protocol fixture for EvaluationHTTPLanguageModel.

This is not an inference backend. It emits fixed, bounded NDJSON scenarios so the
Foundation Evals custom-provider UI can exercise text, guided output, reasoning,
tool continuation, failures, timeout, and cancellation.
"""

from __future__ import annotations

import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


HOST = "127.0.0.1"
PORT = 19096
MAX_REQUEST_BYTES = 8 * 1024 * 1024
STREAM_DELAY_SECONDS = 2.0
TIMEOUT_DELAY_SECONDS = 5.0
CANCEL_DELAY_SECONDS = 20.0

ROUTES = {
    "/generate",
    "/text",
    "/guided",
    "/guided/simple",
    "/guided/stream",
    "/guided/order",
    "/reasoning",
    "/tool",
    "/tool/execute",
    "/malformed",
    "/error",
    "/http-error",
    "/timeout",
    "/cancel",
    "/redirect",
}

SIMPLE_GUIDED_PAYLOAD = {"answer": "fixture"}
ORDER_GUIDED_PAYLOAD = {
    "order": {
        "id": "A-104",
        "status": "shipped",
        "items": [
            {"sku": "SKU-RED", "quantity": 2},
            {"sku": "SKU-BLUE", "quantity": 1},
        ],
    },
    "summary": "Order A-104 is shipped with 3 items.",
}


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        server_address: tuple[str, int],
        request_log: Path | None = None,
    ) -> None:
        super().__init__(server_address, FixtureHandler)
        self.request_log = request_log
        self.request_log_lock = threading.Lock()

    def record_protocol_request(self, request: dict[str, Any]) -> None:
        if self.request_log is None:
            return
        encoded = json.dumps(
            request,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        if len(encoded) > MAX_REQUEST_BYTES:
            raise ValueError("canonical request exceeds the request size limit")
        with self.request_log_lock:
            with self.request_log.open("ab") as log:
                log.write(encoded + b"\n")


class FixtureHandler(BaseHTTPRequestHandler):
    server_version = "FoundationEvalsFixture/2"

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path not in ROUTES:
            self.send_error(404, "Unknown fixture route")
            return

        request = self.read_request(require_protocol=self.path != "/tool/execute")
        if request is None:
            return

        if self.path == "/tool/execute":
            self.serve_tool_execution(request)
            return

        if self.path == "/redirect":
            self.send_response(307)
            self.send_header("Location", f"http://{HOST}:{PORT}/text")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return
        if self.path == "/http-error":
            self.send_error(503, "Deterministic fixture HTTP failure")
            return

        scenario = self.scenario(request)
        if scenario == "timeout":
            time.sleep(TIMEOUT_DELAY_SECONDS)
            scenario = "text"

        try:
            self.begin_event_stream()
            self.serve_scenario(scenario, request)
        except (BrokenPipeError, ConnectionResetError):
            print(f"fixture: client disconnected from {self.path}", flush=True)

    def read_request(self, require_protocol: bool) -> dict[str, Any] | None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(400, "Invalid Content-Length")
            return None
        if length <= 0 or length > MAX_REQUEST_BYTES:
            self.send_error(413, "Request body is empty or too large")
            return None

        try:
            request = json.loads(self.rfile.read(length))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.send_error(400, "Request body must be UTF-8 JSON")
            return None
        if not isinstance(request, dict):
            self.send_error(400, "Request body must be a JSON object")
            return None
        if require_protocol and request.get("protocolVersion") != 1:
            self.send_error(400, "Unsupported protocolVersion")
            return None
        if require_protocol:
            try:
                self.server.record_protocol_request(request)
            except (OSError, ValueError) as error:
                print(f"fixture: could not append request log: {error}", flush=True)
                self.send_error(500, "Could not append fixture request log")
                return None
        return request

    def serve_tool_execution(self, request: dict[str, Any]) -> None:
        if request.get("toolName") != "lookupOrder":
            self.send_error(400, "Tool request must target lookupOrder")
            return
        arguments = request.get("arguments")
        if not isinstance(arguments, dict):
            self.send_error(400, "Tool request must contain an arguments object")
            return
        order_id = arguments.get("orderID", "A-104")
        body = json.dumps(
            {
                "orderID": order_id,
                "status": "shipped",
                "source": "deterministic-fixture",
            },
            separators=(",", ":"),
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def scenario(self, request: dict[str, Any]) -> str:
        scenario = self.path.removeprefix("/")
        if scenario != "generate":
            return scenario
        if request.get("mode") == "guided":
            return "guided"
        if request.get("enabledTools") or contains_tool_output(request.get("transcript")):
            return "tool"
        if "reasoning" in request.get("provider", {}).get("capabilities", []):
            return "reasoning"
        return "text"

    def begin_event_stream(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()

    def serve_scenario(self, scenario: str, request: dict[str, Any]) -> None:
        if scenario == "malformed":
            self.wfile.write(b'{"kind":"response","content":\n')
            self.wfile.flush()
            return
        if scenario == "error":
            self.emit(
                kind="error",
                code="fixtureBackendFailure",
                message="Deterministic fixture backend failure.",
            )
            return
        if scenario == "cancel":
            self.emit_response("Cancellation fixture started. ", token_count=3)
            time.sleep(CANCEL_DELAY_SECONDS)
            self.emit_response("Cancellation fixture completed.", token_count=3)
            self.emit_usage(output_tokens=6)
            return
        if scenario in {"guided", "guided/simple", "guided/stream", "guided/order"}:
            self.serve_guided(scenario, request)
            return
        if scenario == "tool":
            self.serve_tool(request)
            return
        if scenario == "reasoning":
            self.emit(
                kind="reasoning",
                action="append",
                entryID="fixture-reasoning",
                segmentID="fixture-reasoning-text",
                content="The fixture checked its deterministic route before answering.",
                tokenCount=9,
            )
            time.sleep(STREAM_DELAY_SECONDS)
            self.emit_response("Deterministic reasoning response.", token_count=4)
            self.emit_usage(output_tokens=13, reasoning_tokens=9)
            return
        self.serve_text()

    def serve_text(self) -> None:
        chunks = [
            ("Deterministic ", 2),
            ("fixture ", 1),
            ("stream.", 1),
        ]
        for index, (content, token_count) in enumerate(chunks):
            if index:
                time.sleep(STREAM_DELAY_SECONDS)
            self.emit_response(content, token_count=token_count)
        self.emit_usage(output_tokens=4)

    def serve_guided(self, scenario: str, request: dict[str, Any]) -> None:
        if request.get("mode") != "guided":
            self.emit(
                kind="error",
                code="fixtureRequiresGuidedMode",
                message="Enable an output schema before using a guided fixture route.",
            )
            return

        if scenario == "guided/simple":
            payload = SIMPLE_GUIDED_PAYLOAD
        elif scenario == "guided/stream":
            self.serve_guided_stream()
            return
        elif scenario == "guided/order":
            payload = ORDER_GUIDED_PAYLOAD
        else:
            payload = guided_payload_for(request.get("schema"))
        content = json.dumps(payload, separators=(",", ":"))
        token_count = guided_token_count(payload)
        self.emit(
            kind="guidedResponse",
            action="append",
            entryID="fixture-guided-response",
            segmentID="fixture-guided-json",
            content=content,
            tokenCount=token_count,
        )
        self.emit_usage(output_tokens=token_count)

    def serve_guided_stream(self) -> None:
        chunks = [
            ('{"answer":"', 2),
            ("fixture", 1),
            ('"}', 1),
        ]
        for index, (content, token_count) in enumerate(chunks):
            if index:
                time.sleep(STREAM_DELAY_SECONDS)
            self.emit(
                kind="guidedResponse",
                action="append",
                entryID="fixture-guided-response",
                segmentID="fixture-guided-json",
                content=content,
                tokenCount=token_count,
            )
        self.emit_usage(output_tokens=guided_token_count(SIMPLE_GUIDED_PAYLOAD))

    def serve_tool(self, request: dict[str, Any]) -> None:
        if contains_tool_output(request.get("transcript")):
            self.emit_response(
                "Tool result received. Order A-104 is shipped.",
                token_count=8,
            )
            self.emit_usage(output_tokens=8)
            return

        tools = request.get("enabledTools") or []
        if not tools:
            self.emit(
                kind="error",
                code="fixtureRequiresTool",
                message="Configure and enable a custom tool before using /tool.",
            )
            return
        tool = next(
            (candidate for candidate in tools if candidate.get("name") == "lookupOrder"),
            tools[0],
        )
        self.emit(
            kind="toolCall",
            action="append",
            entryID="fixture-tool-calls",
            callID="fixture-call-1",
            toolName=tool.get("name", "lookupOrder"),
            content=json.dumps(tool_arguments(tool), separators=(",", ":")),
            tokenCount=4,
        )
        self.emit(
            kind="usage",
            usageTarget="toolCalls",
            usage={
                "inputTokens": 12,
                "cachedInputTokens": 0,
                "outputTokens": 4,
                "reasoningTokens": 0,
            },
        )

    def emit_response(self, content: str, token_count: int) -> None:
        self.emit(
            kind="response",
            action="append",
            entryID="fixture-response",
            segmentID="fixture-response-text",
            content=content,
            tokenCount=token_count,
        )

    def emit_usage(self, output_tokens: int, reasoning_tokens: int = 0) -> None:
        self.emit(
            kind="usage",
            usageTarget="response",
            usage={
                "inputTokens": 12,
                "cachedInputTokens": 0,
                "outputTokens": output_tokens,
                "reasoningTokens": reasoning_tokens,
            },
        )

    def emit(self, **event: Any) -> None:
        self.wfile.write(json.dumps(event, separators=(",", ":")).encode("utf-8") + b"\n")
        self.wfile.flush()

    def log_message(self, format: str, *args: Any) -> None:
        print(f"fixture: {format % args}", flush=True)


def contains_tool_output(transcript: Any) -> bool:
    """Recognize the Foundation Models Codable tool-output case without inspecting content."""
    if isinstance(transcript, dict):
        role = transcript.get("role")
        if isinstance(role, str) and role.replace("_", "").lower() in {
            "tool",
            "tooloutput",
        }:
            return True
        if any(key.replace("_", "").lower() == "tooloutput" for key in transcript):
            return True
        return any(contains_tool_output(value) for value in transcript.values())
    if isinstance(transcript, list):
        return any(contains_tool_output(value) for value in transcript)
    return False


def guided_payload_for(schema: Any) -> dict[str, Any]:
    """Choose one documented fixture shape from identifiers in the encoded schema."""
    compact = json.dumps(schema, separators=(",", ":")).lower()
    order_markers = ('"order"', '"items"', '"sku"', '"quantity"', '"status"')
    if any(marker in compact for marker in order_markers):
        return ORDER_GUIDED_PAYLOAD
    return SIMPLE_GUIDED_PAYLOAD


def guided_token_count(payload: dict[str, Any]) -> int:
    return 24 if payload is ORDER_GUIDED_PAYLOAD else 4


def tool_arguments(tool: dict[str, Any]) -> dict[str, str]:
    """Return arguments for the documented order tool, with a query fallback."""
    parameters = json.dumps(tool.get("parameters"), separators=(",", ":")).lower()
    if "orderid" in parameters:
        return {"orderID": "A-104"}
    if "query" in parameters:
        return {"query": "A-104"}
    return {}


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=PORT, help="Loopback port (default: %(default)s)")
    parser.add_argument(
        "--stream-delay",
        type=float,
        default=STREAM_DELAY_SECONDS,
        help="Seconds between delayed stream chunks (default: %(default)s)",
    )
    parser.add_argument(
        "--timeout-delay",
        type=float,
        default=TIMEOUT_DELAY_SECONDS,
        help="Seconds before the timeout route sends headers (default: %(default)s)",
    )
    parser.add_argument(
        "--cancel-delay",
        type=float,
        default=CANCEL_DELAY_SECONDS,
        help="Seconds between cancellation route chunks (default: %(default)s)",
    )
    parser.add_argument(
        "--request-log",
        type=Path,
        help=(
            "Append each validated provider protocol request as bounded NDJSON; "
            "disabled by default"
        ),
    )
    return parser.parse_args()


if __name__ == "__main__":
    arguments = parse_arguments()
    if not 0 <= arguments.port <= 65_535:
        raise SystemExit("--port must be between 0 and 65535")
    if min(arguments.stream_delay, arguments.timeout_delay, arguments.cancel_delay) < 0:
        raise SystemExit("fixture delays must not be negative")
    STREAM_DELAY_SECONDS = arguments.stream_delay
    TIMEOUT_DELAY_SECONDS = arguments.timeout_delay
    CANCEL_DELAY_SECONDS = arguments.cancel_delay
    server = FixtureServer((HOST, arguments.port), request_log=arguments.request_log)
    bound_port = server.server_address[1]
    print(f"Foundation Evals protocol fixture listening on http://{HOST}:{bound_port}", flush=True)
    print("This server returns fixed events; it does not perform model inference.", flush=True)
    print("Routes: " + ", ".join(sorted(ROUTES)), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
