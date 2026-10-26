"""Keep canonical app/plugin source membership and both CI consumers aligned."""

import json
import hashlib
from pathlib import Path
import re
import unittest

from script import ci_routes as routes

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "FoundationEvals/FoundationEvals.xcodeproj/project.pbxproj"
MAPPING = json.loads((ROOT / "script/shared_app_sources.json").read_text())


class SharedAppSourcesTests(unittest.TestCase):
    """Verify the shared set without depending on an Xcode installation."""

    def test_catalog_contains_regular_canonical_sources_without_app_copies(self):
        """Keep each of the 24 sources inside the independently packaged plugin."""
        self.assertEqual(len(MAPPING), 24)
        self.assertEqual(len(set(MAPPING.values())), len(MAPPING))
        self.assertEqual(routes.SHARED_APP_SOURCES, MAPPING)
        for canonical, former in MAPPING.items():
            with self.subTest(canonical=canonical):
                self.assertTrue(canonical.startswith("plugins/apple-foundation-evals/native/AppEngine/"))
                self.assertTrue(former.startswith(routes.APP))
                self.assertEqual(Path(canonical).name, Path(former).name)
                self.assertTrue((ROOT / canonical).is_file())
                self.assertFalse((ROOT / canonical).is_symlink())
                self.assertFalse((ROOT / former).exists())
                self.assertFalse((ROOT / former).is_symlink())

    def test_provenance_tracks_current_shared_sources_and_historical_origins(self):
        """Verify current canonical hashes while keeping former hashes explicitly historical."""
        manifest = json.loads((ROOT / "plugins/apple-foundation-evals/native/AppEngine/provenance.json").read_text())
        shared = [entry for entry in manifest["files"] if "canonicalSource" in entry]
        self.assertEqual(len(shared), len(MAPPING))
        self.assertEqual({entry["canonicalSource"] for entry in shared}, set(MAPPING))
        for entry in shared:
            canonical = entry["canonicalSource"]
            with self.subTest(canonical=canonical):
                self.assertEqual(entry["formerSource"], MAPPING[canonical])
                self.assertEqual(entry["bundled"], Path(canonical).name)
                digest = hashlib.sha256((ROOT / canonical).read_bytes()).hexdigest()
                self.assertEqual(entry["canonicalSHA256"], digest)
                self.assertEqual(entry["bundledSHA256"], digest)
                self.assertRegex(entry["formerSourceSHA256"], r"^[0-9a-f]{64}$")
                self.assertNotIn("source", entry)
                self.assertNotIn("sha256", entry)

    def test_project_compiles_exact_catalog_once_into_app_only(self):
        """Check references, group membership, and the owning target's Sources phase."""
        project = PROJECT.read_text()
        group = re.search(r"([A-F0-9]{24}) /\* SharedAppEngine \*/ = \{(.*?)\n\t\t\};", project, re.S)
        self.assertIsNotNone(group)
        self.assertIn('path = "../plugins/apple-foundation-evals/native/AppEngine";', group[2])
        self.assertIn('sourceTree = "<group>";', group[2])
        group_files = re.findall(r"([A-F0-9]{24}) /\* (\w+\.swift) \*/,", group[2])
        self.assertEqual({name for _, name in group_files}, {Path(path).name for path in MAPPING})
        self.assertEqual(len(group_files), len(MAPPING))
        root_group = re.search(r"AFC28B3D304733160023273E = \{(.*?)\n\t\t\};", project, re.S)[1]
        self.assertEqual(root_group.count(group[1]), 1)
        phases = dict(re.findall(
            r"([A-F0-9]{24}) /\* Sources \*/ = \{\s*isa = PBXSourcesBuildPhase;(.*?)\n\t\t\};",
            project, re.S,
        ))
        for file_id, name in group_files:
            with self.subTest(name=name):
                reference = f'{file_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};'
                self.assertEqual(project.count(reference), 1)
                builds = re.findall(
                    rf"([A-F0-9]{{24}}) /\* {re.escape(name)} in Sources \*/ = \{{isa = PBXBuildFile; fileRef = {file_id} /\* {re.escape(name)} \*/; \}};",
                    project,
                )
                self.assertEqual(len(builds), 1)
                self.assertEqual(phases["AFC28B42304733170023273E"].count(builds[0]), 1)
                self.assertEqual(sum(body.count(builds[0]) for body in phases.values()), 1)

    def test_shared_sources_retain_app_test_ownership_and_integrity_checks(self):
        """Route each canonical change exactly like its former app source plus membership checks."""
        for canonical, former in MAPPING.items():
            with self.subTest(canonical=canonical):
                actual = routes.coverage([canonical])
                expected = routes.coverage([former])
                for key in ("native", "native_tests", "ui", "ui_matrix", "swift_suites", "macos_tests", "sdk_consumer"):
                    self.assertEqual(actual[key], expected[key], key)
                self.assertTrue(actual["native"])
                self.assertEqual(actual["native_tests"], ["FoundationEvalsTests"])
                self.assertEqual(actual["swift_suites"], [])
                self.assertIn("script.tests.test_shared_app_sources", actual["python_tests"])
                mixed = routes.coverage([canonical, former, canonical])
                self.assertEqual(actual, mixed)

    def test_mapping_and_project_edits_check_all_source_membership(self):
        """Require conservative app coverage when the catalog or Xcode wiring changes."""
        for path in ("script/shared_app_sources.json", str(PROJECT.relative_to(ROOT))):
            with self.subTest(path=path):
                plan = routes.coverage([path])
                self.assertTrue(plan["native"])
                self.assertEqual(plan["native_tests"], ["FoundationEvalsTests"])
                self.assertIn("script.tests.test_shared_app_sources", plan["python_tests"])

    def test_portable_package_keeps_its_macos26_sources_separate(self):
        """Keep the three deterministic portable counterparts outside the shared set."""
        package = (ROOT / "Package.swift").read_text()
        portable = re.search(r"let portableProductionSources = \[(.*?)\]", package, re.S)[1]
        paths = {routes.APP + path for path in re.findall(r'"([^"]+\.swift)"', portable)}
        self.assertFalse(paths.intersection(MAPPING.values()))
        for relative in ("Models/EvaluationFieldAssertion.swift", "Models/EvaluationScoringTypes.swift",
                         "Services/EvaluationFieldAssertions.swift"):
            with self.subTest(relative=relative):
                self.assertIn(routes.APP + relative, paths)
                self.assertTrue((ROOT / routes.APP / relative).is_file())
        self.assertIn("platforms: [.macOS(.v26)]", package)

    def test_standalone_workflow_still_builds_and_packages_shared_sources(self):
        """Keep canonical edits covered by the independent plugin CI and local build glob."""
        workflow = (ROOT / ".github/workflows/plugin.yml").read_text()
        self.assertEqual(workflow.count("- 'plugins/apple-foundation-evals/**'"), 2)
        self.assertIn("npm run test:native", workflow)
        self.assertIn("node scripts/package.mjs", workflow)
        build = (ROOT / "plugins/apple-foundation-evals/native/build.sh").read_text()
        self.assertIn('"$native_dir"/AppEngine/*.swift', build)
        self.assertNotIn("FoundationEvals/FoundationEvals", build)


if __name__ == "__main__":
    unittest.main()
