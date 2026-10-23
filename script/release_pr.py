"""Gate release PR generation on publication and dispatch CI for created PRs."""

import argparse
import json
import os
import re
import subprocess
from pathlib import Path


def github_json(*args):
    result = subprocess.run(["gh", *args], check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def optional_github_api(endpoint):
    """Only an explicit API 404 is absence; authentication/network errors still fail."""
    result = subprocess.run(
        ["gh", "api", endpoint, "--include"], capture_output=True, text=True
    )
    headers, separator, body = result.stdout.partition("\n\n")
    status = re.match(r"HTTP/\S+ ([0-9]{3})(?:\s|$)", headers)
    if not separator or not status:
        result.check_returncode()
        raise ValueError("GitHub did not return an HTTP response")
    if result.returncode:
        if status[1] == "404":
            return None
        result.check_returncode()
    if status[1] != "200":
        raise ValueError(f"Unexpected GitHub response: HTTP {status[1]}")
    payload = json.loads(body)
    if not isinstance(payload, dict):
        raise ValueError("GitHub did not return an API object")
    return payload


def check_baseline():
    repository = os.environ["GITHUB_REPOSITORY"]
    # Read the same live main manifest that Release Please uses, even on reruns.
    manifest = github_json(
        "api",
        f"repos/{repository}/contents/.release-please-manifest.json?ref=main",
        "-H",
        "Accept: application/vnd.github.raw+json",
    )
    version = manifest["."]
    if not isinstance(version, str) or not re.fullmatch(
        r"[0-9]+\.[0-9]+\.[0-9]+", version
    ):
        raise ValueError("The release manifest must contain a stable semantic version")
    tag = f"v{version}"
    release = optional_github_api(f"repos/{repository}/releases/tags/{tag}")
    missing = release is None
    if missing:
        # A removed, unpublished candidate must not deadlock all future proposals.
        # A surviving tag may already be distributed, so do not bypass that case.
        if optional_github_api(f"repos/{repository}/git/ref/tags/{tag}") is not None:
            raise ValueError(f"{tag} has a tag but no release; restore its release before generating another PR")
        ready = True
    else:
        if release.get("tag_name") != tag or not isinstance(release.get("draft"), bool):
            raise ValueError("The release response does not match the manifest baseline")
        ready = not release["draft"]
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write(f"ready={str(ready).lower()}\n")
    if missing:
        print(f"{tag} has neither a release nor a tag; generating the next release PR from current main.")
    elif ready:
        print(f"{tag} is published; release PR generation can proceed.")
    else:
        print(
            f"{tag} is still a draft; waiting for installer publication before generating another release PR."
        )


def dispatch_ci():
    # No-op action runs omit both pr and prs. Parse only at runtime, with an empty default.
    prs = json.loads(os.environ.get("RELEASE_PRS") or "[]")
    if not isinstance(prs, list):
        raise ValueError("Release Please PR output must be an array")
    branches = []
    for pr in prs:
        branch = pr.get("headBranchName") if isinstance(pr, dict) else None
        if not isinstance(branch, str) or not branch.strip():
            raise ValueError("Each release PR must identify its head branch")
        branches.append(branch)
    for branch in dict.fromkeys(branches):
        subprocess.run(
            [
                "gh",
                "workflow",
                "run",
                "ci.yml",
                "--repo",
                os.environ["GITHUB_REPOSITORY"],
                "--ref",
                branch,
            ],
            check=True,
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("check-baseline", "dispatch-ci"))
    args = parser.parse_args()
    if args.mode == "check-baseline":
        check_baseline()
    else:
        dispatch_ci()


if __name__ == "__main__":
    main()
