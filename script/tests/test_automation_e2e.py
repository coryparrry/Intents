"""Plan, receipt, recovery ordering and owned-resource checks without Apple tooling."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "automation_e2e.py"
spec = importlib.util.spec_from_file_location("automation_e2e", SCRIPT)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


def catalog():
    actions = []
    for family, name in {
        "text": "EchoTextIntent", "bool": "EchoBoolIntent", "integer": "EchoIntegerIntent",
        "decimal": "EchoDecimalIntent", "date": "EchoDateIntent", "enum": "EchoEnumIntent",
        "entity": "EchoEntityIntent", "duration": "EchoDurationIntent",
        "calendarComponents": "EchoCalendarComponentsIntent", "url": "EchoURLIntent",
        "intentFile": "EchoIntentFileIntent", "textArray": "EchoTextArrayIntent",
        "boolArray": "EchoBoolArrayIntent", "integerArray": "EchoIntegerArrayIntent",
        "decimalArray": "EchoDecimalArrayIntent", "dateArray": "EchoDateArrayIntent",
    }.items():
        parameter = {"name": "value", "family": family, "optional": False}
        if family in ("enum", "entity"):
            parameter["typeID"] = "CapturedChoice" if family == "enum" else "CapturedReference"
        actions.append({"id": name, "compiled": True, "parametersComplete": True,
                        "parameters": [parameter], "resultFamily": "text" if family in ("enum", "entity") else family})
    actions.extend([
        {"id": "MakeFixtureFileIntent", "compiled": True, "parametersComplete": True,
         "parameters": [], "resultFamily": "intentFile"},
        {"id": "CompleteTaskIntent", "compiled": True, "parametersComplete": True,
         "parameters": [{"name": "task", "family": "entity", "typeID": "CapturedTask"}], "resultFamily": "noValue"},
    ])
    return {"systemActions": actions, "entities": [{"typeID": "CapturedTask", "queryIdentifier": "TaskQuery",
                                                   "properties": {"title": "text", "owner": "text", "completed": "bool"}}]}


def prepared():
    return {"host": {"app": {"bundleID": "example.fixture"},
                     "target": {"id": "11111111-1111-1111-1111-111111111111", "kind": "simulator"}},
            "catalog": catalog()}


def report(summary="executedUnassessed", values=None):
    return {"resourcesReleased": True, "result": {"summary": summary, "subjectDispatched": True,
            "subjectCompleted": True, "subjectDispatchUncertain": False, "evidenceComplete": True,
            "assessed": summary in ("passed", "assertionFailed")},
            "receipts": [{"segmentID": "subject", "dispatched": True, "completed": True,
                          "verifiedOutputs": values or {}}]}


class PlanAndReceiptTests(unittest.TestCase):
    def test_exact_codec_contract_has_two_bounded_batches_and_five_empty_arrays(self):
        batches = driver.echo_batches(catalog())
        self.assertEqual([len(ops) for ops, _ in batches], [10, 10])
        operations = [op for ops, _ in batches for op in ops]
        self.assertEqual({op["id"] for op in operations if op["id"].startswith("empty.")},
                         {"empty." + family for family in driver.ARRAYS})
        self.assertEqual({op["id"] for op in operations if not op["id"].startswith("empty.")},
                         set(driver.FAMILIES) - {"intentFile"})
        self.assertEqual(batches[0][0][2]["parameters"]["value"], driver.integer(9007199254740993))
        enum_op = next(op for op in operations if op["id"] == "enum")
        self.assertEqual(enum_op["parameters"]["value"]["typeId"], "CapturedChoice")
        self.assertEqual(batches[0][1]["enum"], driver.tagged("text", "second"))
        for op in operations:
            if op["id"].startswith("empty."):
                self.assertEqual(op["parameters"]["value"], driver.tagged("array", []))
                self.assertEqual(op["parameterCodecs"]["value"], op["id"].removeprefix("empty."))

    def test_corrupt_metadata_is_rejected_before_execution(self):
        for mutation in ("missing", "duplicate", "uncompiled", "wrong-family"):
            source = catalog()
            if mutation == "missing":
                source["systemActions"].pop(0)
            elif mutation == "duplicate":
                source["systemActions"].append(copy.deepcopy(source["systemActions"][0]))
            elif mutation == "uncompiled":
                source["systemActions"][0]["compiled"] = False
            else:
                source["systemActions"][0]["parameters"][0]["family"] = "integer"
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError):
                driver.echo_batches(source)

    def test_echo_checks_exact_values_and_does_not_fake_business_assessment(self):
        _, expected = driver.echo_batches(catalog())[0]
        good = report(values=copy.deepcopy(expected))
        driver.verify_echo(good, expected)
        for mutation in ("value", "missing", "extra", "assessment", "release", "uncertain", "evidence"):
            bad = copy.deepcopy(good)
            if mutation == "value":
                bad["receipts"][0]["verifiedOutputs"]["integer"] = driver.integer(9007199254740992)
            elif mutation == "missing":
                bad["receipts"][0]["verifiedOutputs"].pop("date")
            elif mutation == "extra":
                bad["receipts"][0]["verifiedOutputs"]["extra"] = driver.tagged("text", "unexpected")
            elif mutation == "assessment":
                bad["result"]["assessed"] = True
            elif mutation == "release":
                bad["resourcesReleased"] = False
            elif mutation == "uncertain":
                bad["result"]["subjectDispatchUncertain"] = True
            else:
                bad["result"]["evidenceComplete"] = False
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError):
                driver.verify_echo(bad, expected)

    def test_file_uses_verified_producer_binding_and_checks_both_digests(self):
        plan = driver.file_case(prepared())
        binding = plan["execution"]["inputBindings"][0]
        self.assertEqual(binding["producerSegmentID"], plan["setup"][0]["id"])
        self.assertEqual(binding["parameterCodec"], "intentFile")
        self.assertEqual(plan["execution"]["hostProgram"]["operations"][0]["parameters"], {})
        file_value = driver.tagged("artifact", "owned-file", sha256=driver.FILE_SHA)
        good = report(values={"file.echo": file_value})
        good["receipts"].append({"segmentID": "file.producer", "dispatched": True, "completed": True,
                                 "verifiedOutputs": {"file": copy.deepcopy(file_value)}})
        driver.verify_file(good)
        for index, key in ((0, "file.echo"), (1, "file")):
            bad = copy.deepcopy(good)
            bad["receipts"][index]["verifiedOutputs"][key]["sha256"] = "0" * 64
            with self.subTest(receipt=index), self.assertRaises(AssertionError):
                driver.verify_file(bad)

    def test_mixed_case_uses_ui_creation_real_entity_binding_and_independent_observer(self):
        plan = driver.mixed_case(prepared(), "mixed")
        self.assertEqual([s["kind"] for s in plan["setup"]], ["ui", "systemQuery"])
        self.assertEqual(plan["execution"]["hostProgram"]["operations"][0]["typeID"], "CompleteTaskIntent")
        binding = plan["execution"]["inputBindings"][0]
        self.assertEqual(binding["producerSegmentID"], "before")
        self.assertEqual(binding["uniqueEntity"]["matchingProperties"]["owner"], driver.tagged("text", "Personal"))
        check = plan["requirements"][0]
        self.assertEqual(check["observationID"], plan["observations"][0]["id"])
        self.assertEqual(check["entityProperty"]["property"], "completed")
        self.assertEqual(check["expected"], driver.tagged("bool", True))
        wrong = driver.mixed_case(prepared(), "wrong", expected=False)
        self.assertEqual(wrong["requirements"][0]["expected"], driver.tagged("bool", False))

    def test_timeout_is_subject_ui_wait_with_generous_outer_budget(self):
        plan = driver.timeout_case(prepared())
        self.assertEqual(plan["setup"], [])
        self.assertEqual(plan["execution"]["phase"], "subject")
        steps = plan["execution"]["uiProgram"]["steps"]
        self.assertEqual([s["kind"] for s in steps], ["launch", "waitFor"])
        self.assertEqual(steps[1]["timeout"], 2)
        self.assertEqual(steps[1]["query"]["identifier"], "phase3.deliberately.missing")
        self.assertGreater(plan["budget"]["wallClockSeconds"], 120)

    def test_quarantine_and_missing_lease_file_are_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(FileNotFoundError):
                driver.verify_campaigns(root)
            state = root / "target-leases.json"
            state.write_text(json.dumps({"campaigns": {"owned-simulator": {"quarantine": True}}}))
            with self.assertRaises(AssertionError):
                driver.verify_campaigns(root)
            state.write_text(json.dumps({"campaigns": {}}))
            driver.verify_campaigns(root)


class FakeCommands:
    def __init__(self, output, failure=None):
        self.output, self.failure, self.calls, self.saved = output, failure, [], {}

    def run(self, arguments, **options):
        args = [str(a) for a in arguments]
        self.calls.append((args, options))
        if self.failure and self.failure in args:
            raise RuntimeError("injected command failure")
        if args[:3] == ["xcrun", "simctl", "create"]:
            return 0, prepared()["host"]["target"]["id"]
        if "--show-sdk-version" in args:
            return 0, "27.0"
        if "--show-bin-path" in args:
            return 0, str(Path(args[args.index("--scratch-path") + 1]) / "debug")
        return 0, ""

    def json(self, arguments, **options):
        args = [str(a) for a in arguments]
        self.run(arguments, **options)
        if "runtimes" in args:
            return 0, {"runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                                    "isAvailable": True, "version": "27.0"}]}
        if "devicetypes" in args:
            return 0, {"devicetypes": [{"identifier": "device.iphone", "name": "iPhone fixture"}]}
        if "devices" in args:
            return 0, {"devices": {}}
        if "prepare" in args:
            support = Path(args[args.index("--support-root") + 1])
            support.mkdir()
            (support / "target-leases.json").write_text(json.dumps({"campaigns": {}}))
            return 0, prepared()
        if "actions" in args:
            return 0, catalog()
        if "show" in args:
            return 0, self.saved[args[args.index("show") + 1]]
        if "run" in args:
            envelope = json.loads(Path(args[args.index("--plan") + 1]).read_text())
            plan = envelope["plan"]
            summary = "executedUnassessed"
            if plan["requirements"]:
                summary = "passed" if plan["requirements"][0]["expected"]["value"] else "assertionFailed"
            if plan["id"] == "phase3.timeout":
                summary = "timedOut"
            values = {}
            for op in plan["execution"].get("hostProgram", {}).get("operations", []):
                if "value" in op["parameters"]:
                    value = op["parameters"]["value"]
                    values[op["id"]] = driver.tagged("text", value["value"]) if value["kind"] in ("enum", "entity") else value
            result = report(summary, values)
            if plan["id"].endswith("codec-file"):
                value = driver.tagged("artifact", "owned-file", sha256=driver.FILE_SHA)
                result["receipts"][0]["verifiedOutputs"] = {"file.echo": value}
                result["receipts"].append({"segmentID": "file.producer", "dispatched": True, "completed": True,
                                            "verifiedOutputs": {"file": value}})
            if summary == "timedOut":
                result["result"].update(subjectCompleted=False, subjectDispatchUncertain=True, evidenceComplete=False)
            self.saved[envelope["attemptID"]] = result
            return (0 if summary in ("passed", "executedUnassessed") else 1), result
        raise AssertionError(f"Unhandled fake JSON command: {args}")


class RegistrationReadinessTests(unittest.TestCase):
    def exercise(self, failures=0, mutation=None):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        output = Path(temporary.name)
        support = output / "support"
        support.mkdir()
        (support / "target-leases.json").write_text(json.dumps({"campaigns": {}}))
        value = driver.tagged("text", "registration-ready")
        attempts = []
        for index in range(failures + 1):
            attempt = "readiness-" + str(index)
            result = report(values={"registration": value})
            code = 0
            if index < failures:
                result = report("timedOut")
                result["result"].update(subjectDispatched=False, subjectCompleted=False,
                                        subjectDispatchUncertain=True, evidenceComplete=False)
                result["receipts"] = []
                artifact = support / attempt / "artifacts"
                artifact.mkdir(parents=True)
                marker = 'Error Domain=AppIntentsServicesMetadataErrorDomain Code=400 "example.fixture is not present"'
                if mutation in ("other-error", "other-bundle"):
                    marker = marker.replace("Code=400", "Code=401") if mutation == "other-error" else marker.replace("example.fixture", "other.fixture")
                if mutation != "missing-log":
                    (artifact / "apple-command-failure-4-test.txt").write_text(marker)
                if mutation == "unreleased":
                    result["resourcesReleased"] = False
                if mutation == "dispatched":
                    result["result"]["subjectDispatched"] = True
                if mutation == "completed":
                    result["result"]["subjectCompleted"] = True
                if mutation == "receipt":
                    result["receipts"] = report()["receipts"]
                code = 1
            attempts.append((attempt, code, result))
        return output, support, attempts

    def test_registered_fixture_requires_one_exact_harmless_echo(self):
        output, support, attempts = self.exercise()
        with patch.object(driver, "run_plan", side_effect=attempts) as run:
            driver.wait_for_registration(None, "cli", support, output, prepared())
        run.assert_called_once()
        plan = run.call_args.args[-1]
        self.assertEqual(plan["id"], "phase3.registration")
        self.assertEqual(plan["setup"], [])
        self.assertEqual(plan["cleanup"], [])
        self.assertEqual(plan["execution"]["hostProgram"]["operations"], [{
            "id": "registration", "kind": "invoke", "typeID": "EchoTextIntent",
            "parameters": {"value": driver.tagged("text", "registration-ready")},
            "resultCodec": "text"}])

    def test_only_known_metadata_error_retries_after_release_and_retains_attempts(self):
        output, support, attempts = self.exercise(failures=1)
        with patch.object(driver, "run_plan", side_effect=attempts) as run:
            driver.wait_for_registration(None, "cli", support, output, prepared())
        self.assertEqual(run.call_count, 2)
        evidence = json.loads((output / "registration-readiness.json").read_text())
        self.assertEqual([a["summary"] for a in evidence], ["timedOut", "executedUnassessed"])

    def test_unrelated_failures_and_unreleased_or_partly_completed_runs_do_not_retry(self):
        for mutation in ("other-error", "other-bundle", "missing-log", "unreleased", "dispatched", "completed", "receipt"):
            with self.subTest(mutation=mutation):
                output, support, attempts = self.exercise(failures=1, mutation=mutation)
                with patch.object(driver, "run_plan", side_effect=attempts) as run:
                    with self.assertRaises(AssertionError):
                        driver.wait_for_registration(None, "cli", support, output, prepared())
                self.assertEqual(run.call_count, 1)

    def test_registration_wait_stops_after_three_failed_attempts(self):
        output, support, attempts = self.exercise(failures=3)
        with patch.object(driver, "run_plan", side_effect=attempts) as run:
            with self.assertRaisesRegex(AssertionError, "Expected executedUnassessed"):
                driver.wait_for_registration(None, "cli", support, output, prepared())
        self.assertEqual(run.call_count, 3)

    def test_success_still_requires_exact_output_and_successful_exit(self):
        for mutation in ("output", "exit"):
            with self.subTest(mutation=mutation):
                output, support, attempts = self.exercise()
                attempt, code, result = attempts[0]
                if mutation == "output":
                    result["receipts"][0]["verifiedOutputs"]["registration"] = driver.tagged("text", "wrong")
                else:
                    code = 1
                with patch.object(driver, "run_plan", return_value=(attempt, code, result)) as run:
                    with self.assertRaises(AssertionError):
                        driver.wait_for_registration(None, "cli", support, output, prepared())
                run.assert_called_once()


class WorkflowTests(unittest.TestCase):
    def test_mac_input_diagnostic_is_live_scoped_and_preserves_separate_evidence(self):
        workflow = (SCRIPT.parents[1] / ".github/workflows/ci.yml").read_text()
        job = workflow.split("\n  input-conversion:\n", 1)[1]
        self.assertIn("name: Input conversion diagnostic (Mac)", job)
        self.assertIn("needs.changes.outputs.automation_e2e == 'true'", job)
        self.assertIn("runs-on: xcode-27", job)
        self.assertIn("timeout-minutes: 30", job)
        self.assertIn("INTENTS_MAC_INPUT_PROBE_FIXTURE_LIVE: '1'", job)
        self.assertIn("INTENTS_MAC_INPUT_PROBE_FIXTURE_ROOT: ${{ runner.temp }}/input-conversion", job)
        self.assertIn('DEVELOPER_DIR="$(xcode-select -p)"', job)
        self.assertIn('export DEVELOPER_DIR\n', job)
        self.assertIn("swift test --jobs 2", job)
        self.assertIn("--filter 'AutomationMacInputProbeFixtureTests/testAuthoredInputProbeFixtureWhenRequested'", job)
        self.assertIn('--scratch-path "$RUNNER_TEMP/input-conversion-build"', job)
        self.assertIn("set -o pipefail", job)
        self.assertIn("Live input canary did not pass", job)
        self.assertIn("Live calibration did not execute", job)
        self.assertIn("path: ${{ runner.temp }}/input-conversion\n", job)
        self.assertNotIn("--skip-build", job)
        self.assertNotIn("INTENTS_AUTOMATION_LIVE_UI", job)
        self.assertIn("neither executes a business subject nor grants codec execution authority", job)


class OrchestrationTests(unittest.TestCase):
    def exercise(self, failure=None, reuse_build=False):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / "repo/examples/AutomationFixture").mkdir(parents=True)
        (root / "repo/examples/AutomationFixture/project.yml").write_text("name: fixture")
        output = root / "evidence"
        output.mkdir()
        commands = FakeCommands(output, failure)
        build_root = root / "reusable-swift-cache" if reuse_build else None
        if build_root:
            build_root.mkdir()
            (build_root / "keep-cache").write_text("reusable")
        with patch.object(driver, "ROOT", root / "repo"):
            if failure:
                with self.assertRaisesRegex(RuntimeError, "injected"):
                    driver.run_contract(commands, output)
            else:
                results = driver.run_contract(commands, output, build_root=build_root)
        if build_root:
            self.assertEqual((build_root / "keep-cache").read_text(), "reusable")
        return commands, results if not failure else None

    def test_prepare_once_and_good_run_immediately_after_timeout(self):
        commands, results = self.exercise()
        calls = [args for args, _ in commands.calls]
        self.assertEqual(sum("prepare" in args for args in calls), 1)
        self.assertEqual([r["summary"] for r in results], ["executedUnassessed"] * 3 +
                         ["passed", "assertionFailed", "timedOut", "executedUnassessed"])
        self.assertEqual(results[-1]["case"], "phase3.after-timeout")
        self.assertTrue(all(r["exactOutputsCompared"] for r in results[:3]))
        self.assertEqual([args[2] for args in calls if args[:2] == ["xcrun", "simctl"]][-3:],
                         ["shutdown", "delete", "list"])
        owned = prepared()["host"]["target"]["id"]
        self.assertTrue(all(args[-1] == owned for args in calls if args[:3] in
                            (["xcrun", "simctl", "shutdown"], ["xcrun", "simctl", "delete"])))

    def test_swift_build_and_bin_path_use_the_same_external_reusable_cache(self):
        for reusable in (False, True):
            with self.subTest(reusable=reusable):
                commands, _ = self.exercise(reuse_build=reusable)
                builds = [args for args, _ in commands.calls if args[:2] == ["swift", "build"]]
                scratch_paths = [args[args.index("--scratch-path") + 1] for args in builds]
                expected = commands.output.parent / "reusable-swift-cache" if reusable else commands.output / "swift-build"
                self.assertEqual(scratch_paths, [str(expected), str(expected)])

    def test_cli_rejects_reusable_build_cache_inside_the_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(AssertionError, "Build cache must stay outside"):
                driver.main(["--output-root", directory, "--build-root", str(driver.ROOT / "cache")])

    def test_prepare_or_boot_failure_still_deletes_only_owned_simulator(self):
        for failure in ("prepare", "bootstatus"):
            with self.subTest(failure=failure):
                commands, _ = self.exercise(failure)
                calls = [args for args, _ in commands.calls]
                self.assertIn(["xcrun", "simctl", "delete", prepared()["host"]["target"]["id"]], calls)
                self.assertFalse(any("run" in args for args in calls))

    def test_simulator_selection_requires_available_ios_and_supported_iphone(self):
        runtimes = {"runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0",
                                  "isAvailable": True, "supportedDeviceTypes": [{"identifier": "phone.good"}]},
                                 {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-28-0", "version": "28.0", "isAvailable": False}]}
        types = {"devicetypes": [{"identifier": "phone.good", "name": "iPhone good"},
                                 {"identifier": "phone.bad", "name": "iPhone unsupported"}]}
        self.assertEqual(driver.simulator_configuration(runtimes, types),
                         ("com.apple.CoreSimulator.SimRuntime.iOS-27-0", "phone.good"))
        with self.assertRaises(AssertionError):
            driver.simulator_configuration({"runtimes": []}, types)

    def test_runtime_matches_selected_xcode_sdk_even_when_newer_runtime_is_available(self):
        runtimes = {"runtimes": [
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0", "isAvailable": True},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2", "version": "27.2", "isAvailable": True},
        ]}
        types = {"devicetypes": [{"identifier": "phone", "name": "iPhone fixture"}]}
        self.assertEqual(driver.simulator_configuration(runtimes, types, "27.0\n")[0],
                         "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        with self.assertRaisesRegex(AssertionError, "matching"):
            driver.simulator_configuration(runtimes, types, "26.0")

    def test_output_root_rejects_checkout_and_nonempty_artifact_directory(self):
        with self.assertRaisesRegex(AssertionError, "outside"):
            driver.main(["--output-root", str(driver.ROOT / "evidence")])
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "keep").write_text("existing")
            with self.assertRaisesRegex(AssertionError, "empty"):
                driver.main(["--output-root", directory])

    def test_sigterm_enters_python_cleanup_and_restores_original_handler(self):
        with tempfile.TemporaryDirectory() as directory:
            original = driver.signal.getsignal(driver.signal.SIGTERM)
            def terminate(commands, output, build_root=None):
                handler = driver.signal.getsignal(driver.signal.SIGTERM)
                handler(driver.signal.SIGTERM, None)
            with patch.object(driver, "run_contract", side_effect=terminate):
                self.assertEqual(driver.main(["--output-root", directory]), 1)
            self.assertEqual(driver.signal.getsignal(driver.signal.SIGTERM), original)
            summary = json.loads((Path(directory) / "summary.json").read_text())
            self.assertEqual(summary["status"], "failed")
            self.assertIn("Interrupted by signal", summary["error"])

    def test_bounded_command_terminates_only_its_owned_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            process = unittest.mock.Mock(pid=12345)
            process.wait.side_effect = [subprocess.TimeoutExpired("owned", 1), 0]
            with patch.object(driver.subprocess, "Popen", return_value=process) as launch, \
                 patch.object(driver.os, "killpg") as terminate:
                with self.assertRaises(subprocess.TimeoutExpired):
                    driver.Commands(Path(directory)).run(["owned"], timeout=1)
            self.assertTrue(launch.call_args.kwargs["start_new_session"])
            terminate.assert_called_once_with(12345, driver.signal.SIGTERM)
            self.assertTrue((Path(directory) / "01-owned.command.json").exists())
            self.assertTrue((Path(directory) / "01-owned.stdout.log").exists())


if __name__ == "__main__":
    unittest.main()
