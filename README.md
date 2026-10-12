# NotchNest

NotchNest makes your MacBook's notch useful. Move your pointer onto the notch and it opens up into a little hub:

| Tab | What's in it |
|---|---|
| **Nook** | What's playing (Spotify, Apple Music, YouTube…) with play/pause/skip, your Google and/or Apple Calendar (with a **+** to add Google events), and a camera mirror |
| **Tray** | A shelf for files. Drag files onto the notch, or copy a screenshot and press **⌘V**. The **Clipboard** side remembers your last 30 copies. |
| **Tasks** | Your Google Tasks and/or Apple Reminders, sorted by due date. Tick them off or add new ones. |

While it's closed, the notch shows little **live activities**: album art and lyrics while music plays, a countdown before meetings, battery when you plug in, and AirPods battery when they connect.

---

## Installing NotchNest (for friends)

It takes about 5 minutes. Follow the steps in order.

### Step 1: Check your Mac can run it

You need a Mac with an **Apple chip (M1, M2, M3, M4…)** running **macOS 14 Sonoma or newer**.

To check: click the  **Apple menu** (top-left corner) → **About This Mac**. The window should say **Chip: Apple M…** and **macOS 14** or higher.

### Step 2: Download it

1. Open the **[latest release page](https://github.com/Pranav1378/NotchNest/releases/latest)**.
2. Scroll down to **Assets** and click **`NotchNest-x.y.z.zip`** (the numbers are the version).
3. Open your **Downloads** folder. If you still see a `.zip`, double-click it. You'll get an app called **NotchNest**.

### Step 3: Move it to Applications

Drag **NotchNest** from Downloads into your **Applications** folder (in the Finder sidebar).

> ⚠️ Don't skip this. Automatic updates only work when NotchNest lives in Applications.

### Step 4: Open it for the first time

NotchNest isn't from the App Store, so macOS asks you to confirm once:

1. Open **Applications** and double-click **NotchNest**.
2. A message appears saying Apple **could not verify** NotchNest. Click **Done**. (**Not** "Move to Trash".)
3. Open **System Settings** → **Privacy & Security**.
4. Scroll down to the **Security** section. You'll see **"NotchNest" was blocked…**. Click **Open Anyway**.
5. Enter your Mac password (or use Touch ID). If asked once more, click **Open Anyway**.

You only do this once. Updates won't ask again.

### Step 5: Find it

NotchNest has **no Dock icon and no window**. It lives in the notch.

- **Move your pointer onto the notch** at the top-center of your screen, and it opens.
- **Right-click the notch** to get **Settings…** and **Quit NotchNest**.
- Double-clicking NotchNest in Applications again also opens Settings.

The Settings window opens by itself the first time.

### Step 6: Connect your calendar and tasks

Use **Google**, **Apple** (the Calendar and Reminders apps), or **both**. Each one has its own switch.

**Apple Calendar and Reminders:** in **Settings → Apple**, turn on **Show Apple Calendar events** and/or **Show Apple Reminders**, and click **OK** when macOS asks. Untick any calendars or lists you don't want in the notch.

**Google Calendar and Tasks:**

> ✅ **No invite needed.** Any Google account can sign in; nobody has to add you first.

1. In **Settings → Google**, click **Sign in with Google**. Your web browser opens.
2. Pick your Google account.
3. You'll see **"Google hasn't verified this app"**. That's expected for a small app like this one, which Google hasn't put through its review. Click **Advanced** → **Go to NotchNest (unsafe)**. NotchNest only reads your own calendar and tasks.
4. Tick the boxes to allow **Calendar** and **Tasks**, then click **Continue**.
5. The browser says **"NotchNest is connected"**. Close that tab.

Your calendar and tasks now show up in the notch. NotchNest only ever sees **your own** account, and your sign-in is stored in your Mac's Keychain. To use only part of Google, switch **Calendar** or **Tasks** off under **Settings → Google → Use Google for**.

### Step 7 (optional): Start it automatically

In **Settings → General**, turn on **Launch at login**.

---

## Permissions it might ask for

All of these are optional. Say no and that one feature just won't work.

| macOS asks… | Used for |
|---|---|
| **Location** | Showing the weather next to the battery. Prefer not to? Type your city in Settings → General → Weather. |
| **Camera** | The **Mirror** tile, only when you click it. |
| **Calendars** | Only if you turn on Apple Calendar: showing its events in the notch. |
| **Reminders** | Only if you turn on Apple Reminders: showing, ticking off and adding reminders in the Tasks tab. |
| **Keychain / "wants to use your confidential information"** | Remembering your Google sign-in. Click **Always Allow**. |
| **Accessibility** | Only for the ✦ / ✨ usage buttons: it lets NotchNest press ⌘, in Claude or Gemini and click Usage, so their usage window opens over what you're doing. Say no and the buttons open the usage page in your browser instead. |
| **Downloads folder** | Telling you when a download finishes (and optionally adding it to the Tray). Prefer not to? Turn off *Downloads* in Settings → General. |

---

## Updates

NotchNest checks for updates once a day. When there's a new version, a window says **"A new version of NotchNest is available"**. Click **Install Update** and it restarts itself in a few seconds.

To check yourself: **Settings → General → Check for Updates…**

---

## How to use it

| Do this | What happens |
|---|---|
| Point at the notch | Opens it. Move away to close it. |
| Click a tab (Nook / Tray / Tasks) | Switches view. Or **two-finger swipe left/right on the tab bar**. |
| Two-finger swipe **left/right on the player** | Next / previous song |
| Two-finger swipe **up/down on the player** | Volume |
| Click **+** next to the month | Add an event in plain English, like *"Lunch with Sam Friday 1pm"*. Press **Return** to add it. |
| Drag files onto the notch | They go in the **Tray**. Drag them back out whenever you like. |
| **⌘V** while the notch is open | Pastes a copied screenshot (or files) into the Tray |
| Click / **⌘-click** / **⇧-click** / drag a box | Selects items in the Tray, like in Finder |
| **⌘A**, **⌘C**, **Delete** | Select all, copy, remove selected (in the Tray) |
| Right-click a screenshot in the Tray → **Copy Text** | Copies the words in the picture |
| Tray → **Clipboard** | Your last 30 copies. Click one to copy it again, or **drag it out** into any app — a copied screenshot drags out as a PNG file. ✕ deletes it. |
| Click the ☁ weather / battery | Weather, battery health, CPU, memory and network speed |
| Click the sides of a live activity (or swipe on it) | Shrinks it. Click or swipe again to bring it back. |
| Click the ⏱ next to the battery | A timer (1–30 min presets or your own length) or a **Pomodoro** (25 min focus, 5 min break). The countdown stays in the notch while it's closed. |
| Click the speaker icon next to the song | Switch where sound plays: speakers, AirPods, a monitor |
| Click the battery → **Keep Awake** | **Screen on** keeps the screen awake while you work; **Lid closed** keeps the Mac running with the lid shut (macOS asks for your password, since that switches system sleep off). Pick 15m, 1h, 4h or until you turn it off. The same card shows battery health, CPU, network and your Magic Mouse / Keyboard / AirPods battery. |
| Tray → **Clipboard**: copied a link, email or colour | **Open** and **Email** buttons appear on the card; colour codes like `#ff8800` show as a swatch |
| Right-click files in the Tray → **Convert to** / **Zip** | Turns images into JPEG, PNG or HEIC, or zips the selection. The new file lands in the Tray. |
| A download finishes | The notch shows it with **Add to Tray** |
| On a call, the notch shows 🎤 / 📷 | Something is using your mic or camera. Click it to **mute your mic** (it unmutes by itself when the call ends). |
| A meeting with a video link is coming up | Click **Join** in the notch |
| Using Claude Code? | Settings → **Claude & Gemini** → **Connect**. When Claude needs permission, the notch shows **Allow / Deny**; when it finishes, the notch tells you. |
| Pick a Reminders list | In the Tasks tab, click the list name: Google Tasks lists and Reminders lists are both there |
| Check your AI usage | Click **✦** or **✨** in the notch: Claude's and Gemini's session and weekly bars appear right there. Claude's come from the Claude app's own data (it refreshes every 15 min); Gemini keeps none on your Mac, so **↻** reads them from its Usage limits screen, which flashes up for a second. Switch either button off in Settings → Claude & Gemini. |
| More than one screen | Settings → General → **Displays**: keep the notch on your MacBook, on your main monitor, or have it follow your pointer. Screens without a notch get a small black one in the menu bar. |

Every feature can be switched off in **Settings → General**.

---

## Something's not right?

| Problem | Fix |
|---|---|
| **I opened it and nothing happened** | That's normal: there's no window. Point at the notch. |
| **"NotchNest is damaged and can't be opened"** | Open **Terminal** and paste `xattr -dr com.apple.quarantine /Applications/NotchNest.app`, press Return, then open NotchNest again. |
| **"Access blocked" when signing in to Google** | Sign in with a personal Google account. Work and school accounts are often blocked by whoever manages them. |
| **Music isn't showing** | Press play in Spotify/Music. Some websites don't share the song or video name, so it shows as *"Arc media"* or *"Safari media"*. |
| **No weather** | Allow Location when asked, or type your city in Settings → General → Weather. |
| **Calendar is empty** | Sign in under Settings → Google, and make sure your calendars are ticked under *Calendars shown in the notch*. |
| **The notch won't open** | Right-click the notch → Quit, then open NotchNest from Applications again. |
| **I can't find it on my external monitor** | By default it stays on the MacBook's screen. Settings → General → Displays → *The display the pointer is on*. |
| **Claude Code still asks in the terminal** | That's expected when the terminal is already in front, or after the wait time in Settings → Claude Code. After clicking Connect, start a new Claude Code session. |

**Uninstalling:** right-click the notch → **Quit NotchNest**, then drag NotchNest from Applications to the Trash.

---

## Privacy

Everything runs on your Mac. NotchNest only talks to Google (your calendar and tasks), LRCLIB (song lyrics), Open-Meteo (weather), Apple's iTunes Search (album covers) and GitHub (update checks). Clipboard history is kept in memory only and is never saved. Anything a password manager marks as secret is skipped.

---

*Building it yourself or publishing updates? See [MAINTAINING.md](MAINTAINING.md).*
