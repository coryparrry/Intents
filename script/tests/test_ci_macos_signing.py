"""Exercise ephemeral signing with a mocked security CLI, never a real keychain."""

import base64
import contextlib
import io
import os
from pathlib import Path
import signal
import stat
import subprocess
import tempfile
import sys
import time
import unittest
from unittest import mock

from script import ci_macos_signing as signing

TEAM = "ABCDEFGHIJ"
FINGERPRINT = "A" * 40
VALID = f'  1) {FINGERPRINT} "Apple Development: CI Tests (DEVELOPER1)"\n     1 valid identities found\n'

PUBLIC = "-----BEGIN CERTIFICATE-----\nYWJj\n-----END CERTIFICATE-----"
FACTS = "sha1 Fingerprint=" + ":".join(["AA"] * 20) + "\nsubject=\n    CN=Apple Development: CI Tests (DEVELOPER1)\n    OU=" + TEAM + "\n    O=CI Tests\n"


class Child:
    pid = 12345

    def __init__(self, status=0, interrupted=False):
        self.status, self.interrupted, self.finished = status, interrupted, False
        self.returncode = None

    def wait(self, timeout=None):
        self.finished = True
        self.returncode = self.status
        return self.status

    def poll(self):
        return self.status if self.finished else None


class SigningTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.environment = {"RUNNER_TEMP": str(self.root), "CI_TEST_SELECTION": '["NativeMac"]',
                            "CI_MAC_CERTIFICATE_P12_BASE64": base64.b64encode(b"private P12 fixture").decode(),
                            "CI_MAC_CERTIFICATE_PASSWORD": "private-certificate-password", "CI_MAC_SIGNING_TEAM": TEAM}
        self.commands = []
        self.identities = VALID
        self.certificates = PUBLIC
        self.certificate_facts = FACTS
        self.fail = None
        self.child = Child()
        self.child_environments = []
        self.search = ["/Users/runner/Library/Keychains/login.keychain-db", "/Library/Keychains/System.keychain"]
        self.public_child = mock.patch.object(signing.subprocess, "Popen", side_effect=self.start_child)
        self.public_child.start()
        self.addCleanup(self.public_child.stop)
        cli = mock.patch.object(signing.subprocess, "run", side_effect=self.security)
        cli.start()
        self.addCleanup(cli.stop)
        token = mock.patch.object(signing.secrets, "token_urlsafe", return_value="private-keychain-password")
        token.start()
        self.addCleanup(token.stop)
        observe = mock.patch.object(signing, "wait_for_exit", side_effect=self.observe_child)
        observe.start()
        self.addCleanup(observe.stop)
        pause = mock.patch.object(signing.time, "sleep")
        self.pause = pause.start()
        self.addCleanup(pause.stop)
        group = mock.patch.object(signing.os, "killpg")
        self.group = group.start()
        self.addCleanup(group.stop)

    def observe_child(self, child):
        if child.interrupted:
            child.interrupted = False
            raise signing.Interrupted(signal.SIGTERM)
        return child.status

    def security(self, command, *, env, capture_output, text, timeout, check, input=None):
        self.commands.append(command)
        if command[0] == "/usr/bin/openssl":
            self.assertEqual(input, PUBLIC)
            self.assertTrue(signing.CREDENTIAL_KEYS.isdisjoint(env))
            if self.fail == "openssl":
                raise subprocess.CalledProcessError(1, command, stderr="private stderr")
            return subprocess.CompletedProcess(command, 0, self.certificate_facts, "")
        self.assertEqual(command[0], "/usr/bin/security")
        self.assertTrue(capture_output)
        self.assertTrue(text)
        self.assertFalse(check)
        self.assertEqual(timeout, 30)
        self.assertTrue(signing.CREDENTIAL_KEYS.isdisjoint(env))
        action = command[1]
        if self.fail == action:
            raise subprocess.CalledProcessError(1, command, output="private output", stderr="private stderr")
        if action == "import":
            p12 = Path(command[2])
            self.assertEqual(p12.read_bytes(), b"private P12 fixture")
            self.assertEqual(stat.S_IMODE(p12.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(p12.parent.stat().st_mode), 0o700)
            self.assertEqual(command[-2:], ["-T", "/usr/bin/codesign"])
            self.assertNotIn("-A", command)
        output = ""
        if action == "list-keychains" and "-s" not in command:
            output = "\n".join(f'    "{path}"' for path in self.search) + "\n"
        if action == "find-identity":
            output = self.identities
        if action == "find-certificate":
            output = self.certificates
        return subprocess.CompletedProcess(command, 0, output, "")

    def start_child(self, command, *, env, start_new_session):
        self.assertEqual(command, ["fixture-child", "argument"])
        self.assertTrue(start_new_session)
        self.assertTrue(signing.CREDENTIAL_KEYS.isdisjoint(env))
        self.assertEqual(env["INTENTS_CI_SIGNING_TEAM"], TEAM)
        self.assertEqual(env["INTENTS_CI_SIGNING_IDENTITY"], FINGERPRINT)
        self.assertEqual(env["CI_TEST_SELECTION"], '["NativeMac"]')
        self.assertFalse(any(self.root.rglob("*.p12")), "P12 must be deleted before executing repository code")
        self.child_environments.append(env)
        return self.child

    def run_signed(self):
        self.output = io.StringIO()
        with contextlib.redirect_stderr(self.output):
            return signing.run_signed(["fixture-child", "argument"], self.environment)

    def assert_cleanup(self):
        commands = [command[1] for command in self.commands]
        self.assertIn("delete-keychain", commands)
        restore = ["/usr/bin/security", "list-keychains", "-d", "user", "-s", *self.search]
        self.assertIn(restore, self.commands)
        self.assertLess(self.commands.index(restore), commands.index("delete-keychain"))
        self.assertEqual(list(self.root.iterdir()), [])

    def test_success_uses_only_public_child_inputs_and_restores_search_list(self):
        self.assertEqual(self.run_signed(), 0)
        self.assertEqual(len(self.child_environments), 1)
        self.assert_cleanup()
        partition = next(command for command in self.commands if command[1] == "set-key-partition-list")
        self.assertEqual(partition[2:5], ["-S", "apple-tool:,apple:,codesign:", "-s"])
        self.assertNotIn("default-keychain", [command[1] for command in self.commands])

    def test_child_failure_and_signal_status_are_preserved_after_cleanup(self):
        for status, expected in [(17, 17), (-9, 137)]:
            with self.subTest(status=status):
                self.commands.clear()
                self.child = Child(status)
                self.assertEqual(self.run_signed(), expected)
                self.assert_cleanup()

    def test_missing_or_malformed_configuration_never_mutates_a_keychain(self):
        for key in signing.CREDENTIAL_KEYS:
            environment = {**self.environment, key: ""}
            with self.subTest(key=key), self.assertRaises(signing.SigningError):
                signing.run_signed(["fixture-child", "argument"], environment)
        for team in ["short", "abcdefghij", "ABCDEFGHIJ;", "ABCDEFGHIJ\n"]:
            with self.subTest(team=team), self.assertRaises(signing.SigningError):
                signing.configuration({**self.environment, "CI_MAC_SIGNING_TEAM": team})
        for encoded in ["!invalid!", base64.b64encode(b"").decode(), base64.b64encode(b"x" * (1024 * 1024 + 1)).decode()]:
            with self.assertRaises(signing.SigningError):
                signing.configuration({**self.environment, "CI_MAC_CERTIFICATE_P12_BASE64": encoded})
        self.assertEqual(self.commands, [])
        self.assertEqual(list(self.root.iterdir()), [])

    def test_release_and_foreign_team_identities_are_rejected_and_cleaned(self):
        for label in [f"Developer ID Application: CI Tests ({TEAM})", f"Apple Distribution: CI Tests ({TEAM})"]:
            with self.subTest(label=label):
                self.commands.clear()
                self.identities = f'1) {FINGERPRINT} "{label}"\n1 valid identities found\n'
                self.assertEqual(self.run_signed(), 1)
                self.assertEqual(self.child_environments, [])
                self.assert_cleanup()

    def test_zero_multiple_invalid_and_malformed_valid_identity_results_fail(self):
        for output in ["0 valid identities found\n", VALID.replace("1 valid", "0 valid"),
                       VALID.replace(FINGERPRINT, "A" * 39), VALID + VALID,
                       VALID.replace("1 valid", "2 valid")]:
            with self.subTest(output=output), self.assertRaises(signing.SigningError):
                signing.development_identity(output)

    def test_password_bearing_cli_failures_are_sanitized_and_all_cleanup_runs(self):
        for action in ["create-keychain", "unlock-keychain", "import", "set-key-partition-list", "find-identity", "find-certificate", "openssl"]:
            with self.subTest(action=action):
                self.commands.clear()
                self.fail = action
                self.assertEqual(self.run_signed(), 1)
                self.assert_cleanup()
                for secret in ["private-certificate-password", "private-keychain-password", "private output", "private stderr", "CalledProcessError"]:
                    self.assertNotIn(secret, self.output.getvalue())
        self.assertEqual(self.child_environments, [])

    def test_nonzero_security_status_is_sanitized(self):
        with mock.patch.object(signing.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "secret output", "secret error")):
            self.assertEqual(self.run_signed(), 1)
        self.assertNotIn("secret", self.output.getvalue())
        self.assertEqual(list(self.root.iterdir()), [])

    def test_term_reaps_owned_child_group_and_restores_the_keychain(self):
        self.child = Child(-15, interrupted=True)
        original_handler = signal.getsignal(signal.SIGTERM)
        with mock.patch.object(signing.os, "killpg") as kill:
            self.assertEqual(self.run_signed(), 143)
        self.assertEqual(kill.call_args_list, [mock.call(self.child.pid, signal.SIGTERM), mock.call(self.child.pid, signal.SIGKILL)])
        self.assertTrue(self.child.finished)
        self.assertEqual(signal.getsignal(signal.SIGTERM), original_handler)
        self.assert_cleanup()

    def test_cleanup_grace_allows_nested_helpers_to_drain_before_final_kill(self):
        with mock.patch.object(self.child, "poll", side_effect=AssertionError("poll would reap the leader")):
            signing.stop_child(self.child)
        self.pause.assert_called_once_with(20)
        self.assertEqual(self.group.call_args_list, [mock.call(self.child.pid, signal.SIGTERM), mock.call(self.child.pid, signal.SIGKILL)])
        self.assertTrue(self.child.finished)

    def test_darwin_denied_signal_requires_positive_group_absence(self):
        for absence, accepted in [(ProcessLookupError(), True), (None, False), (PermissionError(), False)]:
            self.child = Child()
            with self.subTest(accepted=accepted), mock.patch.object(signing.os, "killpg", side_effect=[PermissionError(), PermissionError(), absence]):
                if accepted:
                    signing.stop_child(self.child, grace_seconds=0)
                else:
                    with self.assertRaises((signing.SigningError, PermissionError)):
                        signing.stop_child(self.child, grace_seconds=0)

    def test_public_leaf_team_is_ou_and_not_developer_cn_suffix(self):
        self.assertNotEqual("DEVELOPER1", TEAM)
        self.assertEqual(self.run_signed(), 0)
        for facts in [FACTS.replace("OU=" + TEAM, "OU=KLMNOPQRST"), FACTS.replace("    OU=" + TEAM + "\n", ""),
                      FACTS + "    OU=" + TEAM + "\n", FACTS.replace("sha1 Fingerprint=", "invalid=")]:
            with self.subTest(facts=facts):
                self.commands.clear()
                self.certificate_facts = facts
                self.assertEqual(self.run_signed(), 1)
                self.assert_cleanup()

    def test_public_leaf_must_match_selected_fingerprint_once(self):
        for certificates, facts in [(PUBLIC + "\n" + PUBLIC, FACTS), (PUBLIC, FACTS.replace("AA:", "BB:")),
                                    ("garbage", FACTS), (PUBLIC + "garbage", FACTS)]:
            with self.subTest(certificates=certificates):
                self.commands.clear()
                self.certificates, self.certificate_facts = certificates, facts
                self.assertEqual(self.run_signed(), 1)
                self.assert_cleanup()

    def test_cleanup_failure_fails_success_but_preserves_failed_child_status(self):
        for status, expected in [(0, 1), (19, 19)]:
            with self.subTest(status=status):
                self.commands.clear()
                self.child = Child(status)
                self.fail = "delete-keychain"
                self.assertEqual(self.run_signed(), expected)
                self.assertIn("cleanup failed", self.output.getvalue())
                self.assertEqual(list(self.root.iterdir()), [])

    def test_child_launch_exception_cannot_expose_credential_arguments(self):
        with mock.patch.object(signing.subprocess, "Popen", side_effect=subprocess.CalledProcessError(1, ["private-certificate-password"])):
            self.assertEqual(self.run_signed(), 1)
        self.assertNotIn("private-certificate-password", self.output.getvalue())
        self.assert_cleanup()

    def test_cli_missing_configuration_is_a_clear_failed_gate(self):
        with mock.patch.dict(signing.os.environ, {}, clear=True), contextlib.redirect_stderr(io.StringIO()) as output:
            self.assertEqual(signing.main(["--", "fixture-child"]), 1)
        self.assertIn("CI_MAC_CERTIFICATE_P12_BASE64", output.getvalue())
        self.assertIn("separate Apple Development identity", output.getvalue())
        self.assertEqual(self.commands, [])


