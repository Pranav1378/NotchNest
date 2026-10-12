import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Borderless panel that sits over the menu bar, on every Space, without stealing focus.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        // Above the menu bar (24) so it draws over app menus and gets the clicks there.
        // Don't set isFloatingPanel afterwards: it silently resets the level to .floating (3).
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            ActivityLog.note("click at \(Int(event.locationInWindow.x)),\(Int(event.locationInWindow.y)) key=\(isKeyWindow)")
        }
        super.sendEvent(event)
    }

    /// Only text fields need keyboard focus (Tasks, quick-add). Everywhere else the notch leaves
    /// focus with the app you're using; clicks still land via first-mouse.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    // Let the panel sit in the menu bar area instead of being pushed below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the notch panel and decides when it opens, closes and takes mouse events.
@MainActor
final class NotchController {
    static let windowSize = CGSize(width: 760, height: 300)
    /// How far below the notch a card may hang.
    static let cardReach: CGFloat = 96

    private enum Axis { case horizontal, vertical }

    private let vm: NotchViewModel
    let panel: NotchPanel
    private var timer: Timer?
    private var hoverSince: Date?
    private var leftSince: Date?
    private var mouseWasDown = false
    private var dragBaseCount = 0
    private var scrollMonitor: Any?
    private var pasteKey: HotKey?
    private var selectAllKey: HotKey?
    private var copyKey: HotKey?
    private var deleteKey: HotKey?
    private var commandDeleteKey: HotKey?
    // The two-finger gesture in progress: its direction and how far it has travelled.
    private var gestureAxis: Axis?
    private var gestureX: CGFloat = 0
    private var gestureY: CGFloat = 0
    private var gestureFired = false
    private var displayMode = DisplayMode.current

