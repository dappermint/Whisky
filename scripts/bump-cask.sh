#!/bin/bash
#
# bump-cask.sh
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
# Points dappermint/homebrew-tap's whisky-preview cask at a published app release.
# Run from CI with BREW_TOKEN set, or locally using the gh CLI's own credentials.
#
# Usage: scripts/bump-cask.sh <version> [sha256]
#   scripts/bump-cask.sh 2026.8.1
#   scripts/bump-cask.sh 2026.8.1 2b9fb057...   # skip the download

set -euo pipefail

VERSION="${1:?usage: scripts/bump-cask.sh <version> [sha256]}"
SHA="${2:-}"
REPO="dappermint/Whisky"
TAP="dappermint/homebrew-tap"
CASK="Casks/whisky-preview.rb"

if ! printf '%s' "$VERSION" | grep -qE '^[0-9]+(\.[0-9]+)*$'; then
    echo "not a dotted numeric version: $VERSION" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -z "$SHA" ]; then
    url="https://github.com/${REPO}/releases/download/app-v${VERSION}/Whisky-Preview-${VERSION}.dmg"
    echo "==> Downloading $url"
    curl -fSL "$url" -o "$WORK/whisky-preview.dmg"
    SHA="$(shasum -a 256 "$WORK/whisky-preview.dmg" | awk '{print $1}')"
fi
echo "==> version ${VERSION}, sha256 ${SHA}"

if [ -n "${BREW_TOKEN:-}" ]; then
    git clone --depth 1 "https://x-access-token:${BREW_TOKEN}@github.com/${TAP}.git" "$WORK/tap"
else
    gh repo clone "$TAP" "$WORK/tap" -- --depth 1
fi
cd "$WORK/tap"

sed -i.bak -E "s/^  version \"[^\"]+\"/  version \"${VERSION}\"/" "$CASK"
sed -i.bak -E "s/^  sha256 \"[^\"]+\"/  sha256 \"${SHA}\"/" "$CASK"
rm -f "$CASK.bak"

# sed exits 0 even when nothing matched, so assert both landed. A partial match
# would push the new version carrying a stale hash and break every install while
# looking successful.
grep -qF "  version \"${VERSION}\"" "$CASK" || { echo "version line not updated" >&2; exit 1; }
grep -qF "  sha256 \"${SHA}\"" "$CASK" || { echo "sha256 line not updated" >&2; exit 1; }

if git diff --quiet; then
    echo "==> Cask already at ${VERSION}; nothing to do."
    exit 0
fi

# Only claim the bot identity in CI; locally, commit as whoever is running this.
# GitHub rejects pushes carrying a private email, so both must be noreply forms.
if [ -n "${BREW_TOKEN:-}" ]; then
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
fi
git commit -qam "whisky-preview ${VERSION}"
git push -q
echo "==> Tap updated to whisky-preview ${VERSION}."
