"""Write a bounded, credential-redacted summary of this workflow attempt."""

import html
import http.client
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


GATES = {"Compile app and tests".casefold()}
LOG_LIMIT = 1024 * 1024
REQUEST_TIMEOUT = 30
ERROR_LIMIT = 6


def redact(text, secrets=()):
    credential = re.compile(
        r"\b(?:authorization|proxy-authorization|cookie|set-cookie)\s*:\s*\S+|"
        r"\bbearer\s+[A-Za-z0-9._~+/=-]+|"
        r'''\b(?:password|passwd|secret|token|api[ _-]?key|private[ _-]?key|credential|signature)["']?\s*[:=]\s*\S+|'''
        r"[?&](?:sig|signature|token|access_token|api_key|key|credential|x-amz-signature)=|"
        r"gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|"
        r"sk-[A-Za-z0-9_-]+|AKIA[A-Z0-9]{16}", re.I)
    environment = re.compile(
        r"^\s*(export\s|setenv\s|environment\s*variables|[A-Z_][A-Z0-9_]*=)", re.I)
    environment_field = re.compile(r'''^\s*["']?[A-Z_][A-Z0-9_]*["']?\s*:''')
    lines = []
    for raw in text.splitlines():
        line = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", raw)
        line = re.sub(r"^\d{4}-\d\d-\d\dT\S+\s+", "", line)
        lines.append("[redacted credential or environment line]"
                     if any(secret and secret in line for secret in secrets)
                     or credential.search(line) or environment.search(line)
                     or (environment_field.search(line) and not re.match(r"\s*(ERROR|WARNING|FATAL|FAIL|FAILED|FAILURE):", line)) else line)
    return "\n".join(lines)


def markdown(value, limit=400):
    value = redact(str(value)).replace("\n", " ")[:limit]
    return re.sub(r"([\\`*_{}\[\]()#+.!|>~-])", r"\\\1", html.escape(value, quote=False))


def error_excerpt(log, secrets=()):
    lines = redact(log, secrets).splitlines()
    assertion = re.compile(r"\bXCTAssert\w*|\bAssertionError|:\d+(?::\d+)?:\s*(?:fatal )?error:", re.I)
    diagnostic = re.compile(r"##\[error\]|\b\w*(?:error|exception):|\bfatal error\b", re.I)
    fallback = re.compile(r"^\s*(?:FAIL|FAILED|FAILURE)(?:\s|:)", re.I)
    generic = re.compile(r"Process completed with exit code|\*\* TEST .* FAILED \*\*|"
                         r"Test Suite .* failed|Test Case .* failed|CalledProcessError|"
                         r"^\s*Traceback\b|Executed \d+ tests?, with \d+ failures?|"
                         r"(?:File:|Added attachment|suggested name:).*fixture-native-failure", re.I)
    assertions, diagnostics, fallbacks = [], [], []
    for raw in lines:
        line = raw.strip()
        if generic.search(line) or "[redacted credential or environment line]" in line:
            continue
        if assertion.search(line):
            assertions.append(line)
        elif diagnostic.search(line):
            diagnostics.append(line)
        elif fallback.search(line):
            fallbacks.append(line)
    # Preserve the first concrete failure even when export paths and wrappers follow it.
    candidates = assertions + diagnostics or fallbacks
    if not candidates:
        return ["No specific error was found in the retained, redacted log excerpt."]
    return list(dict.fromkeys(candidates))[:ERROR_LIMIT]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


