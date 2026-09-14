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
                if item.isLink {
                    Image(systemName: "link").font(.system(size: 8)).foregroundStyle(.secondary)
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
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 10))
                .lineLimit(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

extension ClipItem {
    var isText: Bool { text != nil }
    var isLink: Bool { text.map { $0.hasPrefix("http://") || $0.hasPrefix("https://") } ?? false }

    /// What dragging the card out carries.
    var itemProvider: NSItemProvider {
        switch content {
        case .text(let text): return NSItemProvider(object: text as NSString)
        case .image(let data, _): return NSImage(data: data).map { NSItemProvider(object: $0) } ?? NSItemProvider()
        case .files(let urls): return NSItemProvider(contentsOf: urls[0]) ?? NSItemProvider()
        }
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