class OwnedGroupTests(unittest.TestCase):
    def wait_for_file(self, path):
        deadline = time.monotonic() + 5
        while not path.exists():
            if time.monotonic() > deadline:
                self.fail("Tiny child process did not become ready")
            time.sleep(0.01)

    def test_exited_leader_still_owns_and_stops_its_live_same_group_descendant(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            heartbeat, ready = root / "heartbeat", root / "ready"
            nested = f"""import pathlib, signal, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
heartbeat = pathlib.Path({str(heartbeat)!r})
pathlib.Path({str(ready)!r}).touch()
for index in range(10000):
    heartbeat.write_text(str(index))
    time.sleep(0.01)
"""
            leader = f"""import subprocess, sys, time, os, pathlib
subprocess.Popen([sys.executable, '-c', {nested!r}])
while not pathlib.Path({str(ready)!r}).exists(): time.sleep(0.01)
os._exit(7)
"""
            child = subprocess.Popen([sys.executable, "-c", leader], start_new_session=True,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                self.wait_for_file(heartbeat)
                self.assertEqual(signing.wait_for_exit(child), 7)
                self.assertIsNone(child.returncode, "Exit observation must not reap the leader")
                signing.stop_child(child, grace_seconds=0.05)
                self.assertEqual(child.returncode, 7)
                time.sleep(0.05)
                final = heartbeat.read_bytes()
                time.sleep(0.1)
                self.assertEqual(heartbeat.read_bytes(), final, "Live descendant must stop even after leader exit")
            finally:
                if child.returncode is None:
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except (ProcessLookupError, PermissionError):
                        pass
                    child.wait(timeout=5)

    def test_grace_allows_nested_separate_session_child_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready, nested_done, leader_done = (root / name for name in ("ready", "nested-done", "leader-done"))
            nested = f"""import pathlib, signal, time

def stop(*_):
    time.sleep(0.15)
    pathlib.Path({str(nested_done)!r}).touch()
    raise SystemExit(0)
signal.signal(signal.SIGTERM, stop)
pathlib.Path({str(ready)!r}).touch()
# If the owning parent is interrupted before forwarding termination, this
# separate-session fixture still exits itself without a saved-PID signal.
time.sleep(3)
"""
            leader = f"""import pathlib, signal, subprocess, sys, time
child = subprocess.Popen([sys.executable, '-c', {nested!r}], start_new_session=True)
def stop(*_):
    child.terminate()
    child.wait(timeout=5)
    pathlib.Path({str(leader_done)!r}).touch()
    raise SystemExit(143)
signal.signal(signal.SIGTERM, stop)
while not pathlib.Path({str(ready)!r}).exists(): time.sleep(0.01)
time.sleep(60)
"""
            child = subprocess.Popen([sys.executable, "-c", leader], start_new_session=True,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                self.wait_for_file(ready)
                signing.stop_child(child, grace_seconds=0.5)
                self.assertEqual(child.returncode, 143)
                self.assertTrue(nested_done.exists())
                self.assertTrue(leader_done.exists())
            finally:
                if child.returncode is None:
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except (ProcessLookupError, PermissionError):
                        pass
                    child.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
