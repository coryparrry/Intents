"""Reuse a verified CI automation executable without starting SwiftPM."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import tempfile

RECEIPT = "ci-automation-executable.json"
# These manifests define the reviewed source roots below. Unknown layouts still build normally.
MANIFESTS = {
    "Package.swift": "b7b2c3975e55c5dbfb81b531338f4abee09a3cba9df5952bdef0fb5dc454eab2",
    "Packages/ProductionEvals/Package.swift": "1c8f054724f1c8d1e2addcb6479ee3185266f977e128f8acf389eb731325edbf",
}
SOURCE_ROOTS = ("Sources", "Tools", "Integration", "Packages")
BUILD_ENV = ("SWIFT", "_SWIFT", "SDK", "XCODE", "DEVELOPER", "TOOLCHAINS", "MACOSX_",
             "ARCHS", "CFLAGS", "CXXFLAGS", "LDFLAGS", "OTHER_", "CC", "CXX", "CLANG",
             "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "LIBRARY_PATH", "OBJCFLAGS",
             "OBJC_INCLUDE_PATH", "PKG_CONFIG", "DYLD_", "LD_LIBRARY_PATH")


def sha256(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def safe_path(root, relative):
    if not isinstance(relative, str) or not relative or "\\" in relative or "\0" in relative:
        raise ValueError("Invalid checkpoint path")
    parts = PurePosixPath(relative)
    if not parts.parts or parts.is_absolute() or ".." in parts.parts or str(parts) != relative:
        raise ValueError("Checkpoint path escapes build root")
    path = root
    for part in parts.parts:
        path = path / part
        if path.is_symlink():
            raise ValueError("Checkpoint paths cannot be symlinks")
    return path


def file_entry(path):
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError("Checkpoint input must be a regular file")
    return {"sha256": sha256(path), "mode": stat.S_IMODE(metadata.st_mode)}


def tree(root, directory, *, sources=False):
    result = {}
    if not directory.exists():
        return result
    for current, directories, files in os.walk(directory, followlinks=False):
        if sources:
            directories[:] = [name for name in directories if name not in (".build", ".git", ".swiftpm")]
        for name in [*directories, *files]:
            path = Path(current) / name
            relative = path.relative_to(root).as_posix()
            safe_path(root, relative)
            result[relative] = {"directory": stat.S_IMODE(path.stat().st_mode)} if path.is_dir() else file_entry(path)
    return result


def build_fingerprint(commands, root, scratch, arguments):
    """None disables executable reuse for an unsupported package layout."""
    try:
        files = {}
        for directory in SOURCE_ROOTS:
            path = safe_path(root, directory)
            if not path.is_dir():
                return None
            # Integration/AutomationHost is copied wholesale, including hidden resource trees.
            files.update(tree(root, path, sources=directory != "Integration"))
        for path in root.glob("Package*.swift"):
            relative = path.relative_to(root).as_posix()
            files[relative] = file_entry(safe_path(root, relative))
        manifests = {name: value["sha256"] for name, value in files.items()
                     if Path(name).name.startswith("Package") and name.endswith(".swift") and "sha256" in value}
        if manifests != MANIFESTS:
            return None
        for manifest in manifests:
            parent = Path(manifest).parent
            resolved = root / parent / "Package.resolved"
            if resolved.exists():
                files[resolved.relative_to(root).as_posix()] = file_entry(safe_path(root, resolved.relative_to(root).as_posix()))
            configuration = root / parent / ".swiftpm/configuration"
            if configuration.exists():
                safe_path(root, configuration.relative_to(root).as_posix())
                files.update(tree(root, configuration))
        queries = (("compiler", ["xcrun", "--find", "swift"]),
                   ("version", ["xcrun", "swift", "--version"]),
                   ("xcode", ["xcodebuild", "-version"]),
                   ("sdk", ["xcrun", "--sdk", "macosx", "--show-sdk-path"]),
                   ("sdkBuild", ["xcrun", "--sdk", "macosx", "--show-sdk-build-version"]),
                   ("architecture", ["uname", "-m"]), ("osBuild", ["sw_vers", "-buildVersion"]))
        identity = {}
        for name, command in queries:
            _, raw = commands.run(command)
            if not raw.strip() or len(raw) > 8192:
                return None
            identity[name] = raw.strip()
        identity["compilerDigest"] = sha256(Path(identity["compiler"]).resolve())
        environment = {key: value for key, value in commands.env.items() if key.startswith(BUILD_ENV) or key == "PATH"}
        return fingerprint({"schema": 1, "inputs": files, "identity": identity, "environment": environment,
                            "root": str(root.resolve()), "scratch": str(scratch.resolve()),
                            "arguments": [str(argument) for argument in arguments], "helper": sha256(Path(__file__))})
    except (OSError, ValueError):
        return None


def artifacts(scratch, cli_relative):
    cli = safe_path(scratch, cli_relative)
    if cli.name != "intents-automation":
        raise ValueError("Unexpected cached executable")
    executable = file_entry(cli)
    if not executable["mode"] & 0o111:
        raise ValueError("Cached CLI is not executable")
    resources = {}
    bundles = sorted(path for path in cli.parent.iterdir() if path.suffix in (".bundle", ".resources"))
    if not any("IntentsAutomationCLIResources" in path.name for path in bundles):
        raise ValueError("CLI resource bundle is missing")
    for bundle in bundles:
        safe_path(scratch, bundle.relative_to(scratch).as_posix())
        if not bundle.is_dir():
            raise ValueError("CLI resource bundle is not a directory")
        resources[bundle.relative_to(scratch).as_posix()] = {"directory": stat.S_IMODE(bundle.stat().st_mode)}
        resources.update(tree(scratch, bundle))
    if not any(name.endswith("/AutomationHost/HostPlan.swift") for name in resources):
        raise ValueError("CLI host templates are missing")
    return {"executable": executable, "resources": resources}


def cached_cli(scratch, expected):
    """Return (verified executable, whether current-input products require a clean build)."""
    if expected is None:
        return None, False
    try:
        receipt_path = safe_path(scratch, RECEIPT)
        if receipt_path.stat().st_size > 16 * 1024 * 1024:
            return None, False
        receipt = json.loads(receipt_path.read_text())
        if (not isinstance(receipt, dict) or type(receipt.get("schema")) is not int or receipt["schema"] != 1
                or receipt.get("fingerprint") != expected or set(receipt) != {"schema", "fingerprint", "cli", "artifacts"}):
            return None, False
    except (OSError, ValueError, TypeError):
        return None, False
    try:
        if receipt["artifacts"] == artifacts(scratch, receipt["cli"]):
            return safe_path(scratch, receipt["cli"]), False
    except (OSError, ValueError, TypeError):
        pass
    return None, True


def record_cli(scratch, expected, cli):
    # Replace a hostile receipt link itself; never read or overwrite its target.
    if (scratch / RECEIPT).is_symlink():
        (scratch / RECEIPT).unlink()
    receipt_path = safe_path(scratch, RECEIPT)
    if expected is None:
        receipt_path.unlink(missing_ok=True)
        return
    relative = cli.relative_to(scratch).as_posix()
    receipt = {"schema": 1, "fingerprint": expected, "cli": relative, "artifacts": artifacts(scratch, relative)}
    with tempfile.NamedTemporaryFile(mode="w", dir=scratch, delete=False) as temporary:
        json.dump(receipt, temporary, sort_keys=True)
    os.replace(temporary.name, receipt_path)
