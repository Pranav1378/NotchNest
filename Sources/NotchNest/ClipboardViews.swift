import SwiftUI

/// The Tray's "Clipboard" side: recent copies as cards, with the same selection as the Tray
/// (click, ⌘-click, ⇧-click, drag a box). Delete with ✕, the Delete key, or right-click.
struct ClipboardView: View {
    let clipboard: ClipboardHistory
    let tray: TrayStore
    @AppStorage(Prefs.clipboardHistory) private var enabled = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            shape.fill(Color.white.opacity(0.04))
            if !enabled {
                placeholder("clipboard", "Clipboard history is off", "Turn it on in Settings → General.")
            } else if clipboard.items.isEmpty {
                placeholder("doc.on.clipboard", "Things you copy show up here",
                            "Kept in memory only. Passwords from password managers are skipped.")
            } else {
                GeometryReader { geo in
                    ScrollView(.horizontal, showsIndicators: false) {
                        ClipboardShelf(clipboard: clipboard, tray: tray, minWidth: geo.size.width)
                            .frame(height: geo.size.height)
                    }
                }
                .clipShape(shape)
                .overlay(alignment: .topTrailing) {
                    Button { clipboard.clear() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(5)
                            .background(Circle().fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("Clear all clipboard history")
                }
            }
        }
    }

    private func placeholder(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 20))
            Text(title).font(.system(size: 11, weight: .medium))
            Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 20)
    }
}

struct ClipboardShelf: View {
    static let space = "clipboardShelf"

    let clipboard: ClipboardHistory
    let tray: TrayStore
    let minWidth: CGFloat
    @State private var band: CGRect?
    @State private var bandBase: Set<UUID> = []
    @State private var frames: [UUID: CGRect] = [:]

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Empty space: click to deselect, drag to draw a selection box.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { clipboard.clearSelection() }
                .gesture(bandGesture)
            HStack(spacing: 8) {
                ForEach(clipboard.items) { item in
                    ClipCard(item: item, selected: clipboard.selection.contains(item.id)) {
                        clipboard.remove([item])
                    }
                    .onTapGesture {
                        let flags = NSEvent.modifierFlags
                        clipboard.click(item, command: flags.contains(.command), shift: flags.contains(.shift))
                    }
                    .onDrag { item.itemProvider }
                    .contextMenu { menu(for: item) }
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ItemFramesKey.self, value: [item.id: geo.frame(in: .named(Self.space))])
                    })
                }
            }
            .padding(10)
            .frame(maxHeight: .infinity)
            if let band {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1))
                    .frame(width: band.width, height: band.height)
                    .offset(x: band.minX, y: band.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: minWidth, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
        .onPreferenceChange(ItemFramesKey.self) { frames = $0 }
    }

    private var bandGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if band == nil {
                    let flags = NSEvent.modifierFlags
                    bandBase = flags.contains(.command) || flags.contains(.shift) ? clipboard.selection : []
                }
                let rect = CGRect(x: min(value.startLocation.x, value.location.x),
                                  y: min(value.startLocation.y, value.location.y),
                                  width: abs(value.location.x - value.startLocation.x),
                                  height: abs(value.location.y - value.startLocation.y))
                band = rect
                clipboard.setSelection(bandBase.union(frames.filter { $0.value.intersects(rect) }.map(\.key)))
            }
            .onEnded { _ in band = nil }
    }

    /// Right-click acts on the whole selection when the clip is part of it.
    @ViewBuilder private func menu(for item: ClipItem) -> some View {
        let targets = clipboard.selection.contains(item.id) ? clipboard.selectedItems : [item]
        let count = targets.count > 1 ? " \(targets.count) Clips" : ""
        if targets.count == 1, let url = item.linkURL {
            Button("Open Link") { NSWorkspace.shared.open(url) }
        }
        if targets.count == 1, let email = item.emailAddress {
            Button("New Email to \(email)") { ClipActions.email(email) }
        }
        Button("Copy\(count)") { clipboard.copy(targets) }
        if targets.contains(where: { !$0.isText }) {
            Button("Add to Tray") {
                for target in targets {
                    switch target.content {
                    case .image(let data, _): tray.addImage(data)
                    case .files(let urls): tray.add(urls)
                    case .text: break
                    }
                }
            }
        }
        Divider()
        Button("Delete\(count)") { clipboard.remove(targets) }
    }
}

