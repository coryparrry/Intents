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
    def exercise(self, **kwargs):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        output = Path(directory.name)
        commands = MacCommands(output)
        reports = []
        with patch.object(driver.shutil, "copytree"):
            driver.run_contract(commands, output, reports=reports, include_comparison=False, **kwargs)
        return output, commands, reports

    def test_full_native_contract_reuses_cli_and_proves_cleanup_after_failed_assertion(self):
        output, commands, reports = self.exercise(cli=Path("/external/intents-automation"))
        driver.verify_selection(reports)
        self.assertEqual([report["summary"] for report in reports], list(driver.EXPECTED_CASES.values()))
        self.assertEqual(len(commands.envelopes), 6)
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
        self.assertEqual({family for report in reports for family in report["codecFamiliesCompared"]}, set(driver.shared.FAMILIES))
        self.assertEqual(json.loads((output / "verified-cases.json").read_text()), reports)
        self.assertEqual(len(list(output.glob("*.report.json"))), 6)

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

    def test_selection_rejects_missing_negative_or_followup_case(self):
        _, _, reports = self.exercise(cli=Path("/external/cli"))
        for index in (4, 5):
            with self.subTest(index=index), self.assertRaises(AssertionError):
                driver.verify_selection(reports[:index] + reports[index + 1:])


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
