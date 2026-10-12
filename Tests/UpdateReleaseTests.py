import base64
import importlib.util
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "appcast", Path(__file__).resolve().parent.parent / "Scripts/validate-appcast.py"
)
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


class UpdateReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.archive = self.root / "Sidetone-1.2.0-macos-universal.zip"
        self.archive.write_bytes(b"update archive")
        self.plist = self.root / "Info.plist"
        self.plist.write_bytes(
            plistlib.dumps(
                {
                    "CFBundleVersion": "10",
                    "CFBundleShortVersionString": "1.2.0",
                    "LSMinimumSystemVersion": "13.0",
                }
            )
        )
        self.feed = self.root / "appcast.xml"
        self.rss = ET.Element("rss")
        self.item = ET.SubElement(ET.SubElement(self.rss, "channel"), "item")
        for key, value in [
            ("version", "10"),
            ("shortVersionString", "1.2.0"),
            ("minimumSystemVersion", "13.0"),
        ]:
            ET.SubElement(self.item, appcast.SPARKLE + key).text = value
        self.enclosure = ET.SubElement(
            self.item,
            "enclosure",
            {
                "url": "https://github.com/KarstenEconomou/sidetone/releases/download/v1.2.0/"
                + self.archive.name,
                "length": str(self.archive.stat().st_size),
                appcast.SPARKLE + "edSignature": base64.b64encode(bytes(64)).decode(),
            },
        )

    def validate(self):
        ET.ElementTree(self.rss).write(self.feed)
        appcast.validate(self.feed, self.archive, self.plist)

    def test_matching_release_metadata(self):
        self.validate()

    def test_unsigned_archive_is_rejected(self):
        del self.enclosure.attrib[appcast.SPARKLE + "edSignature"]
        with self.assertRaises(ValueError):
            self.validate()

    def test_changed_archive_size_is_rejected(self):
        self.archive.write_bytes(b"changed archive")
        with self.assertRaises(ValueError):
            self.validate()

    def test_wrong_release_url_is_rejected(self):
        self.enclosure.set("url", "https://example.invalid/update.zip")
        with self.assertRaises(ValueError):
            self.validate()

    def test_wrong_build_or_system_version_is_rejected(self):
        for key in ["version", "shortVersionString", "minimumSystemVersion"]:
            with self.subTest(key=key):
                element = self.item.find(appcast.SPARKLE + key)
                value = element.text
                element.text = "999"
                with self.assertRaises(ValueError):
                    self.validate()
                element.text = value


if __name__ == "__main__":
    unittest.main()
