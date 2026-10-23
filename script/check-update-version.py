#!/usr/bin/env python3
"""Reject update build numbers that cannot advance the published appcast."""

import re
import sys
import xml.etree.ElementTree as ET


def version(value):
    if not re.fullmatch(r"[1-9][0-9]{0,3}(?:\.[0-9]{1,2}){0,2}", value):
        raise ValueError(f"Invalid Apple build number: {value!r}")
    parts = [int(part) for part in value.split(".")]
    return tuple(parts + [0] * (3 - len(parts)))


def check(current, previous=None):
    build = version(current)
    if previous:
        root = ET.parse(previous).getroot()
        namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
        versions = []
        for item in root.findall("./channel/item"):
            value = item.findtext(f"{namespace}version")
            if value is None:
                enclosure = item.find("enclosure")
                value = enclosure.get(f"{namespace}version") if enclosure is not None else None
            if value is None:
                raise ValueError("A published update has no build number.")
            versions.append(value)
        if not versions:
            raise ValueError("The published appcast has no build numbers.")
        if build <= max(version(value) for value in versions):
            raise ValueError(f"Build {current} must be newer than every published update.")


if __name__ == "__main__":
    try:
        check(*sys.argv[1:])
    except (ValueError, TypeError, OSError, ET.ParseError) as error:
        sys.exit(f"Cannot publish update: {error}")
