import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let auth: GoogleAuth
    let calendar: CalendarService
    let weather: WeatherService
    let updater: Updater?
    let claude: ClaudeBridge

    var body: some View {
        TabView {
            GoogleSettings(auth: auth, calendar: calendar)
                .tabItem { Label("Google", systemImage: "person.crop.circle") }
            GeneralSettings(weather: weather, updater: updater)
                .tabItem { Label("General", systemImage: "gearshape") }
            ClaudeSettings(claude: claude)
                .tabItem { Label("Claude Code", systemImage: "sparkle") }
        }
        .frame(width: 560, height: 620)
    }
}

struct GeneralSettings: View {
    let weather: WeatherService
    let updater: Updater?
    @AppStorage(Prefs.openOnHover) private var openOnHover = true
    @AppStorage(Prefs.haptics) private var haptics = true
    @AppStorage(Prefs.swipeTracks) private var swipes = true
    @AppStorage(Prefs.musicActivity) private var musicActivity = true
    @AppStorage(Prefs.lyrics) private var lyrics = true
    @AppStorage(Prefs.eventActivity) private var eventActivity = true
    @AppStorage(Prefs.chargingActivity) private var chargingActivity = true
    @AppStorage(Prefs.headphonesActivity) private var headphonesActivity = true
    @AppStorage(Prefs.autoScreenshots) private var autoScreenshots = true
    @AppStorage(Prefs.clipboardHistory) private var clipboardHistory = true
    @AppStorage(Prefs.weather) private var weatherEnabled = true
    @AppStorage(Prefs.weatherCity) private var weatherCity = ""
    @AppStorage(Prefs.displayMode) private var displayMode = DisplayMode.notch.rawValue
    @AppStorage(Prefs.timerActivity) private var timerActivity = true
    @AppStorage(Prefs.timerSound) private var timerSound = true
    @AppStorage(Prefs.pomodoroFocus) private var pomodoroFocus = 25
    @AppStorage(Prefs.pomodoroBreak) private var pomodoroBreak = 5
    @AppStorage(Prefs.pomodoroAuto) private var pomodoroAuto = true
    @AppStorage(Prefs.privacyActivity) private var privacyActivity = true
    @AppStorage(Prefs.downloadActivity) private var downloadActivity = true
    @AppStorage(Prefs.autoDownloads) private var autoDownloads = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var autoUpdates = true