class GitHubAPI:
    def __init__(self, api_url, token, opener=None):
        self.api_url = api_url.rstrip("/")
        self.origin = urllib.parse.urlsplit(self.api_url)
        self.token = token
        self.opener = opener or urllib.request.build_opener(NoRedirect())

    def get(self, path, *, logs=False):
        url = self.api_url + path
        headers = {"Accept": "application/vnd.github+json", "User-Agent": "Intents-CI-summary"}
        if logs:
            headers["Range"] = f"bytes=-{LOG_LIMIT}"
        for _ in range(6):
            origin = urllib.parse.urlsplit(url)
            if origin.scheme != "https" or origin.username or origin.password:
                raise RuntimeError("unsupported API redirect")
            request_headers = dict(headers)
            if (origin.scheme, origin.netloc) == (self.origin.scheme, self.origin.netloc) and self.token:
                request_headers["Authorization"] = "Bearer " + self.token
            request = urllib.request.Request(url, headers=request_headers)
            try:
                response = self.opener.open(request, timeout=REQUEST_TIMEOUT)
            except urllib.error.HTTPError as error:
                response = error
            except (OSError, urllib.error.URLError, http.client.HTTPException):
                raise RuntimeError("GitHub request could not connect") from None
            with response:
                if response.status in (301, 302, 303, 307, 308):
                    location = response.headers.get("Location")
                    if not location:
                        raise RuntimeError("GitHub redirect omitted its destination")
                    url = urllib.parse.urljoin(url, location)
                    continue
                if response.status not in (200, 206):
                    raise RuntimeError(f"GitHub request returned HTTP {response.status}")
                limit = LOG_LIMIT if logs else 8 * 1024 * 1024
                try:
                    if logs and response.status == 200:
                        # Some log hosts ignore Range. Keep a rolling suffix instead
                        # of the setup-heavy prefix, without retaining the full log.
                        deadline = time.monotonic() + REQUEST_TIMEOUT
                        body, total = bytearray(), 0
                        while True:
                            if time.monotonic() >= deadline:
                                raise RuntimeError("GitHub log response exceeded its read time limit")
                            # read1 returns after one underlying read, so a trickling
                            # response cannot keep read(size) waiting indefinitely.
                            chunk = response.read1(64 * 1024)
                            if not chunk:
                                break
                            total += len(chunk)
                            body.extend(chunk)
                            del body[:max(0, len(body) - limit - 1)]
                        truncated = total > limit
                        if truncated:
                            # Drop a partial first line so truncation cannot remove
                            # the credential label that makes redaction possible.
                            if body[-limit - 1] == 10:
                                body = body[-limit:]
                            else:
                                body = body[-limit:].split(b"\n", 1)[-1] if b"\n" in body[-limit:] else b""
                        return bytes(body), truncated
                    body = response.read(limit + 1)
                except (OSError, urllib.error.URLError, http.client.HTTPException):
                    raise RuntimeError("GitHub response could not be read") from None
                if logs and response.status == 206:
                    content_range = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)",
                                                 response.headers.get("Content-Range", ""))
                    if not content_range:
                        raise RuntimeError("GitHub log response omitted a valid byte range")
                    start, end, total = map(int, content_range.groups())
                    if not (start <= end < total and end - start + 1 == len(body) <= limit):
                        raise RuntimeError("GitHub log response has an inconsistent byte range")
                    # A suffix range can start inside a credential line. Without
                    # the preceding byte, discard the first line conservatively.
                    if start:
                        body = body.split(b"\n", 1)[1] if b"\n" in body else b""
                    return body, start > 0 or end + 1 < total
                truncated = len(body) > limit
                if truncated and not logs:
                    raise RuntimeError("GitHub JSON response exceeded its size limit")
                return body[:limit], truncated
        raise RuntimeError("GitHub redirect limit exceeded")

    def pages(self, path, key):
        page = 1
        while True:
            body, _ = self.get(f"{path}?per_page=100&page={page}")
            try:
                document = json.loads(body)
                rows = document[key]
                if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
                    raise ValueError()
            except (ValueError, KeyError, TypeError):
                raise RuntimeError("GitHub returned an invalid JSON listing") from None
            yield from rows
            if len(rows) < 100:
                return
            page += 1


