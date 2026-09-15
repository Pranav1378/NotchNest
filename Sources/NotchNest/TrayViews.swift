import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct TrayView: View {
    let vm: NotchViewModel
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 14) {
            if vm.trayMode == .clipboard {
                ClipboardView(clipboard: vm.clipboard, tray: vm.tray)
            } else {
                shelf.frame(maxWidth: .infinity, maxHeight: .infinity)
                AirDropZone(tray: vm.tray).frame(width: 120)
            }
        }
    }

    private var shelf: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return ZStack {
            shape.fill(Color.white.opacity(targeted ? 0.12 : 0.04))
            shape.strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(Color.white.opacity(targeted || vm.fileDragActive ? 0.7 : 0.2))
            if vm.tray.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 22))
                    Text("Drop files here").font(.system(size: 11, weight: .medium))
                    Text("or press ⌘V to paste a screenshot").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
            } else {
                GeometryReader { geo in
                    ScrollView(.horizontal, showsIndicators: false) {
                        TrayShelf(tray: vm.tray, minWidth: geo.size.width).frame(height: geo.size.height)
                    }
                }
                .clipShape(shape)
                .overlay(alignment: .topTrailing) {
                    Button { vm.tray.clear() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("Clear the Tray")
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            loadFileURLs(providers) { vm.tray.add($0) }
            return true
        }
    }
}

/// The Tray's items with Finder-style selection: click, ⌘-click, ⇧-click, or drag a box.
struct TrayShelf: View {
    static let space = "trayShelf"

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
                .onTapGesture { tray.clearSelection() }
                .gesture(bandGesture)
            HStack(spacing: 8) {
                ForEach(tray.items) { item in
                    TrayItemView(item: item, tray: tray, selected: tray.selection.contains(item.id))
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: ItemFramesKey.self,
                                                   value: [item.id: geo.frame(in: .named(Self.space))])
                        })
                }
            }
            .padding(.horizontal, 12)
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
                    bandBase = flags.contains(.command) || flags.contains(.shift) ? tray.selection : []
                }
                let rect = CGRect(x: min(value.startLocation.x, value.location.x),
                                  y: min(value.startLocation.y, value.location.y),
                                  width: abs(value.location.x - value.startLocation.x),
                                  height: abs(value.location.y - value.startLocation.y))
                band = rect
                tray.setSelection(bandBase.union(frames.filter { $0.value.intersects(rect) }.map(\.key)))
            }
            .onEnded { _ in band = nil }
    }
}

/// Where each item sits, for drag-a-box selection (Tray files and clipboard cards).
struct ItemFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct TrayItemView: View {
    let item: TrayItem
    let tray: TrayStore
    let selected: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: thumbnail ?? Thumbnails.cached(item.path) ?? NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.2 : 0)))
            Text(item.url.lastPathComponent)
                .font(.system(size: 9, weight: selected ? .semibold : .regular))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.clear))
                .frame(width: 66)
        }
        .frame(width: 70)
        .overlay {
            TrayItemMouse(
                tooltip: item.path,
                onClick: { modifiers, clicks in
                    if clicks >= 2 {
                        NSWorkspace.shared.open(item.url)
                    } else {
                        tray.click(item, command: modifiers.contains(.command), shift: modifiers.contains(.shift))
                    }
                },
                dragURLs: { tray.urlsForDrag(starting: item) },
                menu: { contextMenu() })
        }
        .task(id: item.path) { thumbnail = await Thumbnails.load(item.url) }
    }

    /// Right-click acts on the whole selection when the item is part of it.
    private func contextMenu() -> NSMenu {
        if !tray.selection.contains(item.id) { tray.click(item, command: false, shift: false) }
        let targets = tray.selectedItems
        let urls = targets.map(\.url)
        let count = targets.count > 1 ? " \(targets.count) Items" : ""
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open\(count)") { urls.forEach { NSWorkspace.shared.open($0) } })
        menu.addItem(ClosureMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) })
        menu.addItem(ClosureMenuItem("Copy\(count)") { tray.copy(targets) })
        if targets.contains(where: { TextRecognizer.canRead($0.url) }) {
            menu.addItem(ClosureMenuItem("Copy Text") { tray.copyText(from: targets) })
        }
        let images = targets.filter { FileTools.isImage($0.url) }
        if !images.isEmpty {
            let convert = NSMenuItem(title: images.count > 1 ? "Convert \(images.count) Images to" : "Convert to",
                                     action: nil, keyEquivalent: "")
            let formats = NSMenu()
            for format in FileTools.ImageFormat.allCases where images.contains(where: { !format.matches($0.url) }) {
                formats.addItem(ClosureMenuItem(format.title) { tray.convert(images, to: format) })
            }
            convert.submenu = formats
            menu.addItem(convert)
        }
        menu.addItem(ClosureMenuItem(targets.count > 1 ? "Zip \(targets.count) Items" : "Zip") { tray.zip(targets) })
        menu.addItem(ClosureMenuItem("AirDrop\(count)") { AirDrop.send(urls) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Remove\(count) from Tray") { for target in targets { tray.remove(target) } })
        return menu
    }
}

