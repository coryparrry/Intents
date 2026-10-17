"""Check native shard selection and relocated test-product execution."""

import importlib.util
import io
import json
import os
import selectors
import signal
import subprocess
from pathlib import Path
import sys
import tempfile
import textwrap
import time
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "ci_native_tests.py"
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("ci_native_tests", SCRIPT)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class NativeShardTests(unittest.TestCase):
    def test_ui_shard_reuses_build_and_disables_shared_desktop_workers(self):
        test = "FoundationEvalsUITests/AppAutomationUITests/testPreparationPickersUseStableIdentifiers"
        with patch.object(runner, "prepare_ui_xctestrun", return_value=Path("full.xctestrun")) as prepare:
            command = runner.test_command(Path("Products"), [test, test], Path("ui.xcresult"))
        prepare.assert_called_once_with(Path("Products"))
        self.assertEqual(command[:2], ["xcodebuild", "test-without-building"])
        self.assertEqual(command.count(f"-only-testing:{test}"), 1)
        self.assertEqual(command[command.index("-parallel-testing-enabled") + 1], "NO")
        self.assertNotIn("-test-iterations", command)

    def test_core_shard_keeps_parallel_execution_and_excludes_ui(self):
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary)
            descriptor = products / "FoundationEvalsCoreCI_macosx27.0-arm64.xctestrun"
            descriptor.touch()
            command = runner.test_command(products, ["FoundationEvalsTests"], Path("core.xcresult"))
        self.assertIn(str(descriptor), command)
        self.assertIn("-only-testing:FoundationEvalsTests", command)
        self.assertEqual(command[command.index("-parallel-testing-enabled") + 1], "YES")

    def test_missing_or_ambiguous_descriptors_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary)
            for names in ([], ["FoundationEvals_macosx27.xctestrun", "FoundationEvalsCoreCI_macosx27.xctestrun"]):
                for name in names:
                    (products / name).touch()
                with self.assertRaisesRegex(ValueError, "exactly one"):
                    runner.test_command(products, ["FoundationEvalsTests"], Path("result"))

    def test_invalid_and_empty_selections_fail_before_descriptor_access(self):
        for selection in ([], None, {}, [None], ["--help"], ["FoundationEvalsUITests/Foo/../../bad"], ["OtherTests"]):
            with self.subTest(selection=selection), patch.object(runner, "prepare_ui_xctestrun") as prepare:
                with self.assertRaises(ValueError):
                    runner.test_command(Path("missing"), selection, Path("result"))
                prepare.assert_not_called()

    def test_repetitions_are_explicit_and_positive(self):
        with patch.object(runner, "prepare_ui_xctestrun", return_value=Path("ui.xctestrun")):
            command = runner.test_command(Path("Products"), ["FoundationEvalsUITests/Foo/testPicker"], Path("result"), 10)
            self.assertEqual(command[command.index("-test-iterations") + 1], "10")
            for iterations in (0, -1, True):
                with self.assertRaises(ValueError):
                    runner.test_command(Path("Products"), ["FoundationEvalsUITests/Foo"], Path("result"), iterations)

    def test_each_selected_class_or_method_must_have_passed(self):
        log = "Test Case '-[FoundationEvalsUITests.Foo testPicker]' passed (1.0 seconds)."
        runner.verify_ui_selection(log, ["FoundationEvalsUITests/Foo", "FoundationEvalsUITests/Foo/testPicker"])
        for test in ("FoundationEvalsUITests/Other", "FoundationEvalsUITests/Foo/testRemoved"):
            with self.assertRaisesRegex(ValueError, "did not pass"):
                runner.verify_ui_selection(log, [test])

    def test_failed_skipped_or_zero_tests_are_not_a_successful_selection(self):
        for outcome in ("failed", "skipped", "started"):
            with self.assertRaises(ValueError):
                runner.verify_ui_selection(f"Test Case '-[Foo testPicker]' {outcome}", ["FoundationEvalsUITests/Foo"])
        with self.assertRaises(ValueError):
            runner.verify_ui_selection("Executed 0 tests", ["FoundationEvalsUITests/Foo"])

    def test_native_swift_testing_symbols_are_checked_independently_of_display_names(self):
        document = {"testNodes": [{"children": [{
            "nodeType": "Test Case", "name": "A friendly display name", "result": "Passed",
            "nodeIdentifierURL": "test://com.apple.xcode/Plan/FoundationEvalsTests/FooTests/checkValue",
        }]}]}
        runner.verify_native_selection(document, ["FoundationEvalsTests", "FoundationEvalsTests/FooTests"])
        for missing in ("FoundationEvalsTests/OtherFooTests", "FoundationEvalsTests/FooTestsExtra"):
            with self.assertRaisesRegex(ValueError, "did not pass"):
                runner.verify_native_selection(document, [missing])

    def test_each_native_suite_must_have_a_passing_case(self):
        for result in ("Failed", "Skipped"):
            document = {"testNodes": [{
                "nodeType": "Test Case", "result": result,
                "nodeIdentifierURL": "test://com.apple.xcode/Plan/FoundationEvalsTests/FooTests/checkValue",
            }]}
            with self.assertRaises(ValueError):
                runner.verify_native_selection(document, ["FoundationEvalsTests/FooTests"])
        with self.assertRaises(ValueError):
            runner.verify_native_selection({"testNodes": []}, ["FoundationEvalsTests"])

    def test_malformed_native_results_fail_instead_of_accepting_zero_tests(self):
        for document in ({}, {"testNodes": None}, {"testNodes": [None]}):
            with self.assertRaises(ValueError):
                runner.verify_native_selection(document, ["FoundationEvalsTests"])


