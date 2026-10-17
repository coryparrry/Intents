#!/usr/bin/env python3
"""Run one CI command with a dedicated, temporary Apple Development keychain."""

import argparse
import base64
import binascii
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

CREDENTIAL_KEYS = {"CI_MAC_CERTIFICATE_P12_BASE64", "CI_MAC_CERTIFICATE_PASSWORD", "CI_MAC_SIGNING_TEAM"}
IDENTITY = re.compile(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"Apple Development: [^"\n]+"\s*$')
PUBLIC_CERTIFICATE = re.compile(r"-----BEGIN CERTIFICATE-----\s+[A-Za-z0-9+/=\r\n]+-----END CERTIFICATE-----")


class SigningError(Exception):
    """Only fixed, non-secret diagnostics may be placed in this exception."""


class Interrupted(Exception):
    def __init__(self, number):
        self.number = number


def configuration(environment):
    team = environment.get("CI_MAC_SIGNING_TEAM", "")
    encoded = environment.get("CI_MAC_CERTIFICATE_P12_BASE64", "")
    password = environment.get("CI_MAC_CERTIFICATE_PASSWORD", "")
    if not re.fullmatch(r"[A-Z0-9]{10}", team) or not encoded or not password:
        raise SigningError("Set CI_MAC_CERTIFICATE_P12_BASE64 and CI_MAC_CERTIFICATE_PASSWORD secrets and the CI_MAC_SIGNING_TEAM variable for a separate Apple Development identity.")
    try:
        certificate = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise SigningError("CI development certificate must be valid base64.") from None
    if not certificate or len(certificate) > 1024 * 1024:
        raise SigningError("CI development certificate has an invalid size.")
    return team, certificate, password


def security(arguments, environment):
    # Never expose subprocess exceptions, stdout, stderr or password-bearing argv.
    try:
        result = subprocess.run(["/usr/bin/security", *arguments], env=environment,
                                capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError):
        raise SigningError("Temporary CI signing keychain operation failed.") from None
    if result.returncode:
        raise SigningError("Temporary CI signing keychain operation failed.")
    return result.stdout


def development_identity(output):
    entries = [line for line in output.splitlines() if re.match(r"^\s*\d+\)", line)]
    if len(entries) != 1 or not re.search(r"(?m)^\s*1 valid identities found\s*$", output):
        raise SigningError("Temporary keychain must contain exactly one valid Apple Development signing identity.")
    match = IDENTITY.fullmatch(entries[0])
    if not match:
        raise SigningError("CI signing identity must be Apple Development.")
    return match[1].upper()


def verify_certificate_team(output, fingerprint, team, environment):
    # The CN suffix identifies a developer/certificate, not its signing team.
    # Inspect public leaf metadata only; never export a private key or identity.
    certificates = PUBLIC_CERTIFICATE.findall(output)
    if (len(output) > 1024 * 1024 or not 1 <= len(certificates) <= 16
            or PUBLIC_CERTIFICATE.sub("", output).strip()):
        raise SigningError("Temporary keychain returned invalid public certificate metadata.")
    matching_subjects = []
    for certificate in certificates:
        try:
            result = subprocess.run(["/usr/bin/openssl", "x509", "-noout", "-fingerprint", "-sha1",
                                     "-subject", "-nameopt", "RFC2253,sep_multiline"],
                                    input=certificate, env=environment, capture_output=True,
                                    text=True, timeout=30, check=False)
        except (OSError, subprocess.SubprocessError):
            raise SigningError("Could not inspect the public CI development certificate.") from None
        identities = re.findall(r"(?im)^sha1 Fingerprint=([0-9A-Fa-f:]+)\s*$", result.stdout)
        if result.returncode or len(identities) != 1 or not re.fullmatch(r"(?:[0-9A-Fa-f]{2}:){19}[0-9A-Fa-f]{2}", identities[0]):
            raise SigningError("Could not inspect the public CI development certificate.")
        if identities[0].replace(":", "").upper() == fingerprint:
            matching_subjects.append(result.stdout)
    if len(matching_subjects) != 1:
        raise SigningError("CI signing identity must match exactly one public certificate.")
    units = [line for line in matching_subjects[0].splitlines() if re.match(r"^\s*OU\s*=", line)]
    if len(units) != 1 or not re.fullmatch(r"\s*OU\s*=\s*" + re.escape(team) + r"\s*", units[0]):
        raise SigningError("CI development certificate subject OU must match CI_MAC_SIGNING_TEAM.")


