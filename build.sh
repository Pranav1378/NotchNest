#!/bin/bash
# Builds NotchNest.app (an agent app that lives in the notch) into ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/NotchNest.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/NotchNest "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
# Reuse LidLiquid's stable local identity so the Camera grant and Keychain access
# survive rebuilds; fall back to ad-hoc signing if the certificate isn't there.
if security find-certificate -c "LidLiquid Dev" >/dev/null 2>&1; then
    codesign --force --sign "LidLiquid Dev" "$APP"
else
    codesign --force --sign - "$APP"
fi

echo "Built $APP"
