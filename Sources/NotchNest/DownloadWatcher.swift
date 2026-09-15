import Foundation

/// Notices when a download lands in ~/Downloads: a new file, not a browser's partial one, that has
/// stopped growing and carries the "downloaded from" tag browsers add.
@MainActor
final class DownloadWatcher {
    private let onFinished: (URL) -> Void
    private let directory: URL
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private var checking: Set<String> = []

    init(directory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
         onFinished: @escaping (URL) -> Void) {
        self.directory = directory
        self.onFinished = onFinished
    }

    var isRunning: Bool { source != nil }

    func start() {
        guard source == nil else { return }
        known = names()  // what's already there isn't new
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            ActivityLog.note("downloads: can't watch \(directory.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.collect() }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func collect() {
        let current = names()
        let fresh = current.subtracting(known)
        known = current
        for name in fresh where !Self.isPartial(name) && !checking.contains(name) {
            checking.insert(name)
            settle(directory.appendingPathComponent(name), lastSize: nil, tries: 0)
        }
    }

    /// A finished download stops growing: wait until two looks agree on its size.
    private func settle(_ url: URL, lastSize: Int64?, tries: Int) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        guard let size else {
            checking.remove(url.lastPathComponent)  // gone (renamed or deleted)
            return
        }
        if size == lastSize || tries >= 20 {
            checking.remove(url.lastPathComponent)
            if Self.wasDownloaded(url) {
                ActivityLog.note("download finished: \(url.lastPathComponent)")
                onFinished(url)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated { self?.settle(url, lastSize: size, tries: tries + 1) }
        }
    }

    private func names() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    /// Safari's .download bundles, Chrome/Edge/Arc's .crdownload, Firefox's .part, hidden temp files.
    static func isPartial(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["download", "crdownload", "part", "partial", "opdownload", "tmp"].contains(ext)
    }

    /// Browsers tag what they save with where it came from; files you move in yourself aren't tagged.
    static func wasDownloaded(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemWhereFroms", nil, 0, 0, 0) >= 0
            || getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }
}
