import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var media: MediaController!
    private var auth: GoogleAuth!
    private var calendar: CalendarService!
    private var apple: AppleEventKit!
    private var tasks: TasksService!
    private var battery: BatteryMonitor!
    private var camera: CameraMirror!
    private var tray: TrayStore!
    private var clipboard: ClipboardHistory!
    private var weather: WeatherService!
    private var vm: NotchViewModel!
    private var notch: NotchController!
    private var outputWatcher: OutputDeviceWatcher?
    private var screenshotWatcher: ScreenshotWatcher?
    private var downloadWatcher: DownloadWatcher?
    private var claude: ClaudeBridge!
    private var privacy: PrivacyMonitor!
    private var keepAwake: KeepAwake!
    private var planUsage: ClaudePlanUsage!
    private var gemini: GeminiUsage!
    private var updater: Updater?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.tidyOldKeys()
        Prefs.register()
        installMainMenu()

        media = MediaController()
        auth = GoogleAuth()
        apple = AppleEventKit()
        calendar = CalendarService(auth: auth, apple: apple)
        tasks = TasksService(auth: auth, apple: apple)
        battery = BatteryMonitor()
        camera = CameraMirror()
        tray = TrayStore()
        clipboard = ClipboardHistory()
        weather = WeatherService()
        let args = CommandLine.arguments
        // Test runs listen on their own port, so they don't collide with the NotchNest you're using.
        let testing = ["--selftest", "--featuretest", "--snapshot"].contains(where: args.contains)
        claude = ClaudeBridge(port: testing ? ClaudeBridge.defaultPort + 1 : ClaudeBridge.defaultPort)
        privacy = PrivacyMonitor()
        keepAwake = KeepAwake()
        planUsage = ClaudePlanUsage()
        gemini = GeminiUsage()

        vm = NotchViewModel(media: media, calendar: calendar, battery: battery, tray: tray, camera: camera,
                            tasks: tasks, clipboard: clipboard, lyrics: LyricsService(), weather: weather,
                            stats: SystemStats(), timer: FocusTimer(), claude: claude, privacy: privacy,
                            keepAwake: keepAwake, planUsage: planUsage, gemini: gemini)
        vm.openSettings = { [weak self] in self?.showSettings() }
        UsagePages.announce = { [weak self] message in self?.vm.showToast(message) }
        gemini.announce = { [weak self] message in self?.vm.showToast(message) }
        keepAwake.announce = { [weak self] message in self?.vm.showToast(message) }

        planUsage.start()
        keepAwake.restore()  // an update shouldn't quietly let the Mac sleep
        media.start()
        battery.start()
        calendar.start()
        tasks.start()

        if let flag = args.firstIndex(of: "--snapshot"), flag + 1 < args.count {
            Snapshot.run(vm: vm, to: args[flag + 1])
            return
        }

        notch = NotchController(vm: vm)
        if args.contains("--selftest") {
            SelfTest.run(vm: vm, notch: notch)
            return
        }
        if args.contains("--featuretest") {
            FeatureTest.run(vm: vm, notch: notch)
            return
        }
        if let flag = args.firstIndex(of: "--axdump"), flag + 1 < args.count {
            let bundle = args[flag + 1]
            let items = Array(args.dropFirst(flag + 2))
            AppAutomation.dumpSettingsTree(bundleID: bundle, pressing: items) { exit(0) }
            return
        }
        if let flag = args.firstIndex(of: "--axtray"), flag + 1 < args.count {
            let bundle = args[flag + 1]
            let right = args.contains("right")
            Task { @MainActor in
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
                    print("axtray: \(bundle) isn't running")
                    exit(0)
                }
                let pid = app.processIdentifier
                await withCheckedContinuation { continuation in
                    AXSearch.queue.async {
                        let opened = AXSearch.pressMenuBarItem(pid: pid, rightClick: right)
                        print("axtray: opened=\(opened) right-click=\(right)")
                        Thread.sleep(forTimeInterval: 1.5)
                        AXSearch.dump(pid: pid)
                        continuation.resume()
                    }
                }
                exit(0)
            }
            return
        }
        if args.contains("--quietstrategies") {
            Task { @MainActor in
                await withCheckedContinuation { continuation in
                    AppAutomation.quietStrategies(bundleID: UsagePages.geminiBundle, item: "Usage limits") { notes in
                        notes.forEach { print("  •", $0) }
                        continuation.resume()
                    }
                }
                exit(0)
            }
            return
        }
        if args.contains("--quietread") {
            Task { @MainActor in
                await withCheckedContinuation { continuation in
                    AppAutomation.quietRead(bundleID: UsagePages.geminiBundle, item: "Usage limits") { lines in
                        print("quiet read got \(lines.count) lines:")
                        for line in lines.prefix(40) where line.count < 80 { print("  •", line) }
                        continuation.resume()
                    }
                }
                exit(0)
            }
            return
        }
        if args.contains("--usagetest") {
            UsagePages.announce = { print("notch says:", $0) }
            Task {
                print("--- Claude (new window → usage page)")
                await withCheckedContinuation { continuation in
                    AppAutomation.openClaudeUsageInNewWindow(bundleID: UsagePages.claudeBundle,
                                                             link: "claude://claude.ai/settings/usage") { outcome in
                        print("Claude: \(outcome.rawValue)")
                        continuation.resume()
                    }
                }
                try? await Task.sleep(for: .seconds(2))
                print("--- Gemini (read its numbers into the notch)")
                vm.gemini.refresh()
                for _ in 0..<40 where vm.gemini.isReading || vm.gemini.latest == nil {
                    try? await Task.sleep(for: .seconds(0.5))
                }
                if let reading = vm.gemini.latest {
                    print("Gemini: session \(Int(reading.session))% (\(reading.sessionResets)), week \(Int(reading.week))% (\(reading.weekResets))")
                } else {
                    print("Gemini: nothing read")
                }
                print("--- the ✨ button itself")
                vm.isOpen = true
                vm.usageCardShown = false
                UsageIconButton(kind: .gemini, claude: vm.claude, vm: vm).pressForTest()
                try? await Task.sleep(for: .seconds(1))
                print("✨: \(vm.usageCardShown ? "showed the notch card" : "opened the Gemini app")")
                vm.usageCardShown = false
                vm.isOpen = false
                exit(0)
            }
            return
        }
        if args.contains("--cameratest") {
            SelfTest.runCamera(vm: vm, notch: notch)
            return
        }
        notch.start()
        updater = Updater()

        // Started only for the real app, so test runs don't prompt for Location or touch the Tray.
        clipboard.start()
        weather.start()
        let outputWatcher = OutputDeviceWatcher()
        outputWatcher.onHeadphonesConnected = { [weak self] name in self?.vm.headphonesConnected(name) }
        outputWatcher.start()
        self.outputWatcher = outputWatcher
        let screenshotWatcher = ScreenshotWatcher { [weak self] urls in
            guard let self else { return }
            let added = self.tray.add(urls)
            if added > 0 { self.vm.showToast(added == 1 ? "Screenshot added to the Tray" : "\(added) screenshots added") }
        }
        screenshotWatcher.start()
        self.screenshotWatcher = screenshotWatcher

        claude.start()
        privacy.start()
        downloadWatcher = DownloadWatcher { [weak self] url in
            guard let self else { return }
            let auto = Prefs.bool(Prefs.autoDownloads)
            if auto { self.tray.add([url]) }
            self.vm.downloadFinished(url, inTray: auto)
        }
        updateDownloadWatcher()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDownloadWatcher() }
        }

        if !Prefs.bool(Prefs.hasLaunched) {
            UserDefaults.standard.set(true, forKey: Prefs.hasLaunched)
            showSettings()
        }
    }

    // Launching the app again while it's running opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        media?.stop()
        camera?.stop()
        privacy?.stop()  // never quit with the microphones left muted
        keepAwake?.off()
    }

    /// ~/Downloads is only watched while a Downloads setting is on (macOS asks once for access).
    private func updateDownloadWatcher() {
        guard let downloadWatcher else { return }
        let wanted = Prefs.bool(Prefs.downloadActivity) || Prefs.bool(Prefs.autoDownloads)
        if wanted && !downloadWatcher.isRunning { downloadWatcher.start() }
        if !wanted && downloadWatcher.isRunning { downloadWatcher.stop() }
    }

    func showSettings() {
        ActivityLog.note("settings opened")
        vm?.close()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(auth: auth, calendar: calendar, weather: weather, updater: updater,
                                       claude: claude, apple: apple, tasks: tasks)))
            window.title = "NotchNest"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            // Show up on the Space you're looking at, not the one it was first opened on.
            window.collectionBehavior = [.moveToActiveSpace]
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    /// Agent apps have no visible menu bar, but key equivalents (⌘V, ⌘W, ⌘Q) are still
    /// routed through the main menu, so install a minimal one.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit NotchNest", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
