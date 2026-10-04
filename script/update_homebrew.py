#!/usr/bin/env python3
"""Update the Intents cask from a published, checksum-verified release."""

import argparse
import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path


VERSION = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"


def version_tuple(value):
    if not re.fullmatch(VERSION, value):
        raise ValueError("Require a vMAJOR.MINOR.PATCH release tag.")
    return tuple(int(part) for part in value.split("."))


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True)


def render_cask(version, checksum, repository):
    return f'''cask "intents" do
  version "{version}"
  sha256 "{checksum}"

  url "https://github.com/{repository}/releases/download/v#{{version}}/Intents-#{{version}}-macOS-arm64.dmg"
  name "Intents"
  desc "Evaluation workbench for Apple's Foundation Models"
  homepage "https://github.com/{repository}"

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :golden_gate

  app "Intents.app"
end
'''


def update(tag, tap_dir, repository):
    version = tag.removeprefix("v")
    requested_version = version_tuple(version)
    if tag != f"v{version}":
        raise ValueError("Require a vMAJOR.MINOR.PATCH release tag.")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Require a GitHub owner/repository name.")
    release = json.loads(gh(
        "release", "view", tag, "--repo", repository,
        "--json", "tagName,isDraft,isPrerelease,assets",
    ))
    if (release["tagName"] != tag or release["isDraft"] is not False
            or release["isPrerelease"] is not False):
        raise ValueError("Homebrew requires a published stable release.")

    cask = tap_dir / "Casks/intents.rb"
    previous_checksum = None
    if cask.exists():
        current = cask.read_text()
        current_version = re.search(r'^  version "([^"]+)"$', current, re.MULTILINE)
        current_checksum = re.search(r'^  sha256 "([a-f0-9]{64})"$', current, re.MULTILINE)
        if not current_version or not current_checksum:
            raise ValueError("Existing cask has no valid version or SHA-256.")
        installed_version = version_tuple(current_version[1])
        if installed_version > requested_version:
            print(f"Skipping {tag}: cask already provides {current_version[1]}.")
            return
        if installed_version == requested_version:
            previous_checksum = current_checksum[1]

    filename = f"Intents-{version}-macOS-arm64.dmg"
    for name in (filename, "SHA256SUMS.txt"):
        assets = [asset for asset in release["assets"] if asset["name"] == name]
        if len(assets) != 1 or assets[0]["size"] <= 0:
            raise ValueError(f"Require exactly one nonempty {name} release asset.")
    dmg_asset = next(asset for asset in release["assets"] if asset["name"] == filename)

    with tempfile.TemporaryDirectory(prefix="intents-homebrew-") as directory:
        gh("release", "download", tag, "--repo", repository, "--dir", directory,
           "--pattern", filename, "--pattern", "SHA256SUMS.txt")
        downloads = Path(directory)
        sums = (downloads / "SHA256SUMS.txt").read_text()
        matches = re.findall(r"^([a-fA-F0-9]{64}) [ *]" + re.escape(filename) + r"$",
                             sums, re.MULTILINE)
        if len(matches) != 1:
            raise ValueError("Require exactly one DMG checksum in SHA256SUMS.txt.")
        dmg = downloads / filename
        with dmg.open("rb") as stream:
            checksum = hashlib.file_digest(stream, "sha256").hexdigest()
        if checksum != matches[0].lower() or dmg.stat().st_size != dmg_asset["size"]:
            raise ValueError("Downloaded DMG does not match the release checksum/size.")
        digest = dmg_asset.get("digest")
        if digest and digest != f"sha256:{checksum}":
            raise ValueError("Downloaded DMG does not match GitHub's asset digest.")
    if previous_checksum and previous_checksum != checksum:
        raise ValueError("Refusing to change the checksum of an existing cask version.")
    content = render_cask(version, checksum, repository)
    if cask.exists() and cask.read_text() == content:
        print(f"Intents {version} is already current; no change.")
        return
    cask.parent.mkdir(parents=True, exist_ok=True)
    cask.write_text(content)
    print(f"Updated {cask} to Intents {version} ({checksum}).")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    parser.add_argument("--tap-dir", type=Path, default=Path("tap"))
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "coryparrry/Intents"))
    args = parser.parse_args()
    try:
        update(args.tag, args.tap_dir, args.repo)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Homebrew update failed: {error}\n")


if __name__ == "__main__":
    main()
