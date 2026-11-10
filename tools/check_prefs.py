#!/usr/bin/env python3
"""Check that every pref Zen Browser Lite sets is known to a Zen Browser build.

Firefox silently ignores prefs it does not know, so a renamed or removed pref would
quietly stop saving memory. This script collects every pref name the build mentions
(compiled static prefs in libxul, default pref files, and the JavaScript inside both
omni.ja archives) and fails if a Zen Browser Lite pref is not among them.

Usage: check_prefs.py ZEN_INSTALL_DIR PREFS_FILE [PREFS_FILE ...]
"""

from __future__ import annotations

import re
import struct
import sys
import zlib
from pathlib import Path

PREF_CALL = re.compile(r'^\s*pref\(\s*"([^"]+)"', re.MULTILINE)
OWN_PREFIX = "zenlite."
# Prefs that are read under a computed name and therefore never appear as one string.
DYNAMIC_ALLOWED: set[str] = set()


def omni_texts(path: Path):
    """Yield the decompressed text files inside a Mozilla omni.ja.

    omni.ja is a zip whose entries may be reordered for startup speed, which confuses
    stock zip readers, so the central directory is walked by hand.
    """
    data = path.read_bytes()
    pos = 0
    while True:
        pos = data.find(b"PK\x01\x02", pos)
        if pos < 0:
            return
        method = struct.unpack_from("<H", data, pos + 10)[0]
        csize = struct.unpack_from("<I", data, pos + 20)[0]
        nlen, elen, clen = struct.unpack_from("<HHH", data, pos + 28)
        offset = struct.unpack_from("<I", data, pos + 42)[0]
        name = data[pos + 46 : pos + 46 + nlen].decode("utf-8", "replace")
        pos += 46 + nlen + elen + clen
        if not name.endswith((".js", ".mjs", ".json", ".xhtml", ".html")):
            continue
        if data[offset : offset + 4] != b"PK\x03\x04":
            continue
        lnlen, lelen = struct.unpack_from("<HH", data, offset + 26)
        start = offset + 30 + lnlen + lelen
        raw = data[start : start + csize]
        try:
            body = zlib.decompress(raw, -15) if method == 8 else raw
        except zlib.error:
            continue
        yield body.decode("utf-8", "replace")


def binary_strings(path: Path, min_len: int = 6):
    for match in re.finditer(rb"[\x20-\x7e]{%d,}" % min_len, path.read_bytes()):
        yield match.group().decode("ascii")


def known_pref_names(install: Path) -> set[str]:
    text_parts: list[str] = []
    for omni in (install / "omni.ja", install / "browser" / "omni.ja"):
        if omni.is_file():
            text_parts.extend(omni_texts(omni))
    for pref_dir in (install / "defaults" / "pref", install / "browser" / "defaults" / "preferences"):
        if pref_dir.is_dir():
            text_parts.extend(p.read_text("utf-8", "replace") for p in pref_dir.glob("*.js"))
    blob = "\n".join(text_parts)
    names = set(re.findall(r'["\']([a-zA-Z0-9_.\-]+\.[a-zA-Z0-9_.\-]+)["\']', blob))
    libxul = install / "libxul.so"
    if libxul.is_file():
        names.update(binary_strings(libxul))
    return names


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    install = Path(argv[1])
    if not (install / "application.ini").is_file():
        print(f"error: {install} does not look like a Zen install (no application.ini)", file=sys.stderr)
        return 2
    known = known_pref_names(install)
    if len(known) < 1000:
        print(f"error: only {len(known)} pref names found; the install looks incomplete", file=sys.stderr)
        return 2

    missing: list[tuple[str, str]] = []
    checked = 0
    for prefs_file in map(Path, argv[2:]):
        for name in PREF_CALL.findall(prefs_file.read_text("utf-8")):
            if name.startswith(OWN_PREFIX) or name in DYNAMIC_ALLOWED:
                continue
            checked += 1
            if name not in known:
                missing.append((prefs_file.name, name))

    if missing:
        for file_name, name in missing:
            print(f"unknown pref in {file_name}: {name}")
        print(f"{len(missing)} of {checked} prefs are not known to this build")
        return 1
    print(f"ok: all {checked} prefs are known to this build")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
