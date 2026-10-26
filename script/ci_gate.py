"""Fail closed unless routing and every selected CI worker completed correctly."""

import json
import os
import sys


FLAGS = ("native", "ui", "sdk_consumer", "input_conversion", "regression")
ARRAYS = ("native_tests", "swift_suites", "macos_tests")
WORKERS = ("changes", "swift-tests", "native-build", "ui-tests", "picker-stability")
RESULTS = {"success", "failure", "cancelled", "skipped"}
JSON_LIMIT = 256 * 1024


def evaluate(needs, selection, stability_requested):
    """Return all contract violations from decoded GitHub needs and output objects."""
    errors = []
    if not isinstance(needs, dict):
        errors.append("CI_NEEDS_JSON must be an object")
        needs = {}
    if not isinstance(selection, dict):
        errors.append("CI_SELECTION_JSON must be an object")
        selection = {}

    flags, arrays = {}, {}
    for key in FLAGS:
        value = selection.get(key)
        if value not in ("true", "false"):
            errors.append(f"Selection {key} must be the string true or false")
        else:
            flags[key] = value == "true"
    for key in ARRAYS:
        try:
            if not isinstance(selection[key], str):
                raise ValueError()
            value = json.loads(selection[key])
            if not isinstance(value, list) or not all(isinstance(item, str) and item.strip() for item in value):
                raise ValueError()
        except (KeyError, TypeError, ValueError, RecursionError):
            errors.append(f"Selection {key} must be a JSON array of nonempty strings")
        else:
            arrays[key] = value
    if stability_requested not in ("true", "false"):
        errors.append("CI_STABILITY_REQUESTED must be the string true or false")

    if len(flags) == len(FLAGS) and len(arrays) == len(ARRAYS):
        mac_selected = bool(arrays["swift_suites"] or arrays["macos_tests"] or arrays["native_tests"]
                            or flags["sdk_consumer"] or flags["input_conversion"])
        if flags["regression"] != mac_selected:
            errors.append("Selection regression disagrees with the selected Mac regression work")
        if (arrays["native_tests"] or flags["ui"]) and not flags["native"]:
            errors.append("Selected native core or UI tests require selection native=true")

    expected = {"changes": "success", "swift-tests": "success"}
    for worker, flag in (("native-build", "native"), ("ui-tests", "ui")):
        if flag in flags:
            expected[worker] = "success" if flags[flag] else "skipped"
    if "ui" in flags and stability_requested in ("true", "false"):
        expected["picker-stability"] = "success" if flags["ui"] and stability_requested == "true" else "skipped"

    for worker in WORKERS:
        outcome = needs.get(worker)
        result = outcome.get("result") if isinstance(outcome, dict) else None
        if not isinstance(result, str) or result not in RESULTS:
            errors.append(f"Worker {worker} is missing a valid terminal result")
        elif worker in expected and result != expected[worker]:
            errors.append(f"Worker {worker} must be {expected[worker]}; recorded {result}")
    return errors


def main(environ=None):
    """Decode size-bounded CI environment JSON, print every routing contract error, and return a failing exit status for invalid or incomplete work."""
    env = os.environ if environ is None else environ
    documents = {}
    errors = []
    for key in ("CI_NEEDS_JSON", "CI_SELECTION_JSON"):
        try:
            raw = env[key]
            if not isinstance(raw, str) or len(raw.encode("utf-8")) > JSON_LIMIT:
                raise ValueError()
            documents[key] = json.loads(raw)
        except (KeyError, TypeError, ValueError, RecursionError):
            errors.append(f"{key} must contain a JSON object within {JSON_LIMIT} bytes")
    if not errors:
        errors = evaluate(documents["CI_NEEDS_JSON"], documents["CI_SELECTION_JSON"],
                          env.get("CI_STABILITY_REQUESTED"))
    for error in errors:
        print(f"CI gate error: {error}", file=sys.stderr)
    if errors:
        return 1
    print("Routing and all selected CI workers satisfied the required checks.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
