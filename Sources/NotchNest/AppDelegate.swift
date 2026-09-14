import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var media: MediaController!
    private var auth: GoogleAuth!
    private var calendar: CalendarService!
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
    private var updater: Updater?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        installMainMenu()

        media = MediaController()
        auth = GoogleAuth()
        calendar = CalendarService(auth: auth)
        tasks = TasksService(auth: auth)
        battery = BatteryMonitor()
        camera = CameraMirror()
        tray = TrayStore()
        clipboard = ClipboardHistory()
        weather = WeatherService()

        vm = NotchViewModel(media: media, calendar: calendar, battery: battery, tray: tray, camera: camera,
                            tasks: tasks, clipboard: clipboard, lyrics: LyricsService(), weather: weather,
                            stats: SystemStats())
        vm.openSettings = { [weak self] in self?.showSettings() }

        media.start()
        battery.start()
        calendar.start()
        tasks.start()

        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--snapshot"), flag + 1 < args.count {
            Snapshot.run(vm: vm, to: args[flag + 1])
            return
        }

        notch = NotchController(vm: vm)
        if args.contains("--selftest") {
            SelfTest.run(vm: vm, notch: notch)
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
    }

    func showSettings() {
        ActivityLog.note("settings opened")
        vm?.close()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(auth: auth, calendar: calendar, weather: weather, updater: updater)))
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
