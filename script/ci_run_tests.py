"""Run an explicit CI test selection; an empty selection never runs the whole suite."""

import argparse
import json
import os
import re
import subprocess
import sys

try:
    from ci_test_policy import swift_manual_methods
except ModuleNotFoundError:
    from script.ci_test_policy import swift_manual_methods


def run_tests(kind, selection, scratch_path=None, include_installer=False):
    if not isinstance(selection, list) or any(
        not isinstance(name, str) or not name for name in selection
    ):
        raise ValueError("CI test selection must be an array of nonempty names")
    names = sorted(set(selection))
    if include_installer:
        if kind != "swift":
            raise ValueError("Installer coverage requires Swift tests")
        if names != ["*"]:
            names = sorted(set(names) | {"IntentLabProjectInstallerTests"})
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
    skip_pattern = r"(?:^|\.)(?:" + "|".join(
        re.escape(test) for test in sorted(swift_manual_methods(include_installer))
    ) + r")(?:\(\))?$"
    if names != ["*"]:
        # Fail on renamed/missing suites instead of accepting Swift's zero-test success.
        catalog = subprocess.run(
            [*command, "list"], check=True, stdout=subprocess.PIPE, text=True
        ).stdout
        discovered = {line.strip() for line in catalog.splitlines() if "/" in line}
        available = {test.split("/", 1)[0].rsplit(".", 1)[-1] for test in discovered}
        missing = set(names) - available
        if missing:
            raise ValueError(
                "Selected Swift suites were not discovered: "
                + ", ".join(sorted(missing))
            )
        eligible = {
            test.split("/", 1)[0].rsplit(".", 1)[-1]
            for test in discovered if not re.search(skip_pattern, test)
        }
        manual_only = sorted(set(names) - eligible)
        if manual_only:
            print("No automatic eligible cases for manual-only Swift suites: " + ", ".join(manual_only)
                  + ". Run them directly with their required runtime inputs.", flush=True)
        names = sorted(set(names) & eligible)
        if not names:
            return
        command.extend(["--filter", r"(?:^|\.)(?:" + "|".join(names) + r")/"])
    command.extend(["--skip", skip_pattern])
    subprocess.run(command, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("python", "swift"))
    parser.add_argument("--scratch-path")
    parser.add_argument("--include-installer", action="store_true")
    args = parser.parse_args()
    run_tests(args.kind, json.loads(os.environ["CI_TEST_SELECTION"]), args.scratch_path, args.include_installer)


if __name__ == "__main__":
    main()
