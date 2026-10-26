"""Validate release evidence without executing downloaded metadata."""

import base64
import hashlib
import json
import plistlib
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

REQUIRED_CHECKS = {
    "Compile app and tests",
    "Portable regression tests",
    "Workflow and script checks",
}
APP_DISPLAY_NAME = "Intents"


def validate_checks(jobs):
    """Require each named release gate to have a success conclusion, raising ValueError for missing or unsuccessful checks."""
    conclusions = {job["name"]: job["conclusion"] for job in jobs}
    missing = sorted(
        name for name in REQUIRED_CHECKS if conclusions.get(name) != "success"
    )
    if missing:
        raise ValueError("Release requires successful checks: " + ", ".join(missing))


def verify_checksum(directory, filename):
    """Require a checksum file naming exactly the expected installer, compare its SHA-256, and return the verified digest."""
    checksum = (directory / "SHA256SUMS.txt").read_text().strip()
    match = re.fullmatch(r"([a-fA-F0-9]{64}) [ *]" + re.escape(filename), checksum)
    if not match:
        raise ValueError("Checksum file must name exactly the expected installer.")
    digest = hashlib.sha256((directory / filename).read_bytes()).hexdigest()
    if digest != match[1].lower():
        raise ValueError("Installer checksum does not match.")
    return digest


def validate_app_metadata(info, version, expected_commit=None):
    """Require the Intents bundle brand and requested version, and compare embedded source provenance when an expected commit is supplied."""
    if info.get("CFBundleDisplayName") != APP_DISPLAY_NAME:
        raise ValueError("App display name does not match the Intents release brand.")
    if info.get("CFBundleName") != APP_DISPLAY_NAME:
        raise ValueError("App bundle name does not match the Intents release brand.")
    if info.get("CFBundleShortVersionString") != version:
        raise ValueError("App version does not match the release tag.")
    if expected_commit and info.get("FoundationEvalsSourceCommit") != expected_commit:
        raise ValueError(
            "Signed app source commit does not match the release tag commit."
        )


SPARKLE_NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
FEED_URL = "https://github.com/coryparrry/Intents/releases/latest/download/appcast.xml"
PUBLIC_KEY = "fpED/OlsZgCvLG9IgiEI0+/JmGjbwEkxmnwwkwymPgY="


def validate_update_feed(directory, info, tag):
    """Validate updater configuration, positive build number, exact release enclosure URL and size, and a 64-byte base64 signature; return its encoded text."""
    if info.get("SUFeedURL") != FEED_URL or info.get("SUPublicEDKey") != PUBLIC_KEY:
        raise ValueError(
            "App updater feed or public key does not match release configuration."
        )
    build = str(info.get("CFBundleVersion", ""))
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("Sparkle requires a positive integer build number.")
    root = ET.parse(directory / "appcast.xml").getroot()
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ValueError("Release feed must contain exactly the packaged update.")
    item = items[0]
    if item.findtext(SPARKLE_NS + "version") != build:
        raise ValueError("Feed build does not match the signed app.")
    filename = f"Intents-{tag[1:]}-macOS-arm64.dmg"
    enclosure = item.find("enclosure")
    expected_url = f"https://github.com/coryparrry/Intents/releases/download/{tag}/{filename}"
    if enclosure is None or enclosure.get("url") != expected_url:
        raise ValueError("Feed must point to this release's installer.")
    if enclosure.get("length") != str((directory / filename).stat().st_size):
        raise ValueError("Feed installer length does not match.")
    signature = enclosure.get(SPARKLE_NS + "edSignature", "")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Feed must contain an EdDSA signature.")
    return signature


if __name__ == "__main__":
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "checks":
            validate_checks(json.loads(Path(sys.argv[2]).read_text())["jobs"])
        elif len(sys.argv) == 4 and sys.argv[1] == "checksum":
            print(
                "Installer checksum verified:",
                verify_checksum(Path(sys.argv[2]), sys.argv[3]),
            )
        elif len(sys.argv) == 5 and sys.argv[1] == "metadata":
            info = plistlib.loads(Path(sys.argv[2]).read_bytes())
            validate_app_metadata(info, sys.argv[3], sys.argv[4] or None)
        elif len(sys.argv) == 5 and sys.argv[1] == "appcast":
            print(
                validate_update_feed(
                    Path(sys.argv[2]),
                    plistlib.loads(Path(sys.argv[3]).read_bytes()),
                    sys.argv[4],
                )
            )
        else:
            raise ValueError(
                "Usage: release_validation.py checks FILE | checksum DIRECTORY FILENAME | metadata PLIST VERSION COMMIT"
            )
    except (ValueError, KeyError, OSError, ET.ParseError) as error:
        sys.exit(str(error))
