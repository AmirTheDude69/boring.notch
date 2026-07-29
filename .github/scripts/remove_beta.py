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


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def _is_within(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def resolve_workspace_file(
    raw_path: str | Path,
    workspace_root: str | Path | None = None,
) -> Path:
    value = str(raw_path)
    if not value or any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ValueError("Appcast path contains invalid characters")

    root = Path(
        workspace_root
        or os.environ.get("GITHUB_WORKSPACE")
        or Path.cwd()
    ).resolve(strict=True)
    candidate = Path(value)
    if not candidate.is_absolute():
        candidate = root / candidate
    resolved = candidate.resolve(strict=True)
    if not _is_within(resolved, root):
        raise ValueError("Appcast path is outside the trusted workspace")
    return resolved


def remove_last_beta_item(
    appcast_path: str | Path,
    workspace_root: str | Path | None = None,
) -> int:
    try:
        trusted_path = resolve_workspace_file(appcast_path, workspace_root)
        flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(trusted_path, flags)
        try:
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                raise ValueError("Appcast path is not a regular file")

            with os.fdopen(descriptor, "r+b", closefd=False) as appcast:
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
        finally:
            os.close(descriptor)
    except (OSError, ET.ParseError, ValueError) as error:
        print(f"Error processing appcast: {type(error).__name__}")
        return 2


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: remove_beta.py path/to/appcast.xml")
        raise SystemExit(1)

    raise SystemExit(remove_last_beta_item(sys.argv[1]))
