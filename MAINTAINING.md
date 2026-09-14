# Maintaining NotchNest

Notes for building NotchNest and publishing updates.

## Build and run

Only the Xcode Command Line Tools are needed (no Xcode):

```bash
./build.sh
open build/NotchNest.app
```

`swift build` downloads [Sparkle](https://sparkle-project.org) (the updater) the first time. The app is signed with the local **"LidLiquid Dev"** certificate when it's in your Keychain, and ad-hoc otherwise.

Debug helpers:
- `build/NotchNest.app/Contents/MacOS/NotchNest --selftest` feeds the notch synthetic clicks and drags and checks the results.
- `… --snapshot <dir>` renders the notch's states to PNGs.
- `~/Library/Application Support/NotchNest/activity.log` records what the notch did.

## Publishing an update

```bash
./release.sh 0.2.0 "Lyrics timing fix, new weather card"
```

This:
1. bumps the version and build number
2. builds and signs the app
3. zips it and signs the zip with your Sparkle key
4. writes `appcast.xml`
5. commits, tags `v0.2.0`, pushes
6. creates a GitHub release with the zip and appcast attached

Installed copies read `https://github.com/Pranav1378/NotchNest/releases/latest/download/appcast.xml` and offer the update within a day.

Before running it you need:
- a clean git tree
- the GitHub CLI signed in (`gh auth status`)
- the Sparkle key in your Keychain (see below)

## The Sparkle signing key: back it up!

Updates are signed with a private EdDSA key that `generate_keys` saved in your **login Keychain** (item: *Private key for signing Sparkle updates*). The matching public key is `SUPublicEDKey` in `Info.plist`.

**If you lose this key, installed copies can never update again.** Friends would have to download a new version by hand. Back it up somewhere safe, like a password manager:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/Desktop/sparkle-private-key.txt
```

Store that file somewhere private, then delete it from the Desktop. Never commit it; `*.key` and this file don't belong in the repo.

## Google sign-in for friends

Release builds can carry a Google OAuth client so friends only click **Sign in with Google**.

1. In [Google Cloud Console](https://console.cloud.google.com/projectcreate), create a **separate** project, e.g. *NotchNest Public*, so your own setup is unaffected. If it's ever misused you can delete it and make a new one.
2. Enable the **Google Calendar API** and the **Google Tasks API** in it.
3. Google Auth Platform → **Get started**:
   - App name: NotchNest.
   - Audience: External.
   - Support email: one you're happy for friends to see on the sign-in screen.
4. **Clients → Create client → Desktop app.** Copy the Client ID and secret.
5. Copy `Config/GoogleClient.plist.example` to `Config/GoogleClient.plist` and paste them in. That file is git-ignored.
6. Give friends access, either:
   - **Audience → Test users**: add each friend's Gmail (up to 100). They must sign in again every 7 days while the app is in Testing.
   - **Audience → Publish app**: anyone can sign in after clicking through Google's "unverified app" warning (up to 100 users until Google verifies the app).

`build.sh` bakes the client into the app when `Config/GoogleClient.plist` exists. A client entered in Settings always takes priority, so your own setup keeps working. Anyone who unzips the app could extract the built-in client: that's true of every desktop app. It only identifies the app, though. Each person still signs in with their own account and sees only their own data.

## Where things live

| | |
|---|---|
| `Sources/NotchNest/` | The app (SwiftUI + AppKit) |
| `Info.plist` | Bundle info, Sparkle feed and public key |
| `build.sh` / `release.sh` | Build / publish |
| `Config/GoogleClient.plist` | Your built-in Google client (git-ignored) |
