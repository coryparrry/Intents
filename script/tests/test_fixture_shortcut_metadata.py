import copy
import unittest
from script.check_fixture_shortcut_metadata import GENERIC, PRESETS, validate


def metadata():
    return {
        "actions": {
            **{identifier: {"parameters": []} for identifier in PRESETS.values()},
            **{identifier: {"parameters": [{"name": "note"}]} for identifier in GENERIC.values()},
        },
        "autoShortcuts": [
            {"actionIdentifier": identifier, "phraseTemplates": [{"key": phrase}]}
            for phrase, identifier in (PRESETS | GENERIC).items()
        ],
    }


class FixtureShortcutMetadataTests(unittest.TestCase):
    def test_distinct_preset_actions_preserve_all_existing_phrases_and_generic_actions(self):
        self.assertEqual(validate(metadata()), PRESETS | GENERIC)

    def test_reusing_generic_action_for_preset_is_rejected(self):
        data = metadata()
        data["autoShortcuts"][0]["actionIdentifier"] = "OpenNoteIntent"
        with self.assertRaisesRegex(ValueError, "expected OpenPackingNoteIntent"):
            validate(data)

    def test_duplicate_phrase_registration_is_rejected(self):
        data = metadata()
        data["autoShortcuts"].append(copy.deepcopy(data["autoShortcuts"][0]))
        with self.assertRaisesRegex(ValueError, "more than once"):
            validate(data)

    def test_entity_resolution_on_a_preset_is_rejected(self):
        data = metadata()
        data["actions"]["SummarizePackingNoteIntent"]["parameters"] = [{"name": "note"}]
        with self.assertRaisesRegex(ValueError, "must not need entity resolution"):
            validate(data)

    def test_saved_generic_parameter_is_preserved(self):
        data = metadata()
        data["actions"]["OpenNoteIntent"]["parameters"] = []
        with self.assertRaisesRegex(ValueError, "lost its note parameter"):
            validate(data)


if __name__ == "__main__":
    unittest.main()
