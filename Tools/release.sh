#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Byaydenrx

# Builds, packages, signs and publishes a release that installed copies of
# Pocket pick up through their in-app updater.
#
#   Tools/release.sh 1.0.1 "What changed"
#
# Needs: the GitHub CLI signed in (gh auth login), the update signing key at
# ~/.config/pocket/update-signing.key (Tools/update-signing.swift keygen), and
# a public repository: the updater reads GitHub's public releases API.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: Tools/release.sh <version> [notes]}"
NOTES="${2:-}"
KEY="${POCKET_UPDATE_KEY:-$HOME/.config/pocket/update-signing.key}"
REPO="${POCKET_REPO:-byaydenrx/Pocket}"

[[ -f "$KEY" ]] || { echo "✗ No signing key at $KEY" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "✗ Commit your changes first." >&2; exit 1; }

echo "▸ Setting version $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Resources/Info.plist

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" ./build.sh
./Tools/make-dmg.sh
DMG="dist/Pocket-$VERSION.dmg"
swift Tools/update-signing.swift sign "$KEY" "$DMG"
# The DMG must verify against the key the app ships with, or no install will accept it.
PUBLIC_KEY="$(sed -n 's/.*updatePublicKey = "\(.*\)".*/\1/p' Sources/Pocket/Core/AppInfo.swift)"
swift Tools/update-signing.swift verify "$PUBLIC_KEY" "$DMG"

git add Resources/Info.plist
git commit -qm "Release $VERSION"
git tag "v$VERSION"
git push -q origin HEAD "v$VERSION"
gh release create "v$VERSION" "$DMG" "$DMG.sig" --repo "$REPO" --title "Pocket $VERSION" --notes "${NOTES:-Pocket $VERSION}"
echo "✓ Released $VERSION"
