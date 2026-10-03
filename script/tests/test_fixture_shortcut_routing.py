"""Compile and execute fixture preset routing with real AppIntents, without a device."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "examples" / "IntentLabFixture"


@unittest.skipUnless(sys.platform == "darwin", "Requires Apple's AppIntents SDK")
class FixtureShortcutRoutingTests(unittest.TestCase):
    def test_preset_routes_forward_results_and_errors_to_the_correct_production_intent(self):
        with tempfile.TemporaryDirectory(prefix="intent-lab-shortcut-routing-") as directory:
            package = Path(directory)
            shutil.copytree(ROOT / "Sources" / "IntentLabContracts", package / "Contracts")
            source = package / "Routing"
            source.mkdir()
            for name in ("NoteIntents.swift", "FixtureNotes.swift"):
                shutil.copyfile(FIXTURE / "Sources" / name, source / name)
            shutil.copyfile(FIXTURE / "ShortcutRoutingTests" / "Support.swift", source / "Support.swift")
            tests = package / "Tests"
            tests.mkdir()
            shutil.copyfile(FIXTURE / "ShortcutRoutingTests" / "ShortcutRoutingTests.swift", tests / "ShortcutRoutingTests.swift")
            (package / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "FixtureShortcutRoutingVerification",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IntentLabContracts", path: "Contracts"),
        .target(name: "FixtureShortcutRouting", dependencies: ["IntentLabContracts"], path: "Routing"),
        .testTarget(name: "FixtureShortcutRoutingTests", dependencies: ["FixtureShortcutRouting"], path: "Tests")
    ]
)
''')
            result = subprocess.run(
                ["swift", "test", "--disable-sandbox", "--package-path", str(package), "-j", "2"],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180,
            )
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn("3 tests", result.stdout, result.stdout)


if __name__ == "__main__":
    unittest.main()
