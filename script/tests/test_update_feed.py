import base64
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_validation import FEED_URL, PUBLIC_KEY, SPARKLE_NS, validate_update_feed


class UpdateFeedTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.tag = 'v1.2.3'
        self.filename = 'Foundation-Evals-1.2.3-macOS-arm64.dmg'
        (self.directory / self.filename).write_bytes(b'installer fixture')
        self.info = dict(SUFeedURL=FEED_URL, SUPublicEDKey=PUBLIC_KEY, CFBundleVersion='12')
        self.root = ET.Element('rss')
        self.item = ET.SubElement(ET.SubElement(self.root, 'channel'), 'item')
        ET.SubElement(self.item, SPARKLE_NS + 'version').text = '12'
        self.enclosure = ET.SubElement(self.item, 'enclosure', {
            'url': f'https://github.com/coryparrry/Foundation-Eval-Labs/releases/download/{self.tag}/{self.filename}',
            'length': '17', SPARKLE_NS + 'edSignature': base64.b64encode(b'x' * 64).decode(),
        })

    def validate(self):
        ET.ElementTree(self.root).write(self.directory / 'appcast.xml')
        validate_update_feed(self.directory, self.info, self.tag)

    def test_matching_release_metadata(self):
        # Shape validation only: signature authenticity is enforced by Sparkle.
        self.validate()

    def test_rejects_wrong_download_and_archive_length(self):
        for key, value in [('url', 'https://example.com/other.dmg'), ('length', '999'),
                           (SPARKLE_NS + 'edSignature', ''), (SPARKLE_NS + 'edSignature', 'invalid')]:
            original = self.enclosure.get(key)
            self.enclosure.set(key, value)
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.validate()
            self.enclosure.set(key, original)

    def test_rejects_wrong_key_feed_and_build(self):
        for key, value in [('SUPublicEDKey', ''), ('SUFeedURL', 'https://example.com/feed'),
                           ('CFBundleVersion', '13'), ('CFBundleVersion', '0')]:
            original = self.info[key]
            self.info[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.validate()
            self.info[key] = original

    def test_rejects_missing_or_multiple_updates(self):
        channel = self.root.find('channel')
        channel.remove(self.item)
        with self.assertRaises(ValueError):
            self.validate()
        channel.extend([self.item, self.item])
        with self.assertRaises(ValueError):
            self.validate()


if __name__ == '__main__':
    unittest.main()