    init(vm: NotchViewModel) {
        self.vm = vm
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Self.windowSize))
        let host = FirstMouseHostingView(rootView: NotchRootView(vm: vm))
        host.sizingOptions = []
        panel.contentView = host
        vm.requestKeyboard = { [weak self] in
            guard let self else { return }
            self.panel.allowsKey = true
            self.panel.makeKey()
        }
        vm.pointerInside = { [weak self] in self?.shapeRect().contains(NSEvent.mouseLocation) ?? false }
    }

    /// The black shape, in screen coordinates.
    private func shapeRect() -> CGRect {
        let geo = vm.geometry
        let size = vm.shapeSize
        return CGRect(x: geo.notchMidX - size.width / 2, y: geo.screenTop - size.height,
                      width: size.width, height: size.height + 1)
    }

    func start() {
        place()
        panel.orderFrontRegardless()

        let timer = Timer(timeInterval: 1.0 / 40, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.place() } }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.place() } }
        // Settings → "Show the notch on" takes effect straight away.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, DisplayMode.current != self.displayMode else { return }
                self.displayMode = DisplayMode.current
                self.vm.close()
                self.place()
            }
        }

        installScrollMonitor()
        pasteKey = HotKey(keyCode: kVK_ANSI_V, id: 1) { [weak self] in self?.pasteIntoTray() }
        selectAllKey = HotKey(keyCode: kVK_ANSI_A, id: 2) { [weak self] in self?.selectAll() }
        copyKey = HotKey(keyCode: kVK_ANSI_C, id: 3) { [weak self] in self?.copySelection() }
        deleteKey = HotKey(keyCode: kVK_Delete, modifiers: 0, id: 4) { [weak self] in self?.deleteSelection() }
        commandDeleteKey = HotKey(keyCode: kVK_Delete, id: 5) { [weak self] in self?.deleteSelection() }
    }

    /// For --selftest: show the panel, accepting clicks, without the hover loop.
    func showForTest() {
        place()
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        installScrollMonitor()
    }

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handleScroll(event) }
            return event
        }
    }

    private func place() {
        let geo = NotchGeometry.current()
        if geo != vm.geometry {
            vm.geometry = geo
            ActivityLog.note("notch on \(geo.hasNotch ? "the notched" : "a notchless") screen at \(Int(geo.screenFrame.minX)),\(Int(geo.screenFrame.minY)) (\(Int(geo.screenFrame.width))×\(Int(geo.screenFrame.height)))")
        }
        let size = Self.windowSize
        panel.setFrame(NSRect(x: geo.notchMidX - size.width / 2, y: geo.screenTop - size.height,
                              width: size.width, height: size.height), display: true)
    }

    private func tick() {
        let mouse = NSEvent.mouseLocation
        // "The display the pointer is on": follow it to another screen while the notch is closed.
        if displayMode == .pointer, !vm.isOpen, !vm.geometry.screenFrame.insetBy(dx: 0, dy: -1).contains(mouse) {
            place()
        }
        let geo = vm.geometry
        let top = geo.screenTop
        let shape = shapeRect()

        // Closed: only the notch itself is a hover target, so the menu bar beside it stays usable.
        var zone = vm.isOpen
            ? shape.insetBy(dx: -10, dy: -14)
            : CGRect(x: geo.notchMidX - geo.notchSize.width / 2, y: top - geo.notchSize.height - 2,
                     width: geo.notchSize.width, height: geo.notchSize.height + 3)
        // A status or timer card hangs below the notch: keep it hoverable and clickable.
        if vm.isOpen && (vm.statusCardShown || vm.timerCardShown || vm.usageCardShown) {
            zone = zone.union(CGRect(x: shape.minX, y: shape.minY - Self.cardReach,
                                     width: shape.width, height: Self.cardReach + 1))
        }
        var hovering = zone.contains(mouse)

        trackFileDrag()
        if vm.fileDragActive {
            // Dragging a file toward the notch pulls the Tray open well before the top edge,
            // where macOS would take over the drag and open Mission Control.
            let open = NotchViewModel.openSize
            let reach: CGFloat = vm.isOpen ? open.height + 14 : 120
            let attract = CGRect(x: geo.notchMidX - open.width / 2, y: top - reach,
                                 width: open.width, height: reach + 1)
            hovering = hovering || attract.contains(mouse)
        }

        // Keep the notch open while you're typing in it, even if the pointer wanders off.
        let typing = vm.isOpen && panel.isKeyWindow && (vm.composingEvent || !vm.tasks.draft.isEmpty)
        let now = Date()
        if hovering || typing {
            leftSince = nil
            if hovering && vm.fileDragActive {
                if vm.trayMode != .files { vm.trayMode = .files }
                if !vm.isOpen { vm.open(tab: .tray) } else if vm.tab != .tray { vm.select(.tray) }
            } else if hovering && !vm.isOpen && Prefs.bool(Prefs.openOnHover) {
                if let since = hoverSince {
                    if now.timeIntervalSince(since) > 0.06 { vm.open() }
                } else {
                    hoverSince = now
                }
            }
        } else {
            hoverSince = nil
            if vm.isOpen {
                if let since = leftSince {
                    if now.timeIntervalSince(since) > 0.3 { vm.close(); leftSince = nil }
                } else {
                    leftSince = now
                }
            }
        }

        let interactive = shape.contains(mouse) || (vm.isOpen && hovering)
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }

        // ⌘V/⌘A/⌘C belong to the notch only while it's open under the pointer, and never while a
        // text field is taking typing (there they're the normal Edit menu shortcuts).
        let onTray = vm.isOpen && vm.tab == .tray && !vm.wantsKeyboard
        let clips = vm.trayMode == .clipboard
        let hasSelection = !(clips ? vm.clipboard.selection.isEmpty : vm.tray.selection.isEmpty)
        pasteKey?.isEnabled = vm.isOpen && !vm.wantsKeyboard
        selectAllKey?.isEnabled = onTray && !(clips ? vm.clipboard.items.isEmpty : vm.tray.items.isEmpty)
        copyKey?.isEnabled = onTray && hasSelection
        deleteKey?.isEnabled = onTray && hasSelection
        commandDeleteKey?.isEnabled = onTray && hasSelection

        panel.allowsKey = vm.wantsKeyboard
        // Hand keyboard focus back to the app underneath once the notch closes.
        if !vm.isOpen && panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    /// The pasteboard is only queried while the button is held — it's a cross-process call.
    private func trackFileDrag() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        defer { mouseWasDown = down }
        guard down else {
            if vm.fileDragActive { vm.fileDragActive = false }
            return
        }
        let pasteboard = NSPasteboard(name: .drag)
        if !mouseWasDown {
            dragBaseCount = pasteboard.changeCount
            return
        }
        guard !vm.fileDragActive, pasteboard.changeCount != dragBaseCount else { return }
        if pasteboard.types?.contains(.fileURL) ?? false {
            ActivityLog.note("file drag detected")
            vm.fileDragActive = true
        } else {
            dragBaseCount = pasteboard.changeCount  // a non-file drag; don't re-check every tick
        }
    }

    // MARK: Shortcuts

    private func pasteIntoTray() {
        let added = vm.tray.paste()
        ActivityLog.note("paste into tray: \(added) item(s)")
        if added > 0 {
            vm.trayMode = .files
            vm.select(.tray)
            vm.showToast(added == 1 ? "Added 1 item" : "Added \(added) items")
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        } else {
            NSSound.beep()
        }
    }

    private func selectAll() {
        if vm.trayMode == .clipboard { vm.clipboard.selectAll() } else { vm.tray.selectAll() }
    }

    private func copySelection() {
        if vm.trayMode == .clipboard {
            vm.clipboard.copy(vm.clipboard.selectedItems)
        } else {
            let copied = vm.tray.copy(vm.tray.selectedItems)
            ActivityLog.note("copied \(copied) tray item(s)")
            vm.showToast(copied == 1 ? "Copied 1 item" : "Copied \(copied) items")
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    /// Delete / ⌘⌫: removes the selected clips, or the selected files from the Tray (Tray copies
    /// of pasted screenshots are deleted; originals elsewhere are left alone).
    private func deleteSelection() {
        let removed: Int
        if vm.trayMode == .clipboard {
            removed = vm.clipboard.removeSelected()
            vm.showToast(removed == 1 ? "Deleted 1 clip" : "Deleted \(removed) clips")
        } else {
            let chosen = vm.tray.selectedItems
            for item in chosen { vm.tray.remove(item) }
            removed = chosen.count
            vm.showToast(removed == 1 ? "Removed 1 item" : "Removed \(removed) items")
        }
        ActivityLog.note("deleted \(removed) selected \(vm.trayMode == .clipboard ? "clip(s)" : "tray item(s)")")
    }

    // MARK: Two-finger swipes

    /// Closed: swiping a live activity shrinks it, swiping the small one brings it back.
    /// Open: on the tab bar, left/right switches tabs; on the player, left/right changes track
    /// and up/down changes the volume. Everything else scrolls as usual.
    private func handleScroll(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase == [] else { return }
        if event.phase == .began {
            gestureAxis = nil
            gestureX = 0
            gestureY = 0
            gestureFired = false
        }
        // Normalised so positive means the fingers moved right / up, whatever the scroll setting.
        let inverted = event.isDirectionInvertedFromDevice
        let dx = inverted ? event.scrollingDeltaX : -event.scrollingDeltaX
        let dy = inverted ? -event.scrollingDeltaY : event.scrollingDeltaY
        gestureX += dx
        gestureY += dy
        if gestureAxis == nil, max(abs(gestureX), abs(gestureY)) > 6 {
            gestureAxis = abs(gestureX) >= abs(gestureY) ? .horizontal : .vertical
        }

        if !vm.isOpen {
            guard !gestureFired, abs(gestureX) + abs(gestureY) > 40 else { return }
            if vm.liveActivity != nil {
                gestureFired = true
                vm.dismissLiveActivity()
            } else if vm.miniActivity != nil {
                gestureFired = true
                vm.restoreLiveActivity()
            }
            return
        }

        guard Prefs.bool(Prefs.swipeTracks), let axis = gestureAxis else { return }
        let mouse = NSEvent.mouseLocation
        let geo = vm.geometry
        let fromTop = geo.screenTop - mouse.y
        let contentLeft = geo.notchMidX - NotchViewModel.openSize.width / 2 + NotchViewModel.openFlare + 16
        let overHeader = fromTop < 64
        let overPlayer = vm.tab == .nook && fromTop >= 64 && fromTop <= 220
            && mouse.x >= contentLeft && mouse.x <= contentLeft + 232

        switch axis {
        case .horizontal where overHeader:
            guard !gestureFired, abs(gestureX) > 60 else { return }
            gestureFired = true
            vm.cycleTab(by: gestureX < 0 ? 1 : -1)
        case .horizontal where overPlayer && vm.media.hasTrack:
            guard !gestureFired, abs(gestureX) > 60 else { return }
            gestureFired = true
            if gestureX < 0 { vm.media.next() } else { vm.media.previous() }
        case .vertical where overPlayer:
            guard let level = SystemVolume.level else { return }
            let newLevel = min(max(level + Float(dy) * 0.003, 0), 1)
            SystemVolume.set(newLevel)
            vm.showVolume(newLevel)
        default:
            break
        }
    }
}
