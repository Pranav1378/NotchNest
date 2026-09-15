import Foundation

/// What the notch did, for debugging: ~/Library/Application Support/NotchNest/activity.log
/// (a plain file, because the unified log isn't readable from every shell).
enum ActivityLog {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchNest", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("activity.log")
        // Start fresh once it gets big.
        if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size > 512_000 {
            try? FileManager.default.removeItem(at: file)
        }
        return file
    }()

    static func note(_ message: String) {
        let data = Data("\(Date().formatted(date: .omitted, time: .standard))  \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// UserDefaults keys shared by the notch and the Settings window.
enum Prefs {
    static let openOnHover = "openOnHover"
    static let haptics = "haptics"
    static let swipeTracks = "swipeTracks"
    static let musicActivity = "musicActivity"
    static let eventActivity = "eventActivity"
    static let chargingActivity = "chargingActivity"
    static let googleClientID = "googleClientID"
    static let googleEmail = "googleEmail"
    static let calendarOverrides = "calendarOverrides"
    static let googleScopes = "googleScopes"
    static let googleSignedIn = "googleSignedIn"
    static let tasksList = "tasksList"
    static let tasksSort = "tasksSort"
    static let lyrics = "lyrics"
    static let headphonesActivity = "headphonesActivity"
    static let autoScreenshots = "autoScreenshots"
    static let clipboardHistory = "clipboardHistory"
    static let weather = "weather"
    static let weatherCity = "weatherCity"
    static let trayItems = "trayItems"
    static let lastTab = "lastTab"
    static let hasLaunched = "hasLaunched"
    static let displayMode = "displayMode"
    static let timerActivity = "timerActivity"
    static let timerSound = "timerSound"
    static let pomodoroFocus = "pomodoroFocus"
    static let pomodoroBreak = "pomodoroBreak"
    static let pomodoroAuto = "pomodoroAuto"
    static let privacyActivity = "privacyActivity"
    static let downloadActivity = "downloadActivity"
    static let autoDownloads = "autoDownloads"
    static let claudeAlerts = "claudeAlerts"
    static let claudeWait = "claudeWait"

    static func register() {
        UserDefaults.standard.register(defaults: [
            openOnHover: true, haptics: true, swipeTracks: true,
            musicActivity: true, eventActivity: true, chargingActivity: true,
            lyrics: true, headphonesActivity: true, autoScreenshots: true, clipboardHistory: true, weather: true,
            displayMode: DisplayMode.notch.rawValue,
            timerActivity: true, timerSound: true, pomodoroFocus: 25, pomodoroBreak: 5, pomodoroAuto: true,
            privacyActivity: true, downloadActivity: true, autoDownloads: false,
            claudeAlerts: true, claudeWait: 60,
        ])
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func int(_ key: String) -> Int { UserDefaults.standard.integer(forKey: key) }
}