def summarize(api, repository, run_id, attempt, server_url="https://github.com", needs=None):
    secrets = (getattr(api, "token", ""),)
    def escaped(value, limit=400):
        return markdown(redact(str(value), secrets), limit)
    root = f"/repos/{repository}/actions/runs/{run_id}"
    run_url = f"{server_url.rstrip('/')}/{repository}/actions/runs/{run_id}/attempts/{attempt}"
    jobs, artifacts, warnings = [], [], []
    try:
        for job in api.pages(f"{root}/attempts/{attempt}/jobs", "jobs"):
            jobs.append(job)
    except RuntimeError as error:
        warnings.append("Job listing incomplete: " + str(error))
    try:
        for artifact in api.pages(f"{root}/artifacts", "artifacts"):
            artifacts.append(artifact)
    except RuntimeError as error:
        warnings.append("Artifact listing incomplete: " + str(error))
    failed = [job for job in jobs if job.get("conclusion") in ("failure", "timed_out", "action_required", "startup_failure")]
    gates = [job for job in failed if str(job.get("name", "")).casefold() in GATES]
    originals = [job for job in failed if job not in gates]
    cancelled = [job for job in jobs if job.get("conclusion") == "cancelled"]
    skipped = [job for job in jobs if job.get("conclusion") == "skipped"]
    lines = ["## CI failure summary", "", f"[Workflow attempt {attempt}]({run_url})", ""]
    if originals:
        lines.append("Original failed jobs:")
        for job in originals:
            identifier = job.get("id")
            if not isinstance(identifier, int):
                warnings.append("A failed job omitted its numeric ID; its log could not be fetched.")
                continue
            job_url = f"{server_url.rstrip('/')}/{repository}/actions/runs/{run_id}/job/{identifier}"
            steps = [step for step in job.get("steps", []) if step.get("conclusion") in ("failure", "timed_out", "cancelled")]
            names = ", ".join(escaped(step.get("name", "Unnamed step")) for step in steps) or "No failed step was reported"
            step_number = next((step.get("number") for step in steps if isinstance(step.get("number"), int)), None)
            log_url = job_url + (f"#step:{step_number}:1" if step_number else "")
            lines.extend(["", f"- **{escaped(job.get('name', 'Unnamed job'))}** — {escaped(job.get('conclusion'))}; {names}. "
                          f"[Job]({job_url}) · [Logs]({log_url})"])
            try:
                body, truncated = api.get(f"/repos/{repository}/actions/jobs/{identifier}/logs", logs=True)
                lines.extend("  > " + escaped(line, 700) for line in error_excerpt(body.decode("utf-8", errors="replace"), secrets))
                if truncated:
                    lines.append("  > Log response exceeded the bounded excerpt; additional errors may be absent.")
            except RuntimeError as error:
                warnings.append(f"Log unavailable for job {identifier}: {error}")
    else:
        if cancelled or (needs and "cancelled" in needs.values()):
            lines.append("No original failed job was reported. The attempt contains cancelled work; cancellation is the recorded blocker.")
        elif needs and needs.get("selection-gate") not in (None, "success"):
            lines.append("No original failed job was reported. The selection gate failed: routing or worker results did not satisfy the required coverage. See the Require every selected CI check step for the exact violation.")
        elif warnings:
            lines.append("No original failed job could be identified. The cause is unknown because GitHub evidence is incomplete.")
        elif gates or (needs and "failure" in needs.values()):
            lines.append("No original failed job was reported. Aggregate checks failed; the underlying cause is unknown (possibly infrastructure).")
        elif needs and set(needs.values()) <= {"success", "skipped"}:
            lines.append("No failed jobs were reported. All required terminal checks succeeded or were skipped.")
        else:
            lines.append("No original failed job was reported. No root failure is established; the cause is unknown or infrastructure failed before recording a job failure.")
    for label, selected in (("Failed aggregate gates", gates), ("Cancelled jobs", cancelled), ("Skipped jobs", skipped)):
        if selected:
            lines.extend(["", label + ": " + ", ".join(escaped(job.get("name", "Unnamed job")) for job in selected) + "."])
    lines.extend(["", "### Retained artifacts (entire workflow run)", "",
                  f"Jobs above are from attempt {attempt}. Artifacts may include other attempts; "
                  "the artifact listing does not identify the producing attempt.", ""])
    for artifact in artifacts:
        identifier = artifact.get("id")
        if isinstance(identifier, int) and not artifact.get("expired"):
            url = f"{server_url.rstrip('/')}/{repository}/actions/runs/{run_id}/artifacts/{identifier}"
            lines.append(f"- [{escaped(artifact.get('name', 'Artifact'))}]({url})")
    if not any(isinstance(item.get("id"), int) and not item.get("expired") for item in artifacts):
        lines.append("No accessible artifacts were reported.")
    if warnings:
        lines.extend(["", "### Evidence gaps", ""] + ["- " + escaped(warning, 700) for warning in warnings])
    return "\n".join(lines) + "\n"


def main(environ=None):
    env = os.environ if environ is None else environ
    repository, run_id, attempt = env["GITHUB_REPOSITORY"], env["GITHUB_RUN_ID"], env.get("GITHUB_RUN_ATTEMPT", "1")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) or not run_id.isdigit() or not attempt.isdigit():
        raise ValueError("Invalid workflow identity")
    api = GitHubAPI(env.get("GITHUB_API_URL", "https://api.github.com"), env.get("GITHUB_TOKEN", ""))
    needs = json.loads(env.get("CI_NEEDS_JSON", "{}"))
    results = {key: value.get("result") if isinstance(value, dict) else value for key, value in needs.items()}
    if "CI_GATE_RESULT" in env:
        # This report runs inside the aggregate job, before GitHub records that
        # job's conclusion. Include the gate step so passed workers cannot hide
        # invalid routing or a selected worker's unexpected skip.
        gate_result = env["CI_GATE_RESULT"]
        results["selection-gate"] = gate_result if gate_result in ("success", "cancelled") else "failure"
    report = summarize(api, repository, run_id, attempt, env.get("GITHUB_SERVER_URL", "https://github.com"), results)
    with Path(env["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as destination:
        destination.write(report)


if __name__ == "__main__":
    main()
