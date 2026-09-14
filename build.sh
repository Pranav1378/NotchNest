#!/bin/bash
# Builds NotchNest.app (an agent app that lives in the notch) into ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/NotchNest.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp .build/release/NotchNest "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
# Sparkle (over-the-air updates) keeps its own signature from the Sparkle project.
ditto .build/release/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"

# An optional Google OAuth client for release builds, so people can just "Sign in with Google".
# Config/GoogleClient.plist is git-ignored: it never goes to GitHub.
if [ -f Config/GoogleClient.plist ]; then
    PB=/usr/libexec/PlistBuddy
    "$PB" -c "Add :NNGoogleClientID string $("$PB" -c 'Print :ClientID' Config/GoogleClient.plist)" \
          -c "Add :NNGoogleClientSecret string $("$PB" -c 'Print :ClientSecret' Config/GoogleClient.plist)" \
          "$APP/Contents/Info.plist"
    echo "Built-in Google client: included"
fi

# Sign with a stable local identity so Camera/Location grants and Keychain access survive
# rebuilds and updates; fall back to ad-hoc signing if the certificate isn't there.
if security find-certificate -c "LidLiquid Dev" >/dev/null 2>&1; then
    codesign --force --sign "LidLiquid Dev" "$APP"
else
    codesign --force --sign - "$APP"
fi

echo "Built $APP"
