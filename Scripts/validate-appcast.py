#!/usr/bin/env python3
import base64
import plistlib
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def validate(feed, archive, plist):
    with Path(plist).open("rb") as stream:
        info = plistlib.load(stream)
    items = ET.parse(feed).findall("./channel/item")
    if len(items) != 1:
        raise ValueError("The update feed must contain one release.")
    item = items[0]
    expected = {
        "version": info["CFBundleVersion"],
        "shortVersionString": info["CFBundleShortVersionString"],
        "minimumSystemVersion": info["LSMinimumSystemVersion"],
    }
    for key, value in expected.items():
        if item.findtext(SPARKLE + key) != value:
            raise ValueError(f"The update {key} does not match the app.")
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("The update archive is missing.")
    signature = base64.b64decode(enclosure.get(SPARKLE + "edSignature", ""), validate=True)
    if len(signature) != 64:
        raise ValueError("The update archive must have an Ed25519 signature.")
    archive = Path(archive)
    version = info["CFBundleShortVersionString"]
    url = f"https://github.com/KarstenEconomou/sidetone/releases/download/v{version}/{archive.name}"
    if enclosure.get("url") != url:
        raise ValueError("The update URL does not match the release archive.")
    if int(enclosure.get("length", "0")) != archive.stat().st_size:
        raise ValueError("The update archive size does not match the feed.")


if __name__ == "__main__":
    try:
        validate(*sys.argv[1:])
    except (ValueError, KeyError, OSError, ET.ParseError) as error:
        sys.exit(str(error))
