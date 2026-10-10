import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("duplicate_tasks_profile.py")


class DuplicateTasksProfileTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.prepared = self.root / "prepared.json"
        self.data = {"host": {"app": {"bundleID": "com.coryparry.IntentsAutomation.DuplicateTasks", "platform": "ios"},
                              "target": {"kind": "simulator", "id": "09D3C36B-7A4C-406A-91E5-0A99A429F7D3"}, "xctestrunDigest": "a" * 64},
                     "catalog": {"systemActions": [{"id": "CompleteTaskIntent", "compiled": True}]}}
        self.prepared.write_text(json.dumps(self.data))

    def generate(self, mode="correct", extra=()):
        output = self.root / (mode + ".json")
        result = subprocess.run([sys.executable, str(SCRIPT), "--prepared", str(self.prepared), "--support-root", str(self.root / "campaign"),
                                 "--runtime-app", str(self.root / "Runtime.app"), "--runtime-team-id", "3Z3955EFRE",
                                 "--attempt-id", "test-attempt", "--mode", mode, "--output", str(output), *extra], capture_output=True, text=True)
        return result, output

    def testEverySelectedControlIncludingCorrectIsEstablishedExplicitly(self):
        observations = []
        for mode, label in [("correct", "Correct"), ("wrong-record", "Wrong record"), ("missing-save", "Missing save")]:
            result, output = self.generate(mode)
            self.assertEqual(result.returncode, 0, result.stderr)
            plan = json.loads(output.read_text())["plan"]
            selected = next(op for op in plan["setup"][0]["uiProgram"]["operations"] if op["id"] == "choose-control")
            self.assertEqual(selected["locator"]["value"], label)
            self.assertEqual(selected["locator"]["role"], "button")
            self.assertEqual(plan["revision"], 3)
            self.assertEqual(plan["execution"]["hostProgram"]["operations"][0]["parameters"], {})
            observations.append((plan["observations"], plan["requirements"]))
        self.assertTrue(all(observer == observations[0] for observer in observations))

    def testIntermittentContinuationKeepsCounterAndVerifiesRealControl(self):
        result, output = self.generate("intermittent", ["--keep-control"])
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(output.read_text())["plan"]
        self.assertTrue(plan["id"].endswith(".continuation"))
        self.assertEqual(plan["setup"][0]["uiProgram"]["operations"][0]["id"], "reset")
        self.assertFalse(any(op["id"] == "choose-control" for op in plan["setup"][0]["uiProgram"]["operations"]))
        self.assertEqual(next(c for c in plan["setupChecks"] if c["checkID"] == "fixture.control")["expected"]["value"], "intermittent")

    def testForeignTargetMissingIntentAndOldRevisionProduceNoProfile(self):
        for flag in range(4):
            data = json.loads(json.dumps(self.data))
            extra = []
            if flag == 0: data["host"]["target"]["kind"] = "physicalDevice"
            elif flag == 1: data["catalog"]["systemActions"] = []
            elif flag == 2: extra = ["--revision", "2"]
            else: extra = ["--keep-control"]
            self.prepared.write_text(json.dumps(data))
            result, output = self.generate(extra=extra)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def testExistingProfileCannotBeOverwritten(self):
        output = self.root / "correct.json"
        output.write_text("retained approval")
        result, _ = self.generate()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output.read_text(), "retained approval")


if __name__ == "__main__":
    unittest.main()
