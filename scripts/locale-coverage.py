#!/usr/bin/env python3
#
# locale-coverage.py
#
# This file is part of Whisky.
#
# Whisky is free software: you can redistribute it and/or modify it under the terms
# of the GNU General Public License as published by the Free Software Foundation,
# either version 3 of the License, or (at your option) any later version.
#
# Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
# without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with Whisky.
# If not, see https://www.gnu.org/licenses/.
#
# Gives every translated locale a row for every string, filling the gaps with
# the English source.
#
# Same trap scripts/british-english.py exists for, one scope wider: macOS picks
# one localization per process and a compiled .strings table is not consulted
# key by key, so a key missing from the chosen table renders as the raw key
# rather than falling back to en. Translations arrive per release, the app gains
# strings between them, and the gap is not English text on a German screen, it
# is `library.card.settings`. Filled rows are marked needs_review so a real
# translation still shows up as outstanding work.
#
# Preview lane only. main feeds Crowdin, where an English row wearing a
# translation's state is worse than an honest gap.
#
#   ./scripts/locale-coverage.py            fill every locale
#   ./scripts/locale-coverage.py --check    exit 1 if a locale is short

import json
import pathlib
import sys

CATALOG = pathlib.Path(__file__).resolve().parent.parent / "Whisky" / "Localizable.xcstrings"

# en-GB belongs to scripts/british-english.py, which fills it from the same
# source through the spelling map rather than verbatim.
GENERATED_ELSEWHERE = {"en-GB"}


def target_locales(strings: dict) -> list[str]:
    """Every locale the catalog translates into, learned from the catalog rather
    than hardcoded so a new language needs no edit here."""
    found = set()
    for entry in strings.values():
        found.update(entry.get("localizations", {}))
    return sorted(found - {"en"} - GENERATED_ELSEWHERE)


def english(entry: dict) -> str | None:
    return entry.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value")


def entry_bounds(text: str, key: str) -> tuple[int, int]:
    """Character range of one entry's `localizations` object, braces matched by
    hand because the values contain braces of their own."""
    anchor = '    %s : {\n' % json.dumps(key, ensure_ascii=False)
    start = text.index(anchor)
    loc = text.index('"localizations" : {', start)
    depth, index = 0, text.index("{", loc)
    while True:
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text.index("\n", loc) + 1, index
        elif text[index] == '"':
            index += 1
            while text[index] != '"':
                index += 2 if text[index] == "\\" else 1
        index += 1


def render(localizations: dict) -> str:
    """The whole map, in the byte-for-byte shape Xcode writes it, so a run that
    changes nothing leaves no diff and Xcode never reformats afterwards."""
    rows = []
    for code in sorted(localizations):
        unit = localizations[code]["stringUnit"]
        rows.append('        %s : {\n'
                    '          "stringUnit" : {\n'
                    '            "state" : %s,\n'
                    '            "value" : %s\n'
                    '          }\n'
                    '        }' % (json.dumps(code),
                                   json.dumps(unit["state"]),
                                   json.dumps(unit["value"], ensure_ascii=False)))
    return ",\n".join(rows) + "\n      "


def main() -> int:
    check_only = "--check" in sys.argv
    raw = CATALOG.read_text(encoding="utf-8")
    strings = json.loads(raw)["strings"]
    locales = target_locales(strings)

    gaps: dict[str, list[str]] = {}
    unsupported: list[str] = []
    for key, entry in strings.items():
        source = english(entry)
        if source is None:
            # The key is its own source string, so a locale missing it renders
            # readable English instead of an identifier. Nothing to fill.
            continue
        localizations = entry["localizations"]
        if any(set(value) != {"stringUnit"} for value in localizations.values()):
            # Plural or device variations carry a shape this script does not
            # write. Report rather than mangle.
            unsupported.append(key)
            continue
        missing = [code for code in locales if code not in localizations]
        if missing:
            gaps[key] = missing

    for key in unsupported:
        print("skipped, not a plain string: %s" % key)

    if check_only:
        if gaps:
            rows = sum(len(missing) for missing in gaps.values())
            print("%d string(s) are missing from a translated locale, %d row(s) short, "
                  "run scripts/locale-coverage.py:" % (len(gaps), rows))
            for key in sorted(gaps)[:10]:
                print("  %s: %s" % (key, ", ".join(gaps[key])))
            return 1
        print("all %d locale(s) carry every one of the %d translated strings"
              % (len(locales), len(strings)))
        return 0 if not unsupported else 1

    for key in gaps:
        entry = strings[key]
        source = english(entry)
        for code in gaps[key]:
            entry["localizations"][code] = {"stringUnit": {"state": "needs_review", "value": source}}
        start, end = entry_bounds(raw, key)
        raw = raw[:start] + render(entry["localizations"]) + raw[end:]

    CATALOG.write_text(raw, encoding="utf-8")
    written = sum(len(missing) for missing in gaps.values())
    print("%d locale(s), %d row(s) filled from English across %d string(s)"
          % (len(locales), written, len(gaps)))
    return 1 if unsupported else 0


if __name__ == "__main__":
    sys.exit(main())
