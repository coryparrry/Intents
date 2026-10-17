"""Run a selected native test shard from the single CI build artifact."""

import argparse
import json
import math
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import threading
import time
from urllib.parse import unquote, urlparse

from ci_ui_xctestrun import prepare_ui_xctestrun


def test_command(products, selection, result, iterations=1):
    if not isinstance(selection, list) or not selection:
        raise ValueError("Native test selection must be a nonempty array")
    pattern = r"FoundationEvals(?:UI)?Tests(?:/[A-Za-z_][A-Za-z0-9_]*(?:/[A-Za-z_][A-Za-z0-9_]*)?)?"
    if any(not isinstance(test, str) or not re.fullmatch(pattern, test) for test in selection):
        raise ValueError("Invalid native test identifier")
    if type(iterations) is not int or iterations < 1:
        raise ValueError("Test iterations must be positive")
    ui = any(test.startswith("FoundationEvalsUITests") for test in selection)
    if ui:
        descriptor = prepare_ui_xctestrun(products)
    else:
        candidates = sorted(products.glob("FoundationEvals*_macosx*.xctestrun"))
        if len(candidates) != 1:
            raise ValueError("Expected exactly one native test descriptor")
        descriptor = candidates[0]
    command = [
        "xcodebuild", "test-without-building", "-xctestrun", str(descriptor),
        "-destination", "platform=macOS", "-resultBundlePath", str(result),
        # Each UI shard owns a desktop; Xcode workers must not share that desktop.
        "-parallel-testing-enabled", "NO" if ui else "YES",
    ]
    command.extend(f"-only-testing:{test}" for test in sorted(set(selection)))
    if iterations > 1:
        command.extend(["-test-iterations", str(iterations)])
    return [*command, "CODE_SIGNING_ALLOWED=NO"]


def verify_ui_selection(log, selection):
    """Xcode can return success for a stale -only-testing identifier."""
    executed = set(re.findall(
        r"Test Case '-\[(?:FoundationEvalsUITests\.)?(\w+) (\w+)\]' passed", log
    ))
    for test in selection:
        parts = test.split("/")
        if parts[0] != "FoundationEvalsUITests":
            continue
        if not any(
            (len(parts) < 2 or suite == parts[1])
            and (len(parts) < 3 or method == parts[2])
            for suite, method in executed
        ):
            raise ValueError(f"Selected UI test did not pass: {test}")


def verify_native_selection(document, selection):
    """Use stable result identifiers, including Swift Testing suite symbols."""
    passed = set()

    def visit(node):
        if not isinstance(node, dict):
            raise ValueError("Malformed native test result node")
        if node.get("nodeType") == "Test Case" and node.get("result") == "Passed":
            parts = unquote(urlparse(node.get("nodeIdentifierURL", "")).path).strip("/").split("/")
            if "FoundationEvalsTests" in parts:
                passed.add("/".join(parts[parts.index("FoundationEvalsTests"):]))
        for child in node.get("children", []):
            visit(child)

    if not isinstance(document, dict) or not isinstance(document.get("testNodes"), list):
        raise ValueError("Missing native test result tree")
    for node in document["testNodes"]:
        visit(node)
    for test in selection:
        if not test.startswith("FoundationEvalsTests"):
            continue
        if not any(identifier == test or identifier.startswith(test + "/") for identifier in passed):
            raise ValueError(f"Selected native test did not pass: {test}")


def _stream_available(selector, retained, output, timeout):
    for key, _ in selector.select(timeout):
        data = os.read(key.fileobj.fileno(), 65536)
        if not data:
            selector.unregister(key.fileobj)
            continue
        retained.write(data)
        output.write(data)
        output.flush()


def _drain_output(selector, retained, output, seconds, *, wait_when_closed=False):
    deadline = time.monotonic() + seconds
    while (remaining := deadline - time.monotonic()) > 0:
        if not selector.get_map():
            if wait_when_closed:
                time.sleep(remaining)
            return
        _stream_available(selector, retained, output, min(0.1, remaining))


def _stop_owned_group(process, grace_seconds, selector, retained, output):
    # Keep the direct child unreaped until the final signal. Its reserved PID
    # prevents an unrelated process group from reusing this group's identifier.
    if process.returncode is not None:
        return
    previous = {}
    if threading.current_thread() is threading.main_thread():
        for number in (signal.SIGINT, signal.SIGTERM):
            previous[number] = signal.signal(number, signal.SIG_IGN)
    try:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            # Darwin can reject signals to an already-exited unreaped leader.
            # A denied final signal is accepted only after proving group absence.
            pass
        try:
            _drain_output(selector, retained, output, grace_seconds, wait_when_closed=True)
        finally:
            denied = None
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except PermissionError as error:
                denied = error
            process.wait(timeout=5)
            if denied is not None:
                try:
                    os.killpg(process.pid, 0)
                except ProcessLookupError:
                    pass
                else:
                    raise denied
        _drain_output(selector, retained, output, 1)
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def run_logged(command, log, timeout=None, *, output=None, cleanup_grace=5, exit_drain_timeout=5):
    """Stream merged output and retain it, with bounded owned-group cleanup."""
    if timeout is not None and (not math.isfinite(timeout) or timeout <= 0):
        raise ValueError("Execution timeout must be positive and finite")
    output = sys.stdout.buffer if output is None else output
    deadline = None if timeout is None else time.monotonic() + timeout
    with log.open("wb", buffering=0) as retained:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        with selectors.DefaultSelector() as selector:
            try:
                selector.register(process.stdout, selectors.EVENT_READ)
                exit_deadline = None
                while selector.get_map():
                    now = time.monotonic()
                    if deadline is not None and now >= deadline:
                        raise subprocess.TimeoutExpired(command, timeout)
                    # WNOWAIT observes exit without surrendering the PID reservation
                    # needed for safe cleanup of descendants holding the output pipe.
                    exited = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                    if exited is not None and exited.si_pid == process.pid and exit_deadline is None:
                        exit_deadline = now + exit_drain_timeout
                    if exit_deadline is not None and now >= exit_deadline:
                        raise RuntimeError("Native test process exited but descendants kept its output pipe open")
                    waits = [0.1]
                    waits.extend(limit - now for limit in (deadline, exit_deadline) if limit is not None)
                    _stream_available(selector, retained, output, min(waits))
                remaining = None if deadline is None else max(0, deadline - time.monotonic())
                code = process.wait(timeout=remaining)
                if code:
                    raise subprocess.CalledProcessError(code, command)
            except BaseException:
                _stop_owned_group(process, cleanup_grace, selector, retained, output)
                raise
            finally:
                process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products", type=Path, required=True)
    parser.add_argument("--result", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=1)
    parser.add_argument("--timeout-seconds", type=float, help="Fail before the job deadline so results can upload")
    args = parser.parse_args()
    selection = json.loads(os.environ["CI_TEST_SELECTION"])
    command = test_command(args.products, selection, args.result, args.iterations)
    log = args.result.with_suffix(".log")
    # Actions cancellation must release only this invocation's process group.
    def interrupted(number, _frame):
        raise SystemExit(128 + number)
    previous_term = signal.signal(signal.SIGTERM, interrupted)
    try:
        run_logged(command, log, timeout=args.timeout_seconds)
    finally:
        signal.signal(signal.SIGTERM, previous_term)
    verify_ui_selection(log.read_text(), selection)
    if any(test.startswith("FoundationEvalsTests") for test in selection):
        result = subprocess.run([
            "xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(args.result), "--compact",
        ], check=True, capture_output=True, text=True)
        verify_native_selection(json.loads(result.stdout), selection)


if __name__ == "__main__":
    main()
