"""Stage the source fixture and opt the selected Mac UI shard into real execution."""

import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess

try:
    from ci_ui_xctestrun import prepare_ui_xctestrun, ui_targets
except ModuleNotFoundError:
    from script.ci_ui_xctestrun import prepare_ui_xctestrun, ui_targets

ROOT = Path(__file__).resolve().parents[1]
FIXTURE_ROOT = Path("/private/tmp/foundation-evals-ui-tests/AutomationFixture")


def prepare_mac_fixture(products, developer_directory, fixture_root=FIXTURE_ROOT, repository=ROOT):
    developer_directory = Path(developer_directory).resolve(strict=True)
    if not developer_directory.is_dir():
        raise ValueError("Selected developer directory must be a directory")
    descriptor = prepare_ui_xctestrun(Path(products))
    document = plistlib.loads(descriptor.read_bytes())
    targets = ui_targets(document)
    for target in targets:
        environment = target.get("EnvironmentVariables", {})
        if not isinstance(environment, dict):
            raise ValueError("UI target environment must be a dictionary")
        target["EnvironmentVariables"] = {
            **environment,
            "INTENTS_AUTOMATION_LIVE_UI": "1",
            "INTENTS_AUTOMATION_DEVELOPER_DIR": str(developer_directory),
        }
    fixture_root = Path(fixture_root)
    if fixture_root.is_symlink():
        raise ValueError("Shared automation fixture must not be a symlink")
    fixture_root.parent.mkdir(parents=True, exist_ok=True)
    if fixture_root.exists():
        shutil.rmtree(fixture_root)
    shutil.copytree(Path(repository) / "examples/AutomationFixture", fixture_root,
                    ignore=shutil.ignore_patterns(".build", "*.xcodeproj"))
    subprocess.run(["xcodegen", "generate", "--spec", str(fixture_root / "project.yml")],
                   cwd=fixture_root, check=True, timeout=60)
    project = fixture_root / "AutomationFixture.xcodeproj/project.pbxproj"
    if not project.is_file():
        raise ValueError("Fixture project generation did not produce project.pbxproj")
    descriptor.write_bytes(plistlib.dumps(document, sort_keys=False))
    return descriptor


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products", required=True, type=Path)
    parser.add_argument("--developer-directory", required=True, type=Path)
    arguments = parser.parse_args()
    print(prepare_mac_fixture(arguments.products, arguments.developer_directory))


if __name__ == "__main__":
    main()