def wait_for_exit(child):
    # Observe exit without reaping: the leader reserves its process-group ID
    # until cleanup has sent its final signal to all same-group descendants.
    while True:
        exited = os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        if exited is not None and exited.si_pid == child.pid:
            return exited.si_status if exited.si_code == os.CLD_EXITED else -exited.si_status
        time.sleep(0.1)


def stop_child(child, grace_seconds=20):
    if child is None:
        return
    if child.returncode is not None:
        raise SigningError("Signed CI command was reaped before process-group cleanup.")
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        # Darwin can deny signals to an already-exited, unreaped leader.
        pass
    # The nested native helper can spend five seconds draining plus five
    # waiting; the automation helper gives its separate-session child ten.
    time.sleep(grace_seconds)
    denied = False
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        denied = True
    child.wait(timeout=5)
    if denied:
        try:
            os.killpg(child.pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise SigningError("Could not confirm signed CI process-group absence.")


def run_signed(command, environment=None):
    source = dict(os.environ if environment is None else environment)
    team, certificate, password = configuration(source)
    clean = {key: value for key, value in source.items() if key not in CREDENTIAL_KEYS}
    root = Path(tempfile.mkdtemp(prefix="intents-ci-signing-", dir=clean.get("RUNNER_TEMP")))
    root.chmod(0o700)
    keychain, p12 = root / "development.keychain-db", root / "development.p12"
    key_password = secrets.token_urlsafe(32)
    original = None
    keychain_created = False
    search_changed = False
    child = None
    result = 1
    handlers = {}

    def interrupt(number, _frame):
        raise Interrupted(number)

    try:
        for number in (signal.SIGTERM, signal.SIGINT):
            handlers[number] = signal.signal(number, interrupt)
        original = shlex.split(security(["list-keychains", "-d", "user"], clean))
        if any(not path.startswith("/") for path in original):
            raise SigningError("Could not preserve the existing user keychain search list.")
        with p12.open("xb") as output:
            os.chmod(p12, 0o600)
            output.write(certificate)
        # Mark possible mutation before dispatch so interrupted CLI calls still clean up.
        keychain_created = True
        search_changed = True
        security(["create-keychain", "-p", key_password, str(keychain)], clean)
        security(["set-keychain-settings", "-lut", "7200", str(keychain)], clean)
        security(["unlock-keychain", "-p", key_password, str(keychain)], clean)
        security(["import", str(p12), "-k", str(keychain), "-P", password, "-T", "/usr/bin/codesign"], clean)
        security(["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", key_password, str(keychain)], clean)
        identity = development_identity(security(["find-identity", "-v", "-p", "codesigning", str(keychain)], clean))
        verify_certificate_team(security(["find-certificate", "-a", "-p", str(keychain)], clean), identity, team, clean)
        p12.unlink()
        security(["list-keychains", "-d", "user", "-s", str(keychain), *original], clean)
        public = {**clean, "INTENTS_CI_SIGNING_TEAM": team, "INTENTS_CI_SIGNING_IDENTITY": identity}
        child = subprocess.Popen(command, env=public, start_new_session=True)
        status = wait_for_exit(child)
        result = status if status >= 0 else 128 - status
    except Interrupted as error:
        result = 128 + error.number
    except SigningError as error:
        print("CI Mac signing failed: " + str(error), file=sys.stderr)
    except Exception:
        # Even unexpected subprocess exceptions can include credential-bearing argv.
        print("CI Mac signing failed: unable to prepare or execute the signed CI command.", file=sys.stderr)
    finally:
        for number in handlers:
            signal.signal(number, signal.SIG_IGN)
        cleanup_failed = False
        try:
            stop_child(child)
        except Exception:
            cleanup_failed = True
        if search_changed and original is not None:
            try:
                security(["list-keychains", "-d", "user", "-s", *original], clean)
            except SigningError:
                cleanup_failed = True
        if keychain_created:
            try:
                security(["delete-keychain", str(keychain)], clean)
            except SigningError:
                cleanup_failed = True
        try:
            shutil.rmtree(root)
        except OSError:
            cleanup_failed = True
        for number, handler in handlers.items():
            signal.signal(number, handler)
        if cleanup_failed:
            print("CI Mac signing cleanup failed; inspect the runner keychain state.", file=sys.stderr)
            if result == 0:
                result = 1
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args(argv)
    command = arguments.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("provide a child command after --")
    try:
        return run_signed(command)
    except SigningError as error:
        print("CI Mac signing failed: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
