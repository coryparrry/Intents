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


SIGNING = {"teamID": "ABCDE12345", "identitySHA1": "A" * 40}


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


class SigningTests(unittest.TestCase):
    def test_only_explicit_team_and_certificate_fingerprint_are_accepted(self):
        self.assertEqual(driver.signing_inputs(SIGNING["teamID"], "a" * 40), SIGNING)
        for team, identity in ((None, None), (SIGNING["teamID"], None), (None, "A" * 40),
                               ("TEAM", "A" * 40), ("ABCDE12345\n", "A" * 40),
                               (SIGNING["teamID"], "-"), (SIGNING["teamID"], "Apple Development: Name")):
            with self.subTest(team=team, identity=identity), self.assertRaises(AssertionError):
                driver.signing_inputs(team, identity)

    def test_signing_is_applied_only_to_staged_mac_target(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            original = (driver.ROOT / "examples/AutomationFixture/project.yml").read_text()
            spec = fixture / "project.yml"
            spec.write_text(original)
            driver.configure_fixture_signing(fixture, SIGNING)
            before, mac = spec.read_text().split("  AutomationFixtureMac:\n", 1)
            self.assertNotIn("DEVELOPMENT_TEAM", before)
            self.assertIn('DEVELOPMENT_TEAM: "ABCDE12345"', mac)
            self.assertIn('CODE_SIGN_IDENTITY: "' + "A" * 40 + '"', mac)
            self.assertIn('CODE_SIGN_STYLE: "Manual"', mac)
            self.assertEqual((driver.ROOT / "examples/AutomationFixture/project.yml").read_text(), original)
            with self.assertRaises(AssertionError):
                driver.configure_fixture_signing(driver.ROOT / "examples/AutomationFixture", SIGNING)

    def signature_case(self, mutation=None):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        output = Path(temporary.name) / "signing.json"
        value = prepared()
        value["host"].update(hostBundlePath="/prepared/Host.app", testTarget="HostTests")
        commands = Mock()
        role = 0

        def command(arguments, **options):
            nonlocal role
            if arguments[0] == "/bin/sh":
                role += 1
                raw = "Authority=Apple Development: Fixture (ABCDE12345)\nAuthority=Apple Root CA\nTeamIdentifier=ABCDE12345\n"
                if mutation == "adhoc" and role == 1:
                    raw = "Signature=adhoc\nTeamIdentifier=not set\n"
                if mutation == "team" and role == 2:
                    raw = raw.replace("TeamIdentifier=ABCDE12345", "TeamIdentifier=OTHER12345")
                if mutation == "release" and role == 1:
                    raw = raw.replace("Apple Development:", "Developer ID Application:")
                return 0, raw
            if arguments[0] == "/usr/bin/openssl":
                return 0, "SHA1 Fingerprint=" + ":".join(["BB" if mutation == "certificate" and role == 3 else "AA"] * 20) + "\n"
            if mutation == "verify" and role == 3:
                raise AssertionError("Signature verification failed")
            return 0, ""

        commands.run.side_effect = command
        return output, value, commands

    def test_actual_subject_runner_and_tests_must_share_requested_development_signature(self):
        output, value, commands = self.signature_case()
        evidence = driver.verify_prepared_signing(commands, value, output, SIGNING)
        self.assertTrue(evidence["verified"])
        self.assertEqual([product["role"] for product in evidence["products"]], ["subject", "runner", "tests"])
        self.assertTrue(all(product["identitySHA1"] == SIGNING["identitySHA1"] for product in evidence["products"]))
        self.assertEqual(json.loads(output.read_text()), evidence)
        verifies = [call.args[0] for call in commands.run.call_args_list if call.args[0][0] == "/usr/bin/codesign"]
        self.assertEqual(len(verifies), 3)
        self.assertTrue(all("anchor apple generic" in call[call.index("-R") + 1] for call in verifies))
        self.assertEqual(verifies[-1][-1], Path("/prepared/Host.app/Contents/PlugIns/HostTests.xctest"))

    def test_adhoc_wrong_team_release_certificate_mismatch_and_invalid_signature_fail(self):
        for mutation in ("adhoc", "team", "release", "certificate", "verify"):
            with self.subTest(mutation=mutation):
                output, value, commands = self.signature_case(mutation)
                with self.assertRaises(AssertionError):
                    driver.verify_prepared_signing(commands, value, output, SIGNING)
                self.assertNotIn("verified", json.loads(output.read_text()))

    def test_unconfigured_intent_acceptance_stops_before_commands_or_case_dispatch(self):
        commands = Mock()
        with tempfile.TemporaryDirectory() as directory, self.assertRaisesRegex(AssertionError, "signing-team"):
            driver.run_contract(commands, Path(directory), cli=Path("/external/cli"))
        commands.run.assert_not_called()
        commands.json.assert_not_called()


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
    def exercise(self, include_comparison=False, **kwargs):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        output = Path(directory.name)
        commands = MacCommands(output)
        reports = []
        with patch.object(driver.shutil, "copytree"), patch.object(driver, "configure_fixture_signing"), \
                patch.object(driver, "verify_prepared_signing"):
            driver.run_contract(commands, output, reports=reports, include_comparison=include_comparison, signing=SIGNING, **kwargs)
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
        self.assertEqual({family for report in reports for family in report["codecFamiliesCompared"]}, set(driver.shared.FAMILIES) - {"intentFile"})
        self.assertEqual(json.loads((output / "verified-cases.json").read_text()), reports)
        self.assertEqual(len(list(output.glob("*.report.json"))), 5)

    def test_supported_contract_never_dispatches_files_and_reaches_source_comparison(self):
        with patch.object(driver.shared, "file_case", side_effect=AssertionError("unsupported Mac file transfer")) as file_case, \
                patch.object(driver, "run_source_comparison", return_value={"outcome": "fixed"}) as comparison:
            _, commands, reports = self.exercise(cli=Path("/external/cli"), include_comparison=True)
        file_case.assert_not_called()
        comparison.assert_called_once()
        for envelope in commands.envelopes:
            plan = envelope["plan"]
            segments = plan["setup"] + [plan["execution"]] + plan["observations"] + plan["cleanup"]
            for segment in segments:
                self.assertNotIn("apple.codec.intentFile", segment["requiredCapabilities"])
                for operation in segment.get("hostProgram", {}).get("operations", []):
                    self.assertNotEqual(operation.get("resultCodec"), "intentFile")
                    self.assertNotIn("intentFile", operation.get("parameterCodecs", {}).values())
                for binding in segment.get("inputBindings", []):
                    self.assertNotEqual(binding.get("parameterCodec"), "intentFile")
        self.assertEqual([item["case"] for item in reports], [
            "phase5.codec-1", "phase5.codec-2", "phase5.mixed",
            "phase5.wrong-assertion", "phase5.after-wrong-assertion"])
        self.assertTrue(all("intentFile" not in item["codecFamiliesCompared"] for item in reports))

    def test_unsigned_prepared_product_cannot_reach_intent_dispatch(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            commands = MacCommands(output)
            with patch.object(driver.shutil, "copytree"), patch.object(driver, "configure_fixture_signing"), \
                    patch.object(driver, "verify_prepared_signing", side_effect=AssertionError("ad hoc signing")), \
                    self.assertRaisesRegex(AssertionError, "ad hoc signing"):
                driver.run_contract(commands, output, cli=Path("/external/cli"), signing=SIGNING)
            self.assertEqual(commands.envelopes, [])
            self.assertFalse(any("actions" in args or "run" in args for args, _ in commands.calls))

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
                with patch.object(driver.shutil, "copytree"), patch.object(driver, "configure_fixture_signing"), \
                        patch.object(driver, "verify_prepared_signing"), self.assertRaises(AssertionError):
                    driver.run_contract(commands, output, cli=Path("/external/cli"), reports=reports, include_comparison=False, signing=SIGNING)
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
                    patch.object(driver.shared, "verify_campaigns") as leases, \
                    patch.object(driver, "verify_prepared_signing") as signatures:
                summary = driver.run_source_comparison(commands, Path("/external/cli"), output, output / "support", candidate, Path("/Xcode"))
            self.assertEqual(source.read_text(), original)
            self.assertIn("document.records[affected].completed = false", prepared_sources[0])
            self.assertEqual(prepared_sources[1], original)
            calls = [call.args[0] for call in commands.json.call_args_list]
            self.assertEqual(calls[0][calls[0].index("--project") + 1], calls[1][calls[1].index("--project") + 1])
            self.assertEqual(calls[2][calls[2].index("--attempts") + 1], "3")
            self.assertEqual(summary["outcome"], "fixed")
            self.assertEqual(leases.call_count, 3)
            self.assertEqual(signatures.call_count, 2)

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
