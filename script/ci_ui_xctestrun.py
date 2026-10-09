"""Select the built UI descriptor and repair Xcode's known executable-path alias."""

import plistlib
import sys
from pathlib import Path


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
    target = document.get("FoundationEvalsUITests")
    if not isinstance(target, dict) or target.get("BlueprintName") != "FoundationEvalsUITests" or target.get("IsUITestBundle") is not True:
        raise ValueError("Full descriptor must contain the FoundationEvalsUITests UI target")
    expected_path = "__TESTROOT__/Debug/Intents.app"
    if target.get("UITargetAppPath") not in (expected_path, "__TESTROOT__/Debug/FoundationEvals"):
        raise ValueError("Unexpected UI target app path")
    app = products / "Debug/Intents.app"
    if not app.is_dir() or app.is_symlink():
        raise ValueError("Built Intents.app is missing or is a symlink")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.coryparry.FoundationEvals":
        raise ValueError("Built Intents.app has an unexpected bundle identifier")
    if target["UITargetAppPath"] != expected_path:
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