struct ClipCard: View {
    let item: ClipItem
    let selected: Bool
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 4) {
                if let bundle = item.appBundleID, let icon = AppIcons.icon(for: bundle) {
                    Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                }
                Text(item.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let url = item.linkURL {
                    ActionChip(title: "Open", symbol: "safari") { NSWorkspace.shared.open(url) }
                        .help(url.absoluteString)
                } else if let email = item.emailAddress {
                    ActionChip(title: "Email", symbol: "envelope") { ClipActions.email(email) }
                        .help("New email to \(email)")
                }
            }
        }
        .padding(8)
        .frame(width: 118, height: 112)
        .background(shape.fill(Color.white.opacity(selected ? 0.16 : 0.07)))
        .overlay(shape.strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
        .overlay(alignment: .topTrailing) {
            if hovering || selected {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color(white: 0.3))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .help("Delete this clip")
            }
        }
        .contentShape(shape)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var preview: some View {
        switch item.content {
        case .text(let text):
            if let color = item.swatch {
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(color)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
                    Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                }
            } else {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 10))
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        case .image:
            if let image = item.preview {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        case .files(let urls):
            VStack(spacing: 4) {
                if let icon = item.preview { Image(nsImage: icon).resizable().frame(width: 34, height: 34) }
                Text(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
                    .font(.system(size: 9))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// A small pill button on a clip card ("Open", "Email").
struct ActionChip: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 7, weight: .bold))
                Text(title).font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.16)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

@MainActor
enum ClipActions {
    static func email(_ address: String) {
        if let url = URL(string: "mailto:\(address)") { NSWorkspace.shared.open(url) }
    }
}

/// Reads colour codes people copy: #RGB, #RGBA, #RRGGBB, #RRGGBBAA, rgb(…) and rgba(…).
enum ClipColor {
    static func parse(_ text: String?) -> Color? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), text.count <= 40 else { return nil }
        if text.hasPrefix("#") {
            let hex = Array(text.dropFirst())
            guard [3, 4, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
            let pairs: [String] = hex.count <= 4 ? hex.map { "\($0)\($0)" }
                                                 : stride(from: 0, to: hex.count, by: 2).map { String(hex[$0..<$0 + 2]) }
            let values = pairs.compactMap { UInt8($0, radix: 16) }.map { Double($0) / 255 }
            return Color(.sRGB, red: values[0], green: values[1], blue: values[2], opacity: values.count > 3 ? values[3] : 1)
        }
        let lower = text.lowercased()
        guard lower.hasPrefix("rgb"), lower.hasSuffix(")"), let open = lower.firstIndex(of: "(") else { return nil }
        let numbers = lower[lower.index(after: open)..<lower.index(before: lower.endIndex)]
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) }
        guard numbers.count == 3 || numbers.count == 4, numbers.prefix(3).allSatisfy({ (0...255).contains($0) }) else { return nil }
        return Color(.sRGB, red: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255,
                     opacity: numbers.count == 4 ? min(max(numbers[3] > 1 ? numbers[3] / 100 : numbers[3], 0), 1) : 1)
    }
}

extension ClipItem {
    var isText: Bool { text != nil }

    private var trimmedText: String? {
        text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A copied web address (one link, nothing else).
    var linkURL: URL? {
        guard let text = trimmedText, text.count < 2048, !text.contains(where: \.isWhitespace) else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
           url.host != nil { return url }
        if text.lowercased().hasPrefix("www."), let url = URL(string: "https://" + text), url.host != nil { return url }
        return nil
    }

    /// A copied email address (just the address).
    var emailAddress: String? {
        guard let text = trimmedText,
              text.range(of: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
        else { return nil }
        return text
    }

    /// A copied colour code, shown as a swatch.
    var swatch: Color? { ClipColor.parse(text) }

    /// What dragging the card out carries. Images go as a real PNG file: Finder, Messages, Slack and
    /// the rest only take a file, not raw image data, which is why dragging a copied screenshot
    /// used to do nothing.
    var itemProvider: NSItemProvider {
        switch content {
        case .text(let text):
            return NSItemProvider(object: text as NSString)
        case .image:
            guard let url = ClipFiles.file(for: self), let provider = NSItemProvider(contentsOf: url) else {
                return NSItemProvider()
            }
            provider.suggestedName = url.lastPathComponent
            return provider
        case .files(let urls):
            guard let provider = NSItemProvider(contentsOf: urls[0]) else { return NSItemProvider() }
            provider.suggestedName = urls[0].lastPathComponent
            return provider
        }
    }
}

/// Copied images written out as PNG files, so they can be dragged into other apps. They live in a
/// temporary folder the system clears, and each clip is only written once.
enum ClipFiles {
    private static let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("NotchNest-clips", isDirectory: true)
    private static var made: [UUID: URL] = [:]

    static func file(for item: ClipItem) -> URL? {
        if let url = made[item.id], FileManager.default.fileExists(atPath: url.path) { return url }
        guard case .image(let data, _) = item.content else { return nil }
        guard let png = asPNG(data) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(name(for: item.date)).png")
        do {
            try png.write(to: url)
            made[item.id] = url
            return url
        } catch {
            ActivityLog.note("clipboard drag: couldn't write the image: \(error.localizedDescription)")
            return nil
        }
    }

    private static func asPNG(_ data: Data) -> Data? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }  // already PNG
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

    private static func name(for date: Date) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return "Screenshot \(stamp.string(from: date))"
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}
