import AppKit
import Sparkle

/// Over-the-air updates with Sparkle. Once a day it reads the appcast attached to the latest
/// GitHub release, and offers to download, verify (EdDSA signature) and install new versions.
@MainActor
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // NotchNest has no Dock icon, so Sparkle asks background apps to handle scheduled update
    // alerts gently. Bringing the app forward is enough for its update window to be seen.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                  state: SPUUserUpdateState) {
        ActivityLog.note("update available: \(update.displayVersionString)")
        NSApp.activate(ignoringOtherApps: true)
    }
}
