#!/bin/bash
# Publishes a new version to GitHub releases, where installed copies of NotchNest find it.
#
#   ./release.sh 0.2.0 "What's new in this version"
#
# Needs: a clean git tree, the GitHub CLI signed in (gh auth login), and the Sparkle signing key
# in your Keychain (created once with .build/artifacts/sparkle/Sparkle/bin/generate_keys).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version> [release notes]}"
NOTES="${2:-NotchNest $VERSION}"
REPO="Pranav1378/NotchNest"
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin

[ -z "$(git status --porcelain)" ] || { echo "Commit or stash your changes first."; exit 1; }
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then echo "v$VERSION already exists."; exit 1; fi

# Sparkle decides "newer" from the build number, so it always goes up by one.
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" Info.plist

./build.sh
mkdir -p build/releases
ZIP="build/releases/NotchNest-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/NotchNest.app "$ZIP"

# Signs the zip with the private EdDSA key in your Keychain; prints sparkle:edSignature="…" length="…"
SIGNATURE=$("$SPARKLE_BIN/sign_update" "$ZIP")
URL="https://github.com/$REPO/releases/download/v$VERSION/NotchNest-$VERSION.zip"
cat > build/releases/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>NotchNest</title>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES]]></description>
      <enclosure url="$URL" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
EOF

git add Info.plist
git commit -q -m "Release $VERSION" ${RELEASE_TRAILER:+--trailer "$RELEASE_TRAILER"}
git tag "v$VERSION"
git push -q origin main "v$VERSION"
gh release create "v$VERSION" "$ZIP" build/releases/appcast.xml --repo "$REPO" \
    --title "NotchNest $VERSION" --notes "$NOTES"

echo "Published v$VERSION. Installed copies will offer it within a day, or right away via Check for Updates…"
