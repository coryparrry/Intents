"""Check the compiler's fixture App Shortcut registrations; does not test Siri matching."""
import argparse
import json
from pathlib import Path


PRESETS = {
    "Open the packing note in ${applicationName}": "OpenPackingNoteIntent",
    "Summarize the packing note in ${applicationName}": "SummarizePackingNoteIntent",
}
GENERIC = {
    "Open a note in ${applicationName}": "OpenNoteIntent",
    "Summarize a note in ${applicationName}": "SummarizeNoteIntent",
}


def validate(metadata):
    actions = metadata["actions"]
    registrations = {}
    for shortcut in metadata["autoShortcuts"]:
        for phrase in shortcut["phraseTemplates"]:
            key = phrase["key"]
            if key in registrations:
                raise ValueError(f"Phrase registered more than once: {key}")
            registrations[key] = shortcut["actionIdentifier"]
    for phrase, identifier in (PRESETS | GENERIC).items():
        if registrations.get(phrase) != identifier:
            raise ValueError(f"{phrase}: expected {identifier}, got {registrations.get(phrase)}")
        if identifier not in actions:
            raise ValueError(f"Missing action: {identifier}")
    for identifier in PRESETS.values():
        if actions[identifier].get("parameters"):
            raise ValueError(f"Preset {identifier} must not need entity resolution")
    for identifier in GENERIC.values():
        if not any(parameter["name"] == "note" for parameter in actions[identifier].get("parameters", [])):
            raise ValueError(f"Saved generic action {identifier} lost its note parameter")
    return registrations


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("metadata", type=Path, help="Built .app/Metadata.appintents/extract.actionsdata")
    args = parser.parse_args()
    registrations = validate(json.loads(args.metadata.read_text()))
    for phrase, identifier in registrations.items():
        print(f"{phrase} -> {identifier}")


if __name__ == "__main__":
    main()
