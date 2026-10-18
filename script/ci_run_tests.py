"""Run an explicit CI test selection; an empty selection never runs the whole suite."""

import argparse
import json
import os
import re
import subprocess
import sys


def run_tests(kind, selection, scratch_path=None):
    if not isinstance(selection, list) or any(
        not isinstance(name, str) or not name for name in selection
    ):
        raise ValueError("CI test selection must be an array of nonempty names")
    names = sorted(set(selection))
    if not names:
        print("No tests selected.")
        return
    print(f"Selected {kind} tests: {', '.join(names)}", flush=True)
    if kind == "python":
        if any(
            not re.fullmatch(r"script\.tests\.test_[A-Za-z0-9_]+", name)
            for name in names
        ):
            raise ValueError("Python selections must name repository test modules")
        subprocess.run([sys.executable, "-m", "unittest", "-v", *names], check=True)
        return
    if names != ["*"] and any(
        not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name) for name in names
    ):
        raise ValueError(
            "Swift selections must name test suites, or use a single wildcard for full coverage"
        )
    command = ["swift", "test"]
    if scratch_path:
        command.extend(["--scratch-path", scratch_path])
    if names != ["*"]:
        # Fail on renamed/missing suites instead of accepting Swift's zero-test success.
        catalog = subprocess.run(
            [*command, "list"], check=True, stdout=subprocess.PIPE, text=True
        ).stdout
        available = {
            line.split("/", 1)[0].rsplit(".", 1)[-1]
            for line in catalog.splitlines()
            if "/" in line
        }
        missing = set(names) - available
        if missing:
            raise ValueError(
                "Selected Swift suites were not discovered: "
                + ", ".join(sorted(missing))
            )
        command.extend(["--filter", r"(?:^|\.)(?:" + "|".join(names) + r")/"])
    subprocess.run(command, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("python", "swift"))
    parser.add_argument("--scratch-path")
    args = parser.parse_args()
    run_tests(args.kind, json.loads(os.environ["CI_TEST_SELECTION"]), args.scratch_path)


if __name__ == "__main__":
    main()
