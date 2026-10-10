#!/usr/bin/env python3
"""Run XCTest suites and fail when a provisioned suite silently skips."""
import argparse, re, subprocess, sys

CASE = re.compile(r"Test Case '-\[(?:\w+\.)?(\w+) (\w+)\]' (passed|failed|skipped)")


def evaluate(output: str, suites: list[str], allowed: set[str]) -> list[str]:
    seen = {suite: 0 for suite in suites}
    problems = []
    for suite, test, outcome in CASE.findall(output):
        if suite not in seen:
            continue
        seen[suite] += 1
        if outcome == "skipped" and f"{suite}/{test}" not in allowed:
            problems.append(f"Unexpected skip: {suite}/{test}")
    problems += [f"No tests ran for {suite}" for suite, count in seen.items() if count == 0]
    return problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--suite", action="append", required=True)
    parser.add_argument("--allow-skip", action="append", default=[])
    args = parser.parse_args()
    command = ["swift", "test", "--jobs", "2", "--filter", "|".join(args.suite)]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    lines = []
    for line in process.stdout:
        sys.stdout.write(line)
        lines.append(line)
    status = process.wait()
    problems = evaluate("".join(lines), args.suite, set(args.allow_skip))
    for problem in problems:
        print(f"::error::{problem}")
    return status or (1 if problems else 0)


if __name__ == "__main__":
    sys.exit(main())
