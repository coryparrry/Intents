"""Run a selected native test shard from the single CI build artifact."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products", type=Path, required=True)
    parser.add_argument("--result", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=1)
    args = parser.parse_args()
    selection = json.loads(os.environ["CI_TEST_SELECTION"])
    command = test_command(args.products, selection, args.result, args.iterations)
    log = args.result.with_suffix(".log")
    # Keep a durable log even when xcodebuild fails; print it for the Actions log.
    try:
        with log.open("w") as output:
            subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)
    finally:
        print(log.read_text(), flush=True)
    verify_ui_selection(log.read_text(), selection)
    if any(test.startswith("FoundationEvalsTests") for test in selection):
        result = subprocess.run([
            "xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(args.result), "--compact",
        ], check=True, capture_output=True, text=True)
        verify_native_selection(json.loads(result.stdout), selection)


if __name__ == "__main__":
    main()
