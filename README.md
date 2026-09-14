# NotchNest

A home for your MacBook's notch, inspired by NotchNook. Hover the notch and it opens into:

- **Nook**: what's playing (Spotify, Music, browser video) with controls, your Google Calendar with a quick-add **+**, and a camera mirror
- **Tray**: a shelf for files. Drop or paste (⌘V) things in, select several, drag them out, AirDrop them, or copy the text out of screenshots. The **Clipboard** side keeps your last 30 copies.
- **Tasks**: your Google Tasks, sorted by date

While it's closed, the notch shows **live activities** such as music with lyrics, charging, AirPods battery and upcoming meetings. Click or swipe one to shrink it.

## Install

1. Download the latest `NotchNest-x.y.z.zip` from [Releases](https://github.com/Pranav1378/NotchNest/releases/latest) and unzip it.
2. Drag **NotchNest** into your **Applications** folder.
3. Open it. macOS will block it the first time because it isn't signed by a registered Apple developer. Go to **System Settings → Privacy & Security** and click **Open Anyway**.
4. Open Settings (right-click the notch → Settings…) and **Sign in with Google** for Calendar and Tasks.

Requires an Apple Silicon Mac on macOS 14 or later.

NotchNest checks for updates on its own and offers to install new versions. You can also use Settings → General → **Check for Updates…**.

## Build from source

Only the Xcode Command Line Tools are needed:

```bash
./build.sh            # builds build/NotchNest.app
open build/NotchNest.app
```

Google sign-in needs an OAuth client. Either paste your own in Settings (the app walks you through Google Cloud setup), or put one in `Config/GoogleClient.plist` (git-ignored) so it's built into the app:

```xml
<plist version="1.0"><dict>
    <key>ClientID</key><string>1234-abc.apps.googleusercontent.com</string>
    <key>ClientSecret</key><string>GOCSPX-…</string>
</dict></plist>
```

## Releasing an update

```bash
./release.sh 0.2.0 "What's new in this version"
```

This builds and signs the app, zips it, signs the zip for Sparkle, writes `appcast.xml`, tags the commit and publishes a GitHub release. Installed copies pick it up from `releases/latest/download/appcast.xml`.

## Privacy

Everything runs on your Mac. Google tokens are stored in the Keychain. Clipboard history is kept in memory only, and anything a password manager marks as concealed is skipped. Nothing is sent anywhere except Google (Calendar and Tasks), LRCLIB (lyrics), Open-Meteo (weather) and iTunes Search (album art).
