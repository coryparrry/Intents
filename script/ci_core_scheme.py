"""Derive a CI-only scheme without UI tests from the maintained app scheme."""

import xml.etree.ElementTree as ET
from pathlib import Path

SCHEMES = Path("FoundationEvals/FoundationEvals.xcodeproj/xcshareddata/xcschemes")


def create_core_scheme(source, destination):
    """Remove exactly one UI testable and write the CI scheme, raising ValueError if expected UI or retained core targets are absent."""
    tree = ET.parse(source)
    testables = tree.find("TestAction/Testables")
    if testables is None:
        raise ValueError("App scheme must contain TestAction/Testables")
    ui = [
        test
        for test in testables
        if test.find("BuildableReference") is not None
        and test.find("BuildableReference").get("BlueprintName")
        == "FoundationEvalsUITests"
    ]
    if len(ui) != 1:
        raise ValueError("Expected exactly one FoundationEvalsUITests testable")
    testables.remove(ui[0])
    if not any(
        test.find("BuildableReference") is not None
        and test.find("BuildableReference").get("BlueprintName")
        == "FoundationEvalsTests"
        for test in testables
    ):
        raise ValueError("Core scheme must retain FoundationEvalsTests")
    tree.write(destination, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    create_core_scheme(
        SCHEMES / "FoundationEvals.xcscheme", SCHEMES / "FoundationEvalsCoreCI.xcscheme"
    )