    var body: some View {
        Form {
            Section("Notch") {
                Toggle("Open when the pointer touches the notch", isOn: $openOnHover)
                Text("When off, click the notch to open it.").font(.caption).foregroundStyle(.secondary)
                Toggle("Haptic feedback", isOn: $haptics)
                Toggle("Two-finger swipes", isOn: $swipes)
                Text("On the player: left/right changes the track, up/down the volume. On the tab bar: left/right switches tabs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Displays") {
                Picker("Show the notch on", selection: $displayMode) {
                    ForEach(DisplayMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Text("On a screen without a notch (an external monitor, an M1 MacBook Air, or with the lid closed), NotchNest draws a small black notch in the middle of the menu bar. Hover over it the same way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Live activities (while the notch is closed)") {
                Toggle("Now playing: artwork and waveform", isOn: $musicActivity)
                Toggle("Lyrics under the notch while a song plays", isOn: $lyrics)
                    .disabled(!musicActivity)
                Toggle("Upcoming meeting: 10-minute countdown", isOn: $eventActivity)
                Toggle("Charging: shown when you plug in", isOn: $chargingActivity)
                Toggle("AirPods and headphones: battery when they connect", isOn: $headphonesActivity)
                Toggle("Timer countdown", isOn: $timerActivity)
                Toggle("Camera and microphone in use (click it to mute your mic)", isOn: $privacyActivity)
                Toggle("Downloads: shown when one finishes", isOn: $downloadActivity)
                Text("Click the sides of a live activity, or swipe on it, to shrink it. Click or swipe the small version to bring it back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Tray") {
                Toggle("Add new screenshots to the Tray automatically", isOn: $autoScreenshots)
                Toggle("Add finished downloads to the Tray automatically", isOn: $autoDownloads)
                Toggle("Keep clipboard history", isOn: $clipboardHistory)
                Text("The last 30 things you copy, under Tray → Clipboard. Kept in memory only, never saved to disk; passwords from password managers are skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Timer") {
                Stepper("Pomodoro focus: \(pomodoroFocus) min", value: $pomodoroFocus, in: 5...90, step: 5)
                Stepper("Pomodoro break: \(pomodoroBreak) min", value: $pomodoroBreak, in: 1...30)
                Toggle("Start the next focus or break automatically", isOn: $pomodoroAuto)
                Toggle("Play a sound when time's up", isOn: $timerSound)
            }
            Section("Weather") {
                Toggle("Show the weather next to the battery", isOn: $weatherEnabled)
                    .onChange(of: weatherEnabled) { _, _ in weather.refresh() }
                TextField("City", text: $weatherCity, prompt: Text("Leave empty to use your location"))
                    .onSubmit { weather.refresh() }
                    .disabled(!weatherEnabled)
                if weatherEnabled, let problem = weather.problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let updater {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $autoUpdates)
                        .onChange(of: autoUpdates) { _, enabled in updater.automaticallyChecks = enabled }
                    HStack {
                        Text("NotchNest \(Updater.currentVersion)").foregroundStyle(.secondary)
                        Spacer()
                        Button("Check for Updates…") { updater.checkForUpdates() }
                    }
                }
                .onAppear { autoUpdates = updater.automaticallyChecks }
            }
            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Button("Quit NotchNest") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
    }
}

/// Connects Claude Code: two hooks in ~/.claude/settings.json send its permission questions and
/// "finished" moments to the notch.
struct ClaudeSettings: View {
    let claude: ClaudeBridge
    @AppStorage(Prefs.claudeAlerts) private var enabled = true
    @AppStorage(Prefs.claudeWait) private var wait = 60
    @State private var installed = ClaudeHooks.isInstalled()
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show Claude Code in the notch", isOn: $enabled)
                Text("When Claude Code needs permission to run something, the notch shows what it wants to do with Allow and Deny. When it finishes, the notch tells you; click it to jump back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Connect Claude Code") {
                HStack {
                    Label(installed ? "Connected" : "Not connected",
                          systemImage: installed ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(installed ? Color.green : Color.secondary)
                    Spacer()
                    if installed {
                        Button("Disconnect") { run { try ClaudeHooks.uninstall() } }
                    } else {
                        Button("Connect") { run { try ClaudeHooks.install(port: claude.port) } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Text("Adds two small hooks to ~/.claude/settings.json (a copy of the original is kept next to it as settings.json.notchnest-backup). Claude Code sessions you start afterwards use them. If NotchNest isn't running, Claude Code just asks in the terminal as usual.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message { Text(message).font(.caption).foregroundStyle(.red) }
                if let problem = claude.problem { Text(problem).font(.caption).foregroundStyle(.red) }
            }
            Section("Answering") {
                Stepper("Wait for an answer in the notch: \(wait) s", value: $wait, in: 15...300, step: 15)
                Text("After that, or if you click Terminal, Claude Code asks in its own window instead. If the app Claude Code runs in is already in front, the notch stays out of the way and you answer there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { installed = ClaudeHooks.isInstalled() }
    }

    private func run(_ change: () throws -> Void) {
        do {
            try change()
            message = nil
        } catch {
            message = "Couldn't update ~/.claude/settings.json: \(error.localizedDescription)"
        }
        installed = ClaudeHooks.isInstalled()
    }
}

struct GoogleSettings: View {
    @Bindable var auth: GoogleAuth
    let calendar: CalendarService

    var body: some View {
        Form {
            if auth.isSignedIn { signedIn } else { setup }
        }
        .formStyle(.grouped)
    }

    /// Features that need a permission the current sign-in doesn't have yet.
    private var missingFeatures: [String] {
        var missing: [String] = []
        if !auth.hasScope(CalendarService.writeScope) { missing.append("adding events") }
        if !auth.hasScope(TasksService.scope) { missing.append("Google Tasks") }
        return missing
    }

    @ViewBuilder private var signedIn: some View {
        Section("Account") {
            LabeledContent("Signed in as", value: auth.accountEmail ?? "Google account")
            if let updated = calendar.lastUpdated {
                LabeledContent("Calendar synced", value: updated.formatted(date: .omitted, time: .shortened))
            }
            if let error = calendar.lastError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("Sync now") { Task { await calendar.refresh() } }
                    .disabled(calendar.isLoading)
                Spacer()
                Button("Sign out", role: .destructive) { auth.signOut() }
            }
            if !missingFeatures.isEmpty {
                let list = missingFeatures.joined(separator: " and ")
                Text("\(list.prefix(1).uppercased() + list.dropFirst()) need\(missingFeatures.count == 1 ? "s" : "") one more sign-in. If Tasks is missing and you use your own Google client, turn on the Google Tasks API in your Cloud project first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Link("Enable Tasks API ↗", destination: URL(string: "https://console.cloud.google.com/apis/library/tasks.googleapis.com")!)
                    Spacer()
                    Button(auth.isSigningIn ? "Waiting for your browser…" : "Sign in again") { Task { await auth.signIn() } }
                        .disabled(auth.isSigningIn)
                }
            }
        }
        Section("Calendars shown in the notch") {
            if calendar.calendars.isEmpty {
                Text(calendar.isLoading ? "Loading…" : "No calendars found.").foregroundStyle(.secondary)
            }
            ForEach(calendar.calendars) { cal in
                Toggle(isOn: Binding(get: { calendar.isEnabled(cal) }, set: { calendar.setEnabled(cal, $0) })) {
                    HStack(spacing: 8) {
                        Circle().fill(cal.color).frame(width: 10, height: 10)
                        Text(cal.name)
                    }
                }
            }
        }
    }

    /// With a client built into the app, signing in is one button; the Google Cloud setup is only
    /// needed by people who'd rather use their own client.
    @ViewBuilder private var setup: some View {
        if GoogleAuth.hasBuiltInClient {
            Section {
                signInRow
                Text("You sign in with your own Google account, and NotchNest only sees your own calendar and tasks. Tokens stay in your Mac's Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("Use your own Google Cloud client instead") {
                    cloudSteps
                    credentialFields
                }
            }
        } else {
            Section("1 · Create your Google OAuth client (one time, about 5 minutes)") {
                cloudSteps
                Text("While the app is in \"Testing\", Google makes you sign in again every 7 days. To avoid that, choose Audience → Publish app. It stays private to you; Google just shows an \"unverified app\" warning the first time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("2 · Paste the credentials") { credentialFields }
            Section {
                signInRow
                Text("NotchNest asks to read your calendar, add events you type in the notch, and manage your Google Tasks. Tokens stay in your Mac's Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var signInRow: some View {
        HStack {
            Button(auth.isSigningIn ? "Waiting for your browser…" : "Sign in with Google") {
                Task { await auth.signIn() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(auth.isSigningIn)
            if auth.isSigningIn { Button("Cancel") { auth.cancelSignIn() } }
        }
        if let message = auth.statusMessage {
            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    @ViewBuilder private var credentialFields: some View {
        TextField("Client ID", text: $auth.clientID, prompt: Text("1234-abc.apps.googleusercontent.com"))
        SecureField("Client secret", text: $auth.clientSecret, prompt: Text("GOCSPX-…"))
    }

    private var cloudSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            step(0, "Turn on 2-Step Verification for your Google account. Google Cloud won't open without it (it can take a few minutes to kick in).",
                 link: "https://myaccount.google.com/signinoptions/two-step-verification")
            step(1, "Open Google Cloud Console and create a project (any name).",
                 link: "https://console.cloud.google.com/projectcreate")
            step(2, "Enable the Google Calendar API for that project.",
                 link: "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com")
            step(3, "Enable the Google Tasks API for that project too.",
                 link: "https://console.cloud.google.com/apis/library/tasks.googleapis.com")
            step(4, "Google Auth Platform → Get started: app name \"NotchNest\", audience External, your email as contact.",
                 link: "https://console.cloud.google.com/auth/overview")
            step(5, "Audience → Test users → add your own Gmail address.",
                 link: "https://console.cloud.google.com/auth/audience")
            step(6, "Clients → Create client → Application type \"Desktop app\". Copy the Client ID and Client secret.",
                 link: "https://console.cloud.google.com/auth/clients")
        }
        .padding(.vertical, 4)
    }

    private func step(_ number: Int, _ text: String, link: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                Link("Open ↗", destination: URL(string: link)!).font(.caption)
            }
        }
    }
}
