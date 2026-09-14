import Foundation
import UniformTypeIdentifiers

/// Adds new screenshots to the Tray as soon as macOS saves them (when the setting is on).
@MainActor
final class ScreenshotWatcher {
    private let onNew: ([URL]) -> Void
    private let directory: URL
    private var source: DispatchSourceFileSystemObject?
    private var seen: Set<String> = []

    init(onNew: @escaping ([URL]) -> Void) {
        self.onNew = onNew
        directory = Self.screenshotFolder()
    }

    /// Where screenshots are saved: the Desktop unless changed in the Screenshot app's options.
    static func screenshotFolder() -> URL {
        let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let path = custom.map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory() + "/Desktop"
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func start() {
        seen = Set(currentFiles().map(\.path))  // what's already there isn't new
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            ActivityLog.note("screenshots: can't watch \(directory.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            // macOS writes a hidden temporary file first and renames it; give that a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated { self?.collect() }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func collect() {
        let fresh = currentFiles().filter { !seen.contains($0.path) }
        fresh.forEach { seen.insert($0.path) }
        guard Prefs.bool(Prefs.autoScreenshots) else { return }
        let shots = fresh.filter(Self.isScreenshot)
        if !shots.isEmpty {
            ActivityLog.note("screenshots: adding \(shots.count) to the tray")
            onNew(shots)
        }
    }

    private func currentFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles])) ?? []
    }

    /// macOS tags screenshots with a Spotlight attribute; the file name is a fallback.
    static func isScreenshot(_ url: URL) -> Bool {
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return false }
        if getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0 { return true }
        let name = url.lastPathComponent
        return name.hasPrefix("Screenshot") || name.hasPrefix("Screen Shot")
    }
}
