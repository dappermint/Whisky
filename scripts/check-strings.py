#!/usr/bin/env python3
#
#  check-strings.py
#  Whisky
#
#  This file is part of Whisky.
#
#  Whisky is free software: you can redistribute it and/or modify it under the terms
#  of the GNU General Public License as published by the Free Software Foundation,
#  either version 3 of the License, or (at your option) any later version.
#
#  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
#  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#  See the GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License along with Whisky.
#  If not, see https://www.gnu.org/licenses/.
#
# A key renders as its own raw text in two ways, and both have shipped:
#
#   1. The entry is in the catalog with translations for other languages and no
#      English source value. Crowdin fills translations; the en value was never
#      entered. This hit all 63 audio keys at once.
#   2. The key is used in code but was never added to the catalog at all. This
#      hit 37 console and program-override keys.
#
# Neither is caught by the compiler, and a key whose name is identifier-shaped
# (`config.audio.driver.auto`) is exactly the kind that looks fine in code and
# renders as garbage. This check makes both a CI failure.

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Whisky" / "Localizable.xcstrings"
SOURCE_DIRS = [ROOT / "Whisky", ROOT / "WhiskyKit" / "Sources"]

# Identifier-shaped: two or more dot-joined segments, starting lowercase, no
# whitespace. `Text("Analyze")` needs no catalog entry because the key is the
# string; `library.card.hide` without one renders literally as that.
IDENTIFIER_KEY = re.compile(r"^[a-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)+$")

# Prefixes that match the shape but are not localization keys.
NOT_A_KEY = re.compile(r"^(com|org|net|io)\.")

# Call sites whose first string literal is a localization key. Deliberately a
# list of known-localizing contexts rather than every string in the tree, so a
# file name or a UserDefaults key can never false-positive.
CALL_PATTERNS = [
    r'String\(\s*localized:\s*"([^"\\]+)"',
    r'LocalizedStringResource\(\s*"([^"\\]+)"',
    r'\bText\("([^"\\]+)"\)',
    r'\bButton\("([^"\\]+)"',
    r'\bLabel\("([^"\\]+)"',
    r'\bToggle\("([^"\\]+)"',
    r'\bPicker\("([^"\\]+)"',
    r'\bTextField\("([^"\\]+)"',
    r'\bMenu\("([^"\\]+)"',
    r'\bSection\("([^"\\]+)"',
    r'\balert\(\s*"([^"\\]+)"',
    r'\.help\("([^"\\]+)"\)',
    r'\.navigationTitle\("([^"\\]+)"\)',
    r'\.accessibilityLabel\("([^"\\]+)"\)',
    r'\.accessibilityHint\("([^"\\]+)"\)',
    r'\bProgressView\("([^"\\]+)"',
    r'\bContentUnavailableView\("([^"\\]+)"',
]

# Bare literals in switch arms (LocalizedStringResource properties) are not
# scanned: the same shape carries SF Symbol names, file names and process
# names, and a checker that needs an allowlist stops being trusted. Keys used
# that way are the rare case and still covered by rule 1 once catalogued.


def used_keys() -> dict[str, str]:
    """Identifier-shaped keys used in localizing positions, key -> first site."""
    found: dict[str, str] = {}
    patterns = [re.compile(p) for p in CALL_PATTERNS]
    for src_dir in SOURCE_DIRS:
        for path in sorted(src_dir.rglob("*.swift")):
            text = path.read_text(encoding="utf-8")
            rel = path.relative_to(ROOT)
            candidates = []
            for pattern in patterns:
                candidates += pattern.findall(text)
            for candidate in candidates:
                # Interpolated keys ("menubar.launchFailed \(name)") carry a
                # format suffix in the catalog; checking them needs the compiler
                # rather than a regex, so they are out of scope here.
                if IDENTIFIER_KEY.match(candidate) and not NOT_A_KEY.match(candidate):
                    found.setdefault(candidate, str(rel))
    return found


def main() -> int:
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    strings = catalog["strings"]

    failures: list[str] = []

    # 1. Identifier-shaped entries must carry an English source value.
    for key, entry in sorted(strings.items()):
        if not IDENTIFIER_KEY.match(key):
            continue
        localizations = entry.get("localizations", {})
        has_en = "en" in localizations and "stringUnit" in localizations["en"]
        if localizations and not has_en:
            failures.append(f"no English source value: {key}")

    # 2. Identifier-shaped keys used in code must exist in the catalog.
    for key, site in sorted(used_keys().items()):
        if key not in strings:
            failures.append(f"used but not in the catalog: {key} ({site})")

    if failures:
        for failure in failures:
            print(failure)
        print(f"\n{len(failures)} problem(s). Both render the raw key to users.")
        return 1

    print("every identifier-shaped key has an English source and a catalog entry")
    return 0


if __name__ == "__main__":
    sys.exit(main())