/// AppKit mouse handling for a Tray item: clicks feed selection, and dragging starts a
/// multi-file drag of the whole selection (SwiftUI's onDrag can only drag one item).
struct TrayItemMouse: NSViewRepresentable {
    let tooltip: String
    let onClick: (NSEvent.ModifierFlags, Int) -> Void
    let dragURLs: () -> [URL]
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> MouseView { MouseView() }

    func updateNSView(_ view: MouseView, context: Context) {
        view.toolTip = tooltip
        view.onClick = onClick
        view.dragURLs = dragURLs
        view.menuProvider = menu
    }

    final class MouseView: NSView {
        var onClick: (NSEvent.ModifierFlags, Int) -> Void = { _, _ in }
        var dragURLs: () -> [URL] = { [] }
        var menuProvider: () -> NSMenu = { NSMenu() }
        private var downEvent: NSEvent?
        private var dragging = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            downEvent = event
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragging, let start = downEvent else { return }
            let dx = event.locationInWindow.x - start.locationInWindow.x
            let dy = event.locationInWindow.y - start.locationInWindow.y
            guard dx * dx + dy * dy > 16 else { return }
            dragging = true
            let urls = dragURLs()
            guard !urls.isEmpty else { return }
            let origin = convert(start.locationInWindow, from: nil)
            let items = urls.enumerated().map { index, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let offset = CGFloat(min(index, 4)) * 5
                item.setDraggingFrame(NSRect(x: origin.x - 24 + offset, y: origin.y - 24 - offset, width: 48, height: 48),
                                      contents: Thumbnails.cached(url.path) ?? NSWorkspace.shared.icon(forFile: url.path))
                return item
            }
            ActivityLog.note("dragging \(urls.count) item(s) out of the tray")
            beginDraggingSession(with: items, event: start, source: TrayDragSource.shared)
        }

        override func mouseUp(with event: NSEvent) {
            if !dragging { onClick(event.modifierFlags, event.clickCount) }
            downEvent = nil
            dragging = false
        }

        override func menu(for event: NSEvent) -> NSMenu? { menuProvider() }
    }
}

/// Files dragged out of the Tray are copied, never moved, so originals stay where they were.
final class TrayDragSource: NSObject, NSDraggingSource {
    static let shared = TrayDragSource()

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}

/// Quick Look thumbnails for Tray items, so photos show their picture instead of a file icon.
@MainActor
enum Thumbnails {
    private static var cache: [String: NSImage] = [:]

    static func cached(_ path: String) -> NSImage? { cache[path] }

    static func load(_ url: URL) async -> NSImage? {
        if let hit = cache[url.path] { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 88, height: 88),
                                                   scale: 2, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        cache[url.path] = representation.nsImage
        return representation.nsImage
    }
}

struct AirDropZone: View {
    let tray: TrayStore
    @State private var targeted = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(spacing: 6) {
            Image(nsImage: AirDrop.icon).resizable().frame(width: 40, height: 40)
            Text("AirDrop").font(.system(size: 11, weight: .medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(targeted ? Color.blue.opacity(0.35) : Color.white.opacity(0.06)))
        .overlay(shape.strokeBorder(targeted ? Color.blue : Color.clear, lineWidth: 1.5))
        .contentShape(shape)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            loadFileURLs(providers) { AirDrop.send($0) }
            return true
        }
        .onTapGesture {
            let chosen = tray.selectedItems.isEmpty ? tray.items : tray.selectedItems
            AirDrop.send(chosen.map(\.url))
        }
        .help(tray.items.isEmpty ? "Drop files here to AirDrop them"
                                 : "Click to AirDrop the selected files (or everything in the Tray)")
    }
}

enum AirDrop {
    static let icon = NSWorkspace.shared.icon(
        forFile: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")

    static func send(_ urls: [URL]) {
        ActivityLog.note("airdrop: \(urls.count) file(s)")
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }
}

/// The files being dropped. Reads the drag pasteboard directly — SwiftUI's item providers came
/// back empty for Finder drags — and falls back to the providers for other drag sources.
func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let pasteboard = NSPasteboard(name: .drag)
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
       !urls.isEmpty {
        completion(urls)
        return
    }
    ActivityLog.note("drop: pasteboard had no files; providers \(providers.map(\.registeredTypeIdentifiers))")

    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []
    let fileURL = UTType.fileURL.identifier
    for provider in providers where provider.hasItemConformingToTypeIdentifier(fileURL) {
        group.enter()
        provider.loadItem(forTypeIdentifier: fileURL, options: nil) { item, _ in
            let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            if let url {
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}
