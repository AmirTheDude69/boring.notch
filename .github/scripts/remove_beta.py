#!/usr/bin/env python3
"""
Remove the last beta item from an appcast XML file.
Usage: remove_beta.py path/to/appcast.xml
"""

from __future__ import annotations

import os
import stat
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import BinaryIO


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
APPCAST_RELATIVE_PATH = "updater/appcast.xml"


def _remove_last_beta_from_stream(appcast: BinaryIO) -> int:
    tree = ET.parse(appcast)
    root = tree.getroot()

    channel = root.find("channel")
    if channel is None:
        print("No channel found in appcast")
        return 0

    removed = False
    for item in reversed(channel.findall("item")):
        enclosure = item.find("enclosure")
        if enclosure is None:
            continue
        version = (
            enclosure.get(f"{{{SPARKLE_NAMESPACE}}}version")
            or enclosure.get("sparkle:version")
            or ""
        )
        if "beta" in version.lower():
            channel.remove(item)
            removed = True
            break

    if not removed:
        print("No beta item found in appcast")
        return 0

    appcast.seek(0)
    tree.write(appcast, encoding="utf-8", xml_declaration=True)
    appcast.truncate()
    appcast.flush()
    os.fsync(appcast.fileno())
    print("Removed beta item from appcast")
    return 0


def _open_repository_appcast() -> int:
    repository_root = Path(__file__).resolve(strict=True).parents[2]
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    repository_descriptor = os.open(repository_root, directory_flags | nofollow)
    try:
        updater_descriptor = os.open(
            "updater",
            directory_flags | nofollow,
            dir_fd=repository_descriptor,
        )
        try:
            return os.open(
                "appcast.xml",
                os.O_RDWR | nofollow,
                dir_fd=updater_descriptor,
            )
        finally:
            os.close(updater_descriptor)
    finally:
        os.close(repository_descriptor)


def remove_last_beta_item(requested_path: str | Path = APPCAST_RELATIVE_PATH) -> int:
    if str(requested_path) != APPCAST_RELATIVE_PATH:
        print("Error processing appcast: only updater/appcast.xml is permitted")
        return 2

    try:
        descriptor = _open_repository_appcast()
        try:
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                raise ValueError("Appcast path is not a regular file")
            with os.fdopen(descriptor, "r+b", closefd=False) as appcast:
                return _remove_last_beta_from_stream(appcast)
        finally:
            os.close(descriptor)
    except (OSError, ET.ParseError, ValueError) as error:
        print(f"Error processing appcast: {type(error).__name__}")
        return 2


if __name__ == "__main__":
    if len(sys.argv) > 2:
        print("Usage: remove_beta.py [updater/appcast.xml]")
        raise SystemExit(1)

    requested_path = sys.argv[1] if len(sys.argv) == 2 else APPCAST_RELATIVE_PATH
    raise SystemExit(remove_last_beta_item(requested_path))
