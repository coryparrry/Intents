"""Select the built UI descriptor and repair Xcode's known executable-path alias."""

import plistlib
import sys
from pathlib import Path


def ui_targets(document: dict) -> list[dict]:
    metadata = document.get("__xctestrun_metadata__", {"FormatVersion": 1})
    if not isinstance(metadata, dict) or type(metadata.get("FormatVersion")) is not int or metadata["FormatVersion"] not in (1, 2):
        raise ValueError("Unsupported or malformed xctestrun format version")
    version = metadata["FormatVersion"]
    if version == 1:
        if "TestConfigurations" in document:
            raise ValueError("Version 1 descriptor cannot contain TestConfigurations")
        targets = [document.get("FoundationEvalsUITests")]
    else:
        if "FoundationEvalsUITests" in document:
            raise ValueError("Version 2 descriptor cannot contain a flat UI target")
        configurations = document.get("TestConfigurations")
        if not isinstance(configurations, list) or not configurations:
            raise ValueError("Version 2 descriptor requires TestConfigurations")
        targets, names = [], set()
        for configuration in configurations:
            if not isinstance(configuration, dict):
                raise ValueError("Malformed test configuration")
            name = configuration.get("Name")
            if name is not None:
                if not isinstance(name, str) or not name or name in names:
                    raise ValueError("Invalid or ambiguous test configuration name")
                names.add(name)
            enabled = configuration.get("IsEnabled", True)
            entries = configuration.get("TestTargets")
            if type(enabled) is not bool or not isinstance(entries, list) or any(
                not isinstance(entry, dict) or not isinstance(entry.get("BlueprintName"), str) for entry in entries
            ):
                raise ValueError("Malformed test configuration targets or enabled flag")
            if not enabled:
                continue
            matching = [entry for entry in entries if entry["BlueprintName"] == "FoundationEvalsUITests"]
            if len(matching) > 1:
                raise ValueError("Ambiguous FoundationEvalsUITests UI target in configuration")
            targets.extend(matching)
    if not targets or any(
        not isinstance(target, dict) or target.get("BlueprintName") != "FoundationEvalsUITests"
        or target.get("IsUITestBundle", version == 2) is not True for target in targets
    ):
        raise ValueError("Full descriptor must contain an enabled FoundationEvalsUITests UI target")
    return targets


def prepare_ui_xctestrun(products: Path) -> Path:
    candidates = sorted(products.glob("FoundationEvals_macosx*.xctestrun"))
    if len(candidates) != 1:
        raise ValueError(f"Expected one full FoundationEvals descriptor, found {len(candidates)}")
    descriptor = candidates[0]
    if descriptor.is_symlink() or not descriptor.is_file():
        raise ValueError("UI descriptor must be a regular built file")
    encoded = descriptor.read_bytes()
    document = plistlib.loads(encoded)
    if not isinstance(document, dict):
        raise ValueError("UI descriptor must be a dictionary")
    targets = ui_targets(document)
    expected_path = "__TESTROOT__/Debug/Intents.app"
    if any(target.get("UITargetAppPath") not in (expected_path, "__TESTROOT__/Debug/FoundationEvals") for target in targets):
        raise ValueError("Unexpected UI target app path")
    app = products / "Debug/Intents.app"
    if not app.is_dir() or app.is_symlink():
        raise ValueError("Built Intents.app is missing or is a symlink")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.coryparry.FoundationEvals":
        raise ValueError("Built Intents.app has an unexpected bundle identifier")
    if any(target["UITargetAppPath"] != expected_path for target in targets):
        for target in targets:
            target["UITargetAppPath"] = expected_path
        plist_format = plistlib.FMT_BINARY if encoded.startswith(b"bplist00") else plistlib.FMT_XML
        descriptor.write_bytes(plistlib.dumps(document, fmt=plist_format, sort_keys=False))
    return descriptor.resolve()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: ci_ui_xctestrun.py BUILD_PRODUCTS_DIRECTORY")
    try:
        print(prepare_ui_xctestrun(Path(sys.argv[1])))
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        sys.exit(str(error))
