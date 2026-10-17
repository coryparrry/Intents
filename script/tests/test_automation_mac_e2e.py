"""Native Mac harness contracts without building or starting Apple processes."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

try:
    from script import automation_mac_e2e as driver
    from script.tests.test_automation_e2e import FakeCommands, prepared as simulator_prepared, report
except ModuleNotFoundError:
    spec = importlib.util.spec_from_file_location("automation_mac_e2e", Path(__file__).resolve().parents[1] / "automation_mac_e2e.py")
    driver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver)
    from test_automation_e2e import FakeCommands, prepared as simulator_prepared, report


def prepared():
    value = simulator_prepared()
    value["host"]["target"] = {"kind": "nativeMac", "id": "host-macos-local", "loginSession": "mac-gui-v1:501:123:0"}
    value["host"]["app"]["bundleID"] = driver.FIXTURE_BUNDLE_ID
    return value


class MacCommands(FakeCommands):
    def __init__(self, output):
        super().__init__(output)
        self.sequence = 0
        self.file_rejections = []

    def run(self, arguments, **options):
        args = [str(argument) for argument in arguments]
        if "run" in args and "--plan" in args:
            envelope = json.loads(Path(args[args.index("--plan") + 1]).read_text())
            if envelope["plan"]["id"] == "phase5.codec-file":
                super().run(arguments, **options)
                self.sequence += 1
                self.file_rejections.append(envelope)
                (self.output / f"{self.sequence:02d}-{Path(args[0]).name}.stderr.log").write_text(
                    json.dumps({"error": driver.FILE_REJECTION}))
                return 1, ""
        return super().run(arguments, **options)

    def json(self, arguments, **options):
        args = [str(argument) for argument in arguments]
        if "prepare" in args:
            super().json(arguments, **options)
            return 0, prepared()
        return super().json(arguments, **options)


class MacPlanTests(unittest.TestCase):
    def test_comparison_uses_fresh_names_initial_state_and_exact_entity_id_readback(self):
        plan = driver.fresh_comparison_case(prepared())
        create, lookup = plan["setup"]
        self.assertEqual(create["attemptTextBindings"], {"approvedText": "Phase5Compare"})
        self.assertEqual(create["uiProgram"]["operations"][0]["binding"], "approvedText")
        self.assertNotIn("steps", create["uiProgram"])
        save = next(operation for operation in create["uiProgram"]["operations"] if operation["id"] == "save")
        self.assertEqual(save["locator"], {"kind": "testId", "value": "task.add"})
        for operation in create["uiProgram"]["operations"]:
            locator = operation.get("locator", {})
            if "role" in locator:
                self.assertEqual((operation["kind"], locator["kind"]), ("tap", "label"))
        self.assertEqual(lookup["hostProgram"]["operations"][0]["attemptQueryPrefix"], "Phase5Compare")
        self.assertEqual(lookup["effects"], ["observe"])
        self.assertFalse(plan["setupChecks"][0]["expected"]["value"])
        self.assertTrue(plan["requirements"][0]["expected"]["value"])
        selection = plan["setupChecks"][0]["entityProperty"]["selection"]
        self.assertEqual(selection["attemptProperties"], {"title": "Phase5Compare"})
        self.assertEqual(plan["execution"]["inputBindings"][0]["uniqueEntity"], selection)
        self.assertEqual(plan["observations"][0]["inputBindings"][0]["destination"], "hostQueryIDs")

    def test_mac_plan_uses_captured_gui_session_and_keeps_same_mixed_checks(self):
        source = driver.shared.mixed_case(prepared(), "mixed")
        original = copy.deepcopy(source)
        plan = driver.mac_plan(prepared(), source)
        self.assertEqual(plan["id"], "phase5.mixed")
        self.assertEqual(plan["environmentID"], "selected-mac-session:mac-gui-v1:501:123:0")
        self.assertEqual(plan["requirements"], original["requirements"])
        self.assertEqual(plan["setup"], original["setup"])
        self.assertNotIn("capabilities", plan)

    def test_missing_or_foreign_session_cannot_be_substituted(self):
        for target in ({"kind": "simulator", "id": "host-macos-local", "loginSession": "session"},
                       {"kind": "nativeMac", "id": "another-mac", "loginSession": "session"},
                       {"kind": "nativeMac", "id": "host-macos-local"},
                       {"kind": "nativeMac", "id": "host-macos-local", "loginSession": "bad\nsession"}):
            value = prepared()
            value["host"]["target"] = target
            with self.subTest(target=target), self.assertRaises(AssertionError):
                driver.mac_plan(value, {"id": "phase3.mixed"})

    def test_output_and_cache_paths_cannot_resolve_inside_repository(self):
        with self.assertRaises(AssertionError):
            driver.outside_repository(driver.ROOT / "verification", "Artifacts")


class MacExecutionTests(unittest.TestCase):
    def exercise(self, include_comparison=False, **kwargs):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        output = Path(directory.name)
        commands = MacCommands(output)
        reports = []
        with patch.object(driver.shutil, "copytree"):
            driver.run_contract(commands, output, reports=reports, include_comparison=include_comparison, **kwargs)
        return output, commands, reports

    def test_full_native_contract_reuses_cli_and_proves_cleanup_after_failed_assertion(self):
        output, commands, reports = self.exercise(cli=Path("/external/intents-automation"))
        driver.verify_selection(reports)
        self.assertEqual([report["summary"] for report in reports], list(driver.EXPECTED_CASES.values()))
        self.assertEqual(len(commands.envelopes), 5)
        self.assertTrue(all(not envelope["allowBootAndInstall"] for envelope in commands.envelopes))
        self.assertTrue(all(envelope["disposable"] for envelope in commands.envelopes))
        self.assertTrue(all(envelope["plan"]["target"]["kind"] == "nativeMac" for envelope in commands.envelopes))
        calls = [args for args, _ in commands.calls]
        self.assertFalse(any("simctl" in args or "build" in args for args in calls))
        prepare = next(args for args in calls if "prepare" in args)
        self.assertEqual(prepare[prepare.index("--destination") + 1], "mac")
        self.assertEqual(prepare[prepare.index("--scheme") + 1], "AutomationFixtureMac")
        self.assertEqual(commands.envelopes[-2]["plan"]["requirements"][0]["expected"]["value"], False)
        self.assertTrue(reports[-1]["exactOutputsCompared"])
        self.assertEqual({family for report in reports for family in report["codecFamiliesCompared"]},
                         set(driver.shared.FAMILIES) - {"intentFile"})
        self.assertEqual(json.loads((output / "verified-cases.json").read_text()), reports)
        self.assertEqual(len(list(output.glob("*.report.json"))), 5)

    def test_each_codec_attempt_approves_launch_before_host_operations(self):
        _, commands, _ = self.exercise(cli=Path("/external/cli"))
        for envelope in (commands.envelopes[0], commands.envelopes[1], commands.envelopes[-1]):
            plan = envelope["plan"]
            self.assertEqual(len(plan["setup"]), 1)
            launch = plan["setup"][0]
            self.assertEqual((launch["kind"], launch["phase"]), ("ui", "setup"))
            self.assertEqual(launch["effects"], ["observe", "navigate"])
            self.assertEqual([step["kind"] for step in launch["uiProgram"]["steps"]], ["launch"])
            self.assertEqual(plan["budget"]["subjectOperations"], 20)
            self.assertEqual(plan["budget"]["uiActions"], 100)
            self.assertTrue(plan["execution"]["hostProgram"]["operations"])

    def test_supported_contract_retains_file_rejection_and_reaches_source_comparison(self):
        rejections = []
        with patch.object(driver, "run_source_comparison", return_value={"outcome": "fixed"}) as comparison:
            output, commands, reports = self.exercise(cli=Path("/external/cli"), include_comparison=True,
                                                     unsupported_checks=rejections)
        comparison.assert_called_once()
        self.assertEqual(len(commands.file_rejections), 1)
        self.assertEqual(commands.file_rejections[0]["plan"]["execution"]["inputBindings"][0]["parameterCodec"], "intentFile")
        self.assertEqual(rejections[0]["outcome"], "rejectedUnsupported")
        self.assertFalse(rejections[0]["subjectDispatched"])
        self.assertTrue(rejections[0]["resourcesReleased"])
        self.assertEqual(json.loads((output / "unsupported-codec-check.json").read_text()), rejections[0])
        self.assertTrue(all("intentFile" not in item["codecFamiliesCompared"] for item in reports))
        for envelope in commands.envelopes:
            plan = envelope["plan"]
            for segment in plan["setup"] + [plan["execution"]] + plan["observations"] + plan["cleanup"]:
                self.assertNotIn("apple.codec.intentFile", segment["requiredCapabilities"])

    def test_build_defaults_to_two_jobs_and_selected_xcode(self):
        _, commands, _ = self.exercise()
        build = next(args for args, _ in commands.calls if "--product" in args)
        self.assertEqual(build[build.index("--jobs") + 1], "2")
        prepare = next(args for args, _ in commands.calls if "prepare" in args)
        self.assertEqual(prepare[prepare.index("--xcode") + 1], commands.env["DEVELOPER_DIR"])

    def test_no_pass_when_saved_report_is_changed_or_resource_release_is_missing(self):
        for mutation in ("saved", "release", "outputs"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                output = Path(directory)
                commands = MacCommands(output)
                original = commands.json

                def corrupted(arguments, **options):
                    code, result = original(arguments, **options)
                    if (mutation == "saved" and "show" in arguments) or (mutation != "saved" and "run" in arguments):
                        result = copy.deepcopy(result)
                        if mutation == "outputs":
                            result["receipts"][0]["verifiedOutputs"]["integer"]["value"] = "0"
                        else:
                            result["resourcesReleased"] = False
                    return code, result

                commands.json = corrupted
                reports = []
                with patch.object(driver.shutil, "copytree"), self.assertRaises(AssertionError):
                    driver.run_contract(commands, output, cli=Path("/external/cli"), reports=reports, include_comparison=False)
                self.assertEqual(reports, [])

    def test_selection_requires_every_supported_case(self):
        _, _, reports = self.exercise(cli=Path("/external/cli"))
        for index in range(len(reports)):
            with self.subTest(index=index), self.assertRaises(AssertionError):
                driver.verify_selection(reports[:index] + reports[index + 1:])

    def test_selection_requires_exact_comparisons_and_supported_codec_coverage(self):
        _, _, reports = self.exercise(cli=Path("/external/cli"))
        for mutation in ("uncompared", "missing-codec", "unsupported-file"):
            changed = copy.deepcopy(reports)
            if mutation == "uncompared":
                changed[-1]["exactOutputsCompared"] = False
            elif mutation == "missing-codec":
                for item in changed:
                    item["codecFamiliesCompared"] = [family for family in item["codecFamiliesCompared"] if family != "integer"]
            else:
                changed[0]["codecFamiliesCompared"].append("intentFile")
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError):
                driver.verify_selection(changed)


class FileRejectionTests(unittest.TestCase):
    def test_file_rejection_requires_exact_error_no_dispatch_and_released_campaign(self):
        for mutation in (None, "error", "exit", "stdout", "created-root", "report", "xcuitest", "journal", "campaign"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                output = Path(directory)
                support = output / "support"
                support.mkdir()
                (support / "target-leases.json").write_text(json.dumps({"campaigns": {}}))
                commands = MacCommands(output)
                original = commands.run

                def reject(arguments, **options):
                    self.assertEqual(options["allowed"], (1,))
                    code, stdout = original(arguments, **options)
                    root = support / commands.file_rejections[0]["attemptID"]
                    if mutation in ("created-root", "report", "xcuitest", "journal"):
                        root.mkdir()
                    if mutation == "error":
                        (output / "01-cli.stderr.log").write_text(json.dumps({"error": "another rejection"}))
                    elif mutation == "exit":
                        code = 0
                    elif mutation == "stdout":
                        stdout = '{"receipts": []}'
                    elif mutation == "report":
                        (root / "report.json").write_text('{"receipts": []}')
                    elif mutation == "xcuitest":
                        (root / "xcuitest").mkdir()
                    elif mutation == "journal":
                        (root / "journal.json").write_text('{"dispatch": {"state": "dispatched"}}')
                    elif mutation == "campaign":
                        (support / "target-leases.json").write_text('{"campaigns": {"mac": {}}}')
                    return code, stdout

                commands.run = reject
                if mutation:
                    with self.assertRaises(AssertionError):
                        driver.verify_file_rejection(commands, Path("/external/cli"), support, output, prepared())
                else:
                    result = driver.verify_file_rejection(commands, Path("/external/cli"), support, output, prepared())
                    self.assertEqual(result["error"], driver.FILE_REJECTION)


class SourceComparisonTests(unittest.TestCase):
    def stage(self, output):
        source = output / "AutomationFixture/Models/TaskDiskStore.swift"
        source.parent.mkdir(parents=True)
        source.write_text((driver.ROOT / "examples/AutomationFixture/Models/TaskDiskStore.swift").read_text())
        return source

    def comparison(self):
        baseline, candidate = prepared(), prepared()
        baseline["host"]["app"]["productDigest"] = "broken-digest"
        candidate["host"]["app"]["productDigest"] = "fixed-digest"
        baseline["host"]["app"]["sourceManifestDigest"] = "broken-source"
        candidate["host"]["app"]["sourceManifestDigest"] = "fixed-source"
        before, after = [], []
        for index in range(3):
            for population, summary, prefix in ((before, "assertionFailed", "before"), (after, "passed", "after")):
                item = report(summary)
                item["attemptID"] = prefix + str(index)
                population.append(item)
        frozen = lambda value: {"contractDigest": "same-contract", "oracleDigest": "same-oracle", "plan": {"app": value["host"]["app"]}}
        return {"outcome": "fixed", "originalAttemptID": "seed", "report": {
            "requestedAttemptsPerBuild": 3, "before": before, "after": after,
            "baseline": frozen(baseline), "candidate": frozen(candidate)}}, candidate, baseline

    def test_comparison_requires_three_failures_then_three_passes_and_changed_product(self):
        value, candidate, baseline = self.comparison()
        driver.verify_comparison(value, "seed", candidate, baseline)
        for mutation in ("missing", "same-product", "same-source", "changed-check", "after-failed", "reused-id", "unreleased", "not-fixed"):
            result, good, broken = self.comparison()
            if mutation == "missing":
                result["report"]["before"].pop()
            elif mutation == "same-product":
                broken["host"]["app"]["productDigest"] = good["host"]["app"]["productDigest"]
            elif mutation == "changed-check":
                result["report"]["candidate"]["oracleDigest"] = "changed"
            elif mutation == "same-source":
                broken["host"]["app"]["sourceManifestDigest"] = good["host"]["app"]["sourceManifestDigest"]
            elif mutation == "after-failed":
                result["report"]["after"][0]["result"]["summary"] = "assertionFailed"
            elif mutation == "reused-id":
                result["report"]["after"][0]["attemptID"] = "before0"
            elif mutation == "unreleased":
                result["report"]["before"][0]["resourcesReleased"] = False
            else:
                result["outcome"] = "notFixed"
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError):
                driver.verify_comparison(result, "seed", good, broken)

    def test_source_versions_share_project_path_and_are_restored_before_fixed_prepare(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            source = self.stage(output)
            original = source.read_text()
            result, candidate, baseline = self.comparison()
            commands = Mock()
            prepared_sources = []

            def reply(arguments, **options):
                if "prepare" in arguments:
                    prepared_sources.append(source.read_text())
                    return 0, baseline if len(prepared_sources) == 1 else candidate
                return 0, result

            commands.json.side_effect = reply
            with patch.object(driver.shared, "run_plan", return_value=("seed", 1, report("assertionFailed"))), \
                    patch.object(driver.shared, "verify_campaigns") as leases:
                summary = driver.run_source_comparison(commands, Path("/external/cli"), output, output / "support", candidate, Path("/Xcode"))
            self.assertEqual(source.read_text(), original)
            self.assertIn("document.records[affected].completed = false", prepared_sources[0])
            self.assertEqual(prepared_sources[1], original)
            calls = [call.args[0] for call in commands.json.call_args_list]
            self.assertEqual(calls[0][calls[0].index("--project") + 1], calls[1][calls[1].index("--project") + 1])
            self.assertEqual(calls[2][calls[2].index("--attempts") + 1], "3")
            self.assertEqual(summary["outcome"], "fixed")
            self.assertEqual(leases.call_count, 3)

    def test_prepare_failure_restores_only_the_disposable_source(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            source = self.stage(output)
            original = source.read_text()
            commands = Mock()
            commands.json.side_effect = RuntimeError("injected failed preparation")
            with self.assertRaisesRegex(RuntimeError, "injected"):
                driver.run_source_comparison(commands, Path("/external/cli"), output, output / "support", prepared(), Path("/Xcode"))
            self.assertEqual(source.read_text(), original)


if __name__ == "__main__":
    unittest.main()
