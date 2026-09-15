import AppKit

struct TrayItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var path: String
    var url: URL { URL(fileURLWithPath: path) }
}

/// Files parked in the notch. Items point at the original file, except temporary files
/// (e.g. a screenshot dragged from its thumbnail), which are copied so they don't vanish.
@Observable @MainActor
final class TrayStore {
    private(set) var items: [TrayItem] = []
    private(set) var selection: Set<UUID> = []
    @ObservationIgnored private var anchor: UUID?
    /// Shows a short confirmation in the notch (wired to `NotchViewModel.showToast`).
    @ObservationIgnored var announce: (String) -> Void = { _ in }

    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchNest/Tray", isDirectory: true)

    init() {
        if let data = UserDefaults.standard.data(forKey: Prefs.trayItems),
           let saved = try? JSONDecoder().decode([TrayItem].self, from: data) {
            items = saved.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    var selectedItems: [TrayItem] { items.filter { selection.contains($0.id) } }

    /// Returns how many of the files were new to the Tray.
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls where url.isFileURL {
            let stable = Self.keepable(url)
            if !items.contains(where: { $0.path == stable.path }) {
                items.append(TrayItem(path: stable.path))
                added += 1
            }
        }
        ActivityLog.note("tray add: \(added) of \(urls.count) file(s)")
        save()
        return added
    }

    /// Adds what's on the clipboard: copied files as they are, or an image (e.g. a screenshot
    /// taken with ⌃⇧⌘4) saved as a PNG in the Tray folder. Returns how many items were added.
    @discardableResult
    func paste(from pasteboard: NSPasteboard = .general) -> Int {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return add(urls)
        }
        guard let png = Self.pngData(from: pasteboard) else {
            ActivityLog.note("paste: nothing usable on the clipboard \((pasteboard.types ?? []).prefix(4).map(\.rawValue))")
            return 0
        }
        return addImage(png)
    }

    /// Saves image data (PNG or TIFF) as a PNG file in the Tray folder and adds it.
    @discardableResult
    func addImage(_ data: Data) -> Int {
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        guard let png = isPNG ? data : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
            return 0
        }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let name = "Screenshot \(Self.stamp.string(from: Date()))"
        var destination = Self.folder.appendingPathComponent("\(name).png")
        var copy = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = Self.folder.appendingPathComponent("\(name) (\(copy)).png")
            copy += 1
        }
        do {
            try png.write(to: destination)
            return add([destination])
        } catch {
            ActivityLog.note("paste: couldn't save the image: \(error.localizedDescription)")
            return 0
        }
    }

    /// Reads the text in the chosen images/PDFs (on-device) and puts it on the clipboard.
    func copyText(from chosen: [TrayItem]) {
        let readable = chosen.filter { TextRecognizer.canRead($0.url) }
        guard !readable.isEmpty else {
            announce("Only images and PDFs have text to copy")
            return
        }
        announce("Reading text…")
        Task {
            var parts: [String] = []
            for item in readable {
                if let text = await TextRecognizer.text(in: item.url) { parts.append(text) }
            }
            guard !parts.isEmpty else {
                announce("No text found")
                return
            }
            let text = parts.joined(separator: "\n\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            ActivityLog.note("copied \(text.count) characters of text from \(readable.count) file(s)")
            announce("Copied text (\(text.count) characters)")
        }
    }

    /// Saves each image as a new file in the chosen format, next to the Tray's other copies.
    func convert(_ chosen: [TrayItem], to format: FileTools.ImageFormat) {
        var made: [URL] = []
        var failures = 0
        for item in chosen where FileTools.isImage(item.url) && !format.matches(item.url) {
            do { made.append(try FileTools.convert(item.url, to: format, in: Self.folder)) } catch { failures += 1 }
        }
        let added = add(made)
        ActivityLog.note("converted \(made.count) image(s) to \(format.title), \(failures) failed")
        if added > 0 {
            announce(added == 1 ? "Saved \(made[0].lastPathComponent)" : "Saved \(added) \(format.title) files")
        } else {
            announce(failures > 0 ? "Couldn't convert that" : "Already \(format.title)")
        }
    }

    func zip(_ chosen: [TrayItem]) {
        let urls = chosen.map(\.url)
        announce("Zipping…")
        Task {
            do {
                let archive = try await FileTools.zip(urls, in: Self.folder)
                add([archive])
                announce("Made \(archive.lastPathComponent)")
            } catch {
                ActivityLog.note("zip failed: \(error.localizedDescription)")
                announce("Couldn't zip that")
            }
        }
    }

    // MARK: Selection (Finder-style)

    func click(_ item: TrayItem, command: Bool, shift: Bool) {
        if shift, let anchor,
           let from = items.firstIndex(where: { $0.id == anchor }),
           let to = items.firstIndex(where: { $0.id == item.id }) {
            let range = Set(items[min(from, to)...max(from, to)].map(\.id))
            selection = command ? selection.union(range) : range
            return
        }
        if command {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else {
            selection = [item.id]
        }
        anchor = item.id
    }

    func setSelection(_ ids: Set<UUID>) {
        if ids != selection { selection = ids }
    }

    func selectAll() { selection = Set(items.map(\.id)) }

    func clearSelection() {
        if !selection.isEmpty { selection.removeAll() }
    }

    /// Dragging an unselected item drags just that item (and selects it), like Finder.
    func urlsForDrag(starting item: TrayItem) -> [URL] {
        if !selection.contains(item.id) {
            selection = [item.id]
            anchor = item.id
        }
        return selectedItems.map(\.url)
    }

    /// Puts the files on the clipboard, ready to paste into Finder, Messages, Slack…
    @discardableResult
    func copy(_ chosen: [TrayItem], to pasteboard: NSPasteboard = .general) -> Int {
        guard !chosen.isEmpty else { return 0 }
        pasteboard.clearContents()
        pasteboard.writeObjects(chosen.map { $0.url as NSURL })
        return chosen.count
    }

    // MARK: Removing

    func remove(_ item: TrayItem) {
        items.removeAll { $0.id == item.id }
        selection.remove(item.id)
        deleteIfOwned(item)
        save()
    }

    func clear() {
        items.forEach(deleteIfOwned)
        items.removeAll()
        selection.removeAll()
        save()
    }

    private func deleteIfOwned(_ item: TrayItem) {
        if item.path.hasPrefix(Self.folder.path) { try? FileManager.default.removeItem(atPath: item.path) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: Prefs.trayItems) }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return f
    }()

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func keepable(_ url: URL) -> URL {
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix("/private/var/folders") || path.hasPrefix("/var/folders")
                || path.contains("/TemporaryItems/") else { return url }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(url.lastPathComponent)")
        }
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return url
        }
    }
}
