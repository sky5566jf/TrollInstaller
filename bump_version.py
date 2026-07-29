#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Bump app version for each CI build.

- CFBundleShortVersionString: +0.1 (one decimal place)
- CFBundleVersion:            +1 (integer build number, used by TrollStore
                              to treat a re-install as an app update)

Uses regex on the raw plist text so that comments and formatting are
preserved (plistlib would strip XML comments). Prints the new short
version to stdout so the CI step can capture it for the artifact name.
"""
import re
import sys

PLIST = 'Info.plist'


def main() -> None:
    with open(PLIST, encoding='utf-8') as f:
        s = f.read()

    # ---- CFBundleShortVersionString: +0.1 ----
    m = re.search(
        r'(<key>CFBundleShortVersionString</key>\s*<string>)([\d.]+)(</string>)',
        s,
    )
    if not m:
        print('ERROR: CFBundleShortVersionString not found', file=sys.stderr)
        sys.exit(1)
    old_short = float(m.group(2))
    new_short = round(old_short + 0.1, 1)
    new_short_s = f'{new_short:.1f}'
    s = s[:m.start()] + m.group(1) + new_short_s + m.group(3) + s[m.end():]

    # ---- CFBundleVersion: +1 (integer) ----
    m2 = re.search(
        r'(<key>CFBundleVersion</key>\s*<string>)([\d.]+)(</string>)',
        s,
    )
    if m2:
        old_build = int(float(m2.group(2)))
        new_build = old_build + 1
        s = s[:m2.start()] + m2.group(1) + str(new_build) + m2.group(3) + s[m2.end():]

    with open(PLIST, 'w', encoding='utf-8') as f:
        f.write(s)

    print(new_short_s)


if __name__ == '__main__':
    main()
