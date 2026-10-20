import contextlib
import copy
import io
import itertools
import json
import unittest

from script import ci_gate


def selection(**overrides):
    values = {key: "false" for key in ci_gate.FLAGS}
    values.update({key: "[]" for key in ci_gate.ARRAYS})
    values.update(overrides)
    return values


def results(selected, stability="false"):
    return {key: {"result": outcome} for key, outcome in {
        "changes": "success", "swift-tests": "success",
        "native-build": "success" if selected["native"] == "true" else "skipped",
        "ui-tests": "success" if selected["ui"] == "true" else "skipped",
        "picker-stability": "success" if selected["ui"] == "true" and stability == "true" else "skipped",
        "automation-e2e-scenarios": "success" if selected["automation_e2e"] == "true" else "skipped",
    }.items()}


class GateTests(unittest.TestCase):
    def test_selected_coverage_shapes_accept_the_real_workers(self):
        cases = {
            "docs-only-ubuntu-noop": selection(),
            "portable-only-skipped-native-ancestry": selection(regression="true", swift_suites='["PortableTests"]'),
            "sdk-only": selection(regression="true", sdk_consumer="true"),
            "input-only": selection(regression="true", input_conversion="true"),
            "macos-only": selection(regression="true", macos_tests='["MacTests"]'),
            "native-build-only": selection(native="true"),
            "native-core-only": selection(native="true", regression="true", native_tests='["CoreTests"]'),
            "automation-only": selection(automation_e2e="true"),
            "full": selection(**{key: "true" for key in ci_gate.FLAGS},
                              **{key: '["SelectedTests"]' for key in ci_gate.ARRAYS}),
        }
        for name, selected in cases.items():
            for stability in ("true", "false"):
                with self.subTest(name=name, stability=stability):
                    self.assertEqual(ci_gate.evaluate(results(selected, stability), selected, stability), [])

    def test_every_worker_must_match_selected_or_unselected_outcome(self):
        for all_selected, stability in itertools.product((False, True), ("false", "true")):
            selected = selection(**{key: "true" for key in ci_gate.FLAGS},
                                 native_tests='["CoreTests"]') if all_selected else selection()
            baseline = results(selected, stability)
            for worker in ci_gate.WORKERS:
                for result in ("success", "failure", "cancelled", "skipped", "pending", "", None):
                    with self.subTest(selected=all_selected, stability=stability, worker=worker, result=result):
                        changed = copy.deepcopy(baseline)
                        changed[worker]["result"] = result
                        errors = ci_gate.evaluate(changed, selected, stability)
                        self.assertEqual(bool(errors), result != baseline[worker]["result"])
                        if errors:
                            self.assertTrue(any(worker in error for error in errors))

    def test_missing_or_malformed_worker_evidence_fails_closed(self):
        selected = selection()
        for worker in ci_gate.WORKERS:
            for malformed in (None, {}, "success", {"result": []}):
                with self.subTest(worker=worker, malformed=malformed):
                    changed = results(selected)
                    changed[worker] = malformed
                    self.assertTrue(ci_gate.evaluate(changed, selected, "false"))
            changed = results(selected)
            del changed[worker]
            self.assertTrue(ci_gate.evaluate(changed, selected, "false"))
        for needs in (None, [], "success"):
            self.assertTrue(ci_gate.evaluate(needs, selected, "false"))

    def test_flags_and_stability_require_exact_boolean_strings(self):
        for flag in ci_gate.FLAGS:
            for invalid in (True, False, None, 0, "", "TRUE", " false ", [], {}):
                with self.subTest(flag=flag, invalid=invalid):
                    selected = selection(**{flag: invalid})
                    self.assertTrue(ci_gate.evaluate(results(selection()), selected, "false"))
            selected = selection()
            del selected[flag]
            self.assertTrue(ci_gate.evaluate(results(selection()), selected, "false"))
        for invalid in (True, False, None, "", "TRUE", " false "):
            self.assertTrue(ci_gate.evaluate(results(selection()), selection(), invalid))

    def test_arrays_require_json_lists_of_nonempty_strings(self):
        for key in ci_gate.ARRAYS:
            for invalid in (None, [], b"[]", "", "null", "{}", '"Tests"', "true", '[1]', '[null]', '[""]', '["  "]', '[[]]', '["Tests", false]', "[" * 2000 + "]" * 2000):
                with self.subTest(key=key, invalid=invalid):
                    self.assertTrue(ci_gate.evaluate(results(selection()), selection(**{key: invalid}), "false"))
            selected = selection()
            del selected[key]
            self.assertTrue(ci_gate.evaluate(results(selection()), selected, "false"))
        for invalid in (None, [], "{}"):
            self.assertTrue(ci_gate.evaluate(results(selection()), invalid, "false"))

    def test_regression_flag_agrees_with_every_mac_selection_permutation(self):
        for swift, macos, core, sdk, inputs in itertools.product((False, True), repeat=5):
            selected = selection(native="true" if core else "false",
                                 swift_suites='["SwiftTests"]' if swift else "[]",
                                 macos_tests='["MacTests"]' if macos else "[]",
                                 native_tests='["CoreTests"]' if core else "[]",
                                 sdk_consumer=str(sdk).lower(), input_conversion=str(inputs).lower())
            expected = any((swift, macos, core, sdk, inputs))
            for regression in (False, True):
                with self.subTest(swift=swift, macos=macos, core=core, sdk=sdk, inputs=inputs, regression=regression):
                    selected["regression"] = str(regression).lower()
                    self.assertEqual(bool(ci_gate.evaluate(results(selected), selected, "false")), regression != expected)

    def test_ui_and_core_cannot_succeed_without_native_build_selection(self):
        for selected in (selection(ui="true"), selection(regression="true", native_tests='["CoreTests"]')):
            self.assertTrue(any("require selection native=true" in error
                                for error in ci_gate.evaluate(results(selected), selected, "false")))

    def test_cli_requires_bounded_json_and_prints_actionable_errors(self):
        selected = selection()
        env = {"CI_NEEDS_JSON": json.dumps(results(selected)), "CI_SELECTION_JSON": json.dumps(selected),
               "CI_STABILITY_REQUESTED": "false"}
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ci_gate.main(env), 0)
        for key in ("CI_NEEDS_JSON", "CI_SELECTION_JSON", "CI_STABILITY_REQUESTED"):
            for invalid in (None, [], "not-json", "null", "[]", "x" * (ci_gate.JSON_LIMIT + 1), "[" * 2000 + "]" * 2000):
                with self.subTest(key=key, invalid_type=type(invalid).__name__):
                    changed = dict(env)
                    if invalid is None:
                        del changed[key]
                    else:
                        changed[key] = invalid
                    errors = io.StringIO()
                    with contextlib.redirect_stderr(errors):
                        self.assertEqual(ci_gate.main(changed), 1)
                    self.assertIn("CI gate error:", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