class LoggedExecutionTests(unittest.TestCase):
    def test_output_is_retained_and_streamed_before_the_process_exits(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "tests.log"
            acknowledged = Path(directory) / "acknowledged"
            class LiveOutput(io.BytesIO):
                def write(self, data):
                    count = super().write(data)
                    if b"ready" in self.getvalue():
                        # The child cannot exit until its live output reaches us.
                        self.assert_retained = b"ready" in log.read_bytes()
                        acknowledged.touch()
                    return count
            output = LiveOutput()
            code = "\n".join([
                "import pathlib, sys, time",
                "print('ready', flush=True)",
                f"acknowledged = pathlib.Path({str(acknowledged)!r})",
                "while not acknowledged.exists(): time.sleep(0.01)",
                "print('stderr: café', file=sys.stderr, flush=True)",
            ])
            runner.run_logged([sys.executable, "-c", code], log, timeout=10, output=output)
            self.assertTrue(output.assert_retained)
            self.assertEqual(log.read_bytes(), output.getvalue())
            self.assertIn("stderr: café".encode(), output.getvalue())

    def test_nonzero_exit_preserves_output_and_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            log, output = Path(directory) / "tests.log", io.BytesIO()
            with self.assertRaises(subprocess.CalledProcessError) as failure:
                runner.run_logged([sys.executable, "-c", "print('failure detail', flush=True); raise SystemExit(7)"],
                                  log, timeout=10, output=output)
            self.assertEqual(failure.exception.returncode, 7)
            self.assertEqual(log.read_bytes(), b"failure detail\n")
            self.assertEqual(log.read_bytes(), output.getvalue())

    @staticmethod
    def child_fixture(pid_file):
        # The parent reaps its child after group TERM, so absence is independently
        # observable without relying on this machine's orphan-reaping behavior.
        return textwrap.dedent(f"""\
            import json, os, signal, subprocess, sys, time
            from pathlib import Path
            child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
            def terminate(_number, _frame):
                print('fixture shutdown', flush=True)
                child.wait(timeout=3)
                raise SystemExit(0)
            signal.signal(signal.SIGTERM, terminate)
            Path({str(pid_file)!r}).write_text(json.dumps([os.getpid(), child.pid]))
            print('fixture ready', flush=True)
            time.sleep(60)
            """)

    def assert_processes_absent(self, pid_file):
        for pid in json.loads(pid_file.read_text()):
            with self.subTest(pid=pid), self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    def test_timeout_releases_owned_child_group_and_leaves_unrelated_process(self):
        with tempfile.TemporaryDirectory() as directory:
            log, pid_file = Path(directory) / "tests.log", Path(directory) / "pids.json"
            unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
            output = io.BytesIO()
            try:
                with self.assertRaises(subprocess.TimeoutExpired):
                    runner.run_logged([sys.executable, "-c", self.child_fixture(pid_file)], log,
                                      timeout=2, output=output, cleanup_grace=0.5)
                self.assert_processes_absent(pid_file)
                self.assertIsNone(unrelated.poll(), "Cleanup must not stop an unrelated process")
                self.assertIn(b"fixture ready", log.read_bytes())
                self.assertIn(b"fixture shutdown", log.read_bytes())
                self.assertEqual(log.read_bytes(), output.getvalue())
            finally:
                unrelated.terminate()
                unrelated.wait(timeout=5)

    def test_timeout_escalates_when_the_owned_process_ignores_term(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / "pids.json"
            code = ("import json, os, signal, time; from pathlib import Path; "
                    "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                    f"Path({str(pid_file)!r}).write_text(json.dumps([os.getpid()])); "
                    "print('ignoring TERM', flush=True); time.sleep(60)")
            with self.assertRaises(subprocess.TimeoutExpired):
                runner.run_logged([sys.executable, "-c", code], Path(directory) / "tests.log",
                                  timeout=2, output=io.BytesIO(), cleanup_grace=0.5)
            self.assert_processes_absent(pid_file)

    def test_wrapper_term_cleans_its_group_and_preserves_partial_log(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            products = root / "Products"
            products.mkdir()
            (products / "FoundationEvalsCoreCI_macosx27.xctestrun").touch()
            pid_file = root / "pids.json"
            executable = root / "xcodebuild"
            executable.write_text(f"#!{sys.executable}\n" + self.child_fixture(pid_file))
            executable.chmod(0o700)
            result = root / "tests.xcresult"
            environment = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                           "CI_TEST_SELECTION": '["FoundationEvalsTests"]'}
            process = subprocess.Popen([sys.executable, str(SCRIPT), "--products", str(products),
                                        "--result", str(result), "--timeout-seconds", "15"],
                                       env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 10
                log = result.with_suffix(".log")
                while time.monotonic() < deadline:
                    if pid_file.exists() and log.exists() and b"fixture ready" in log.read_bytes():
                        break
                    time.sleep(0.01)
                self.assertTrue(pid_file.exists() and log.exists() and b"fixture ready" in log.read_bytes(),
                                "The owned Xcode fixture did not start")
                process.terminate()
                output, _ = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 128 + signal.SIGTERM, output.decode())
                self.assert_processes_absent(pid_file)
                self.assertIn(b"fixture ready", result.with_suffix(".log").read_bytes())
                self.assertIn(b"fixture shutdown", output)
                self.assertEqual(result.with_suffix(".log").read_bytes(), output)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
                process.stdout.close()

    def test_exited_leader_with_inherited_pipe_fails_and_cleans_without_execution_deadline(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready, stopped, log = root / "ready", root / "stopped", root / "tests.log"
            child = textwrap.dedent(f"""\
                import signal, time
                from pathlib import Path
                def terminate(_number, _frame):
                    print('grandchild shutdown', flush=True)
                    Path({str(stopped)!r}).touch()
                    raise SystemExit(0)
                signal.signal(signal.SIGTERM, terminate)
                Path({str(ready)!r}).touch()
                print('grandchild ready', flush=True)
                time.sleep(5)
                """)
            parent = ("import subprocess, sys, time; from pathlib import Path; "
                      f"subprocess.Popen([sys.executable, '-c', {child!r}]); "
                      f"ready = Path({str(ready)!r})\n"
                      "while not ready.exists(): time.sleep(0.01)\n")
            output = io.BytesIO()
            with self.assertRaisesRegex(RuntimeError, "descendants kept its output pipe open"):
                runner.run_logged([sys.executable, "-c", parent], log, output=output,
                                  cleanup_grace=0.5, exit_drain_timeout=0.1)
            self.assertTrue(stopped.exists(), "The inherited-pipe child must receive owned-group cleanup")
            self.assertIn(b"grandchild shutdown", log.read_bytes())
            self.assertEqual(log.read_bytes(), output.getvalue())

    def test_denied_final_signal_requires_independent_group_absence(self):
        class ExitedLeader:
            pid, returncode = 42, None
            def wait(self, timeout):
                self.returncode = 0
                return 0
        for absent in (True, False):
            def signal_group(_group, number):
                if number == signal.SIGKILL:
                    raise PermissionError("Final signal denied")
                if number == 0 and absent:
                    raise ProcessLookupError("Group absent after reaping its leader")
            with self.subTest(absent=absent), selectors.DefaultSelector() as selector:
                with patch.object(runner.os, "killpg", side_effect=signal_group):
                    if absent:
                        runner._stop_owned_group(ExitedLeader(), 0, selector, io.BytesIO(), io.BytesIO())
                    else:
                        with self.assertRaises(PermissionError):
                            runner._stop_owned_group(ExitedLeader(), 0, selector, io.BytesIO(), io.BytesIO())

    def test_invalid_deadlines_fail_before_launch(self):
        for timeout in (0, -1, float("inf"), float("nan")):
            with self.subTest(timeout=timeout), tempfile.TemporaryDirectory() as directory:
                with self.assertRaisesRegex(ValueError, "positive and finite"):
                    runner.run_logged(["missing-executable"], Path(directory) / "tests.log", timeout)


if __name__ == "__main__":
    unittest.main()
