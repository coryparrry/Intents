"""Validate curated Release Please notes for squash-merged pull requests."""

import argparse
import json
import os
import re
from pathlib import Path

BEGIN = "BEGIN_COMMIT_OVERRIDE"
END = "END_COMMIT_OVERRIDE"
REQUIRED_PR_TYPES = {"feat", "fix"}
ALLOWED_ENTRY_TYPES = {
    "build",
    "chore",
    "ci",
    "deps",
    "docs",
    "feat",
    "fix",
    "perf",
    "refactor",
    "revert",
    "style",
    "test",
}
HTML_COMMENT = re.compile(r"<!--.*?(?:-->|$)", re.DOTALL)
SUBJECT = re.compile(
    r"^(?P<type>[a-z]+)(?:\([^()\r\n]+\))?(?P<breaking>!)?: (?P<summary>\S.*)$"
)
MARKER_LINES = {
    BEGIN: re.compile(rf"^[ \t]*{BEGIN}[ \t]*\r?$", re.MULTILINE),
    END: re.compile(rf"^[ \t]*{END}[ \t]*\r?$", re.MULTILINE),
}


def subject_details(subject):
    match = SUBJECT.fullmatch(subject.strip()) if isinstance(subject, str) else None
    return (
        (match.group("type"), bool(match.group("breaking"))) if match else (None, False)
    )


def extract_override(body):
    if not isinstance(body, str):
        raise ValueError("The pull request body must be text")
    uncommented = HTML_COMMENT.sub("", body)
    if any(body.count(marker) != uncommented.count(marker) for marker in (BEGIN, END)):
        raise ValueError(
            "Release note override markers must not be hidden inside HTML comments"
        )
    marker_counts = {marker: body.count(marker) for marker in (BEGIN, END)}
    if not marker_counts[BEGIN] and not marker_counts[END]:
        return None
    if marker_counts != {BEGIN: 1, END: 1}:
        raise ValueError(
            "Release notes must contain exactly one ordered override block"
        )
    if any(len(MARKER_LINES[marker].findall(body)) != 1 for marker in (BEGIN, END)):
        raise ValueError("Release note override markers must be on their own lines")
    begin = body.index(BEGIN)
    end = body.index(END)
    if begin >= end:
        raise ValueError(
            "Release notes must contain exactly one ordered override block"
        )
    content = body[begin + len(BEGIN) : end]
    entries = [line.strip() for line in content.splitlines() if line.strip()]
    if not entries:
        raise ValueError("The release note override must contain at least one entry")
    parsed = []
    for entry in entries:
        entry_type, breaking = subject_details(entry)
        if entry_type not in ALLOWED_ENTRY_TYPES:
            allowed = ", ".join(sorted(ALLOWED_ENTRY_TYPES))
            raise ValueError(
                f"Invalid release note entry {entry!r}; allowed types: {allowed}"
            )
        parsed.append((entry_type, breaking, entry))
    return parsed


def validate_pull_request(title, body):
    if not isinstance(title, str) or not title.strip():
        raise ValueError("The pull request title must be nonempty text")
    pull_request_type, pull_request_breaking = subject_details(title)
    entries = extract_override(body)
    if pull_request_type in REQUIRED_PR_TYPES and entries is None:
        raise ValueError(
            f"{pull_request_type}: pull requests require an active release note override"
        )
    if entries is None:
        return []
    if pull_request_type in REQUIRED_PR_TYPES and not any(
        entry_type == pull_request_type for entry_type, _, _ in entries
    ):
        raise ValueError(
            f"The override must retain the pull request's {pull_request_type}: release type"
        )
    if pull_request_type == "fix" and any(
        entry_type == "feat" for entry_type, _, _ in entries
    ):
        raise ValueError(
            "A fix: pull request cannot contain feat: release notes; use a feat: title"
        )
    breaking_entries = [entry for _, breaking, entry in entries if breaking]
    if pull_request_breaking and not any(
        entry_type == pull_request_type and breaking
        for entry_type, breaking, _ in entries
    ):
        raise ValueError(
            "A breaking pull request title requires a matching breaking release note"
        )
    if not pull_request_breaking and breaking_entries:
        raise ValueError("Breaking release notes require a breaking pull request title")
    return [entry for _, _, entry in entries]


def validate_event(path):
    try:
        event = json.loads(path.read_text())
        pull_request = event["pull_request"]
        title = pull_request["title"]
        body = pull_request.get("body") or ""
    except (KeyError, OSError, TypeError, ValueError) as error:
        raise ValueError(
            "GITHUB_EVENT_PATH must contain a pull_request payload"
        ) from error
    entries = validate_pull_request(title, body)
    print(
        f"Validated {len(entries)} curated release note entr{'y' if len(entries) == 1 else 'ies'}."
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("validate-event",))
    parser.add_argument("--event", type=Path)
    args = parser.parse_args()
    event_path = args.event or (
        Path(os.environ["GITHUB_EVENT_PATH"])
        if "GITHUB_EVENT_PATH" in os.environ
        else None
    )
    if event_path is None:
        parser.error("--event or GITHUB_EVENT_PATH is required")
    validate_event(event_path)


if __name__ == "__main__":
    main()
