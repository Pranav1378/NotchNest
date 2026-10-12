import AppKit
import Carbon.HIToolbox
import SwiftUI

/// `NotchNest --snapshot <dir>` renders the notch's states to PNGs and quits, so the look can be
/// checked without Screen Recording permission. Uses live data (whatever is playing right now).
@MainActor
enum Snapshot {
    static func run(vm: NotchViewModel, to directory: String) {
        let savedTab = vm.tab
        vm.stats.setActive(true)
        // Give the now-playing helper and the Google fetches time to report in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            MainActor.assumeIsolated {
                render(vm, name: "closed", to: directory)
                vm.isOpen = true
                for tab in [NotchTab.nook, .tray, .tasks] {
                    vm.tab = tab
                    render(vm, name: "open-\(tab.rawValue)", to: directory)
                }
                vm.tab = .nook
                vm.statusCardShown = true
                render(vm, name: "open-status", to: directory)
                vm.statusCardShown = false
                vm.tab = savedTab
                Task { await newStates(vm, to: directory) }
            }
        }
    }

    /// The live activities and cards added for the timer, Claude Code, downloads and other screens.
    private static func newStates(_ vm: NotchViewModel, to directory: String) async {
        vm.isOpen = true
        vm.timerCardShown = true
        render(vm, name: "open-timer-idle", to: directory)
        vm.timer.start(minutes: 25)
        render(vm, name: "open-timer-running", to: directory)
        vm.timerCardShown = false
        vm.isOpen = false
        render(vm, name: "closed-timer", to: directory)

        vm.timerAlert = TimerAlert(title: "Focus done", detail: "Break · 5 min")
        render(vm, name: "closed-timer-done", to: directory)
        vm.timerAlert = nil

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        vm.downloadNotice = DownloadNotice(url: downloads.appendingPathComponent("CS 425 Lecture 7 slides.pdf"), inTray: false)
        render(vm, name: "closed-download", to: directory)
        vm.downloadNotice = nil

        vm.claudeDone = ClaudeFinished(project: "NotchNest", message: "Added the timer and Claude Code alerts. All checks pass.",
                                       hostApp: nil)
        render(vm, name: "closed-claude-done", to: directory)
        vm.claudeDone = nil

        // A real request through the bridge (on the test port).
        vm.claude.start()
        try? await Task.sleep(for: .seconds(0.4))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(vm.claude.port)/claude/permission")!)
        request.httpMethod = "POST"
        request.setValue("1", forHTTPHeaderField: "X-NotchNest")
        request.httpBody = Data(#"{"tool_name":"Bash","cwd":"/Users/me/NotchNest","tool_input":{"command":"swift build -c release && ./build.sh"}}"#.utf8)
        let asking = Task { try? await URLSession.shared.data(for: request) }
        try? await Task.sleep(for: .seconds(0.6))
        render(vm, name: "closed-claude-ask", to: directory)
        vm.isOpen = true
        render(vm, name: "open-claude-ask", to: directory)
        vm.isOpen = false
        if let id = vm.claudeRequest?.id { vm.claude.answer(id, .terminal) }
        _ = await asking.value

        // Usage, as a status line update would bring it (it only feeds the ✦ tooltip now).
        var status = URLRequest(url: URL(string: "http://127.0.0.1:\(vm.claude.port)/claude/status")!)
        status.httpMethod = "POST"
        status.setValue("1", forHTTPHeaderField: "X-NotchNest")
        let now = Int(Date().timeIntervalSince1970)
        status.httpBody = Data(#"{"rate_limits":{"five_hour":{"used_percentage":100,"resets_at":\#(now + 5400)},"seven_day":{"used_percentage":34,"resets_at":\#(now + 3 * 86400 + 7200)}}}"#.utf8)
        _ = try? await URLSession.shared.data(for: status)
        vm.isOpen = true
        render(vm, name: "open-usage-icons", to: directory)
        vm.planUsage.reload()
        vm.gemini.refresh()
        try? await Task.sleep(for: .seconds(6))
        vm.usageCardShown = true
        render(vm, name: "open-usage-card", to: directory)
        vm.usageCardShown = false
        vm.isOpen = false

        // An external monitor: the pill in its menu bar.
        vm.geometry = NotchGeometry.make(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                         visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415), safeTop: 0,
                                         leftArea: nil, rightArea: nil)
        vm.timer.stop()
        render(vm, name: "notchless-closed", to: directory)
        vm.timer.start(minutes: 12)
        render(vm, name: "notchless-timer", to: directory)
        vm.isOpen = true
        render(vm, name: "notchless-open", to: directory)
        exit(0)
    }

    fileprivate static func render(_ vm: NotchViewModel, name: String, to directory: String) {
        let view = NotchRootView(vm: vm)
            .frame(width: NotchController.windowSize.width, height: NotchController.windowSize.height)
            .background(Color(white: 0.62))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}

/// `NotchNest --selftest` opens the notch (app inactive, like a real hover) and feeds it
/// synthetic clicks and drags, printing what worked. Uses a private pasteboard, never the
/// real clipboard, and removes anything it adds to the Tray.
@MainActor
enum SelfTest {
    static func run(vm: NotchViewModel, notch: NotchController) {
        let panel = notch.panel
        var settingsOpened = false
        vm.openSettings = { settingsOpened = true }
        vm.tab = .nook
        vm.isOpen = false
        vm.chargingFlash = true  // a live activity to click and swipe on
        notch.showForTest()

        let height = NotchController.windowSize.height
        let trayTab = NSPoint(x: 180, y: height - 47)
        let gear = NSPoint(x: 668, y: height - 47)

        func send(_ type: NSEvent.EventType, _ point: NSPoint, _ modifiers: NSEvent.ModifierFlags = []) {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: panel.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1,
                                              pressure: type == .leftMouseUp ? 0 : 1) {
                panel.sendEvent(event)
            }
        }
        func click(_ point: NSPoint, _ modifiers: NSEvent.ModifierFlags = []) {
            send(.leftMouseDown, point, modifiers)
            send(.leftMouseUp, point, modifiers)
        }
        func drag(from start: NSPoint, to end: NSPoint) {
            send(.leftMouseDown, start)
            for step in 1...10 {
                let t = CGFloat(step) / 10
                send(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            }
            send(.leftMouseUp, end)
        }
        func frame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
        func itemViews(in view: NSView) -> [NSView] {
            view.subviews.flatMap { ($0 is TrayItemMouse.MouseView ? [$0] : []) + itemViews(in: $0) }
        }

        /// The newer features' moving parts, without touching the real clipboard or volume.
        func testExtras() {
            let parsed = LyricsService.parse("[00:01.00] one\n[00:03.50][00:10.00] two\n[00:05.00] three")
            log("lyrics parse: \(parsed.map { "\($0.time)=\($0.text)" }.joined(separator: ", ")) (want 1=one, 3.5=two, 5=three, 10=two)")

            let board = NSPasteboard(name: NSPasteboard.Name("NotchNestSelfTest2"))
            board.clearContents()
            board.setString("hello from the notch", forType: .string)
            log("clipboard capture, text: \(ClipboardHistory.capture(board)?.text ?? "nil") (want hello from the notch)")
            board.clearContents()
            board.writeObjects([NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
                NSColor.systemTeal.setFill()
                rect.fill()
                return true
            }])
            var capturedImage = false
            if case .image = ClipboardHistory.capture(board)?.content { capturedImage = true }
            log("clipboard capture, image: \(capturedImage) (want true)")

            // Clipboard history selection and deleting. Only ⌘/⇧-clicks: a plain click would copy
            // onto the real clipboard.
            let history = vm.clipboard
            for text in ["first clip", "second clip", "third clip"] {
                board.clearContents()
                board.setString(text, forType: .string)
                if let clip = ClipboardHistory.capture(board) { history.add(clip) }
            }
            let clips = history.items  // newest first: third, second, first
            history.click(clips[0], command: true, shift: false)
            history.click(clips[2], command: false, shift: true)
            log("clipboard ⌘-click then ⇧-click: \(history.selection.count) selected (want 3)")
            history.click(clips[1], command: true, shift: false)
            log("clipboard ⌘-click to deselect one: \(history.selection.count) selected (want 2)")
            let deleted = history.removeSelected()
            log("clipboard delete selected: deleted \(deleted), \(history.items.count) left (want 2, 1)")
            history.remove(history.items)
            let deleteKey = HotKey(keyCode: kVK_Delete, modifiers: 0, id: 98) {}
            deleteKey.isEnabled = true
            log("Delete key shortcut registered: \(deleteKey.isRegistered) (want true)")
            deleteKey.isEnabled = false
            board.releaseGlobally()

            let url = FileManager.default.temporaryDirectory.appendingPathComponent("notchnest-ocr-test.png")
            let sample = NSImage(size: NSSize(width: 640, height: 120), flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                ("NotchNest reads 425" as NSString).draw(at: NSPoint(x: 24, y: 36), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 44, weight: .semibold), .foregroundColor: NSColor.black,
                ])
                return true
            }
            if let tiff = sample.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
            }
            log("screenshot check on a plain image: \(ScreenshotWatcher.isScreenshot(url)) (want false)")

            Task {
                let text = await TextRecognizer.text(in: url) ?? "nil"
                log("OCR: \"\(text.replacingOccurrences(of: "\n", with: " "))\" (want NotchNest reads 425)")
                let trackpad = await HeadphoneBattery.levels(for: "Magic Trackpad")
                log("Bluetooth battery, Magic Trackpad: \(trackpad?.headline.map { "\($0)%" } ?? "nil")")
                log("output volume readable: \(SystemVolume.level.map { "\(Int(($0 * 100).rounded()))%" } ?? "nil")")
                vm.stats.setActive(true)
                try? await Task.sleep(for: .seconds(1.8))
                let snapshot = vm.stats.snapshot
                let memory = snapshot.map { ByteCountFormatter.string(fromByteCount: Int64($0.memoryUsed), countStyle: .memory) }
                log("stats: CPU \(snapshot?.cpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "nil"), memory \(memory ?? "nil"), "
                    + "battery health \(vm.stats.batteryHealth.map { "\($0)%" } ?? "nil") \(vm.stats.batteryCondition ?? ""), "
                    + "\(vm.stats.cycleCount.map { "\($0) cycles" } ?? "no cycle count")")
                vm.stats.setActive(false)
                try? FileManager.default.removeItem(at: url)
                exit(0)
            }
        }

        func testTray() {
            let hotKey = HotKey(keyCode: kVK_ANSI_V, id: 99) {}
            hotKey.isEnabled = true
            log("⌘V shortcut registered: \(hotKey.isRegistered) (want true)")
            hotKey.isEnabled = false

            let clipboard = NSPasteboard(name: NSPasteboard.Name("NotchNestSelfTest"))
            clipboard.clearContents()
            clipboard.writeObjects([NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
                NSColor.systemPink.setFill()
                rect.fill()
                return true
            }])
            let before = vm.tray.items.count
            let added = vm.tray.paste(from: clipboard) + vm.tray.paste(from: clipboard)
            log("paste image twice: added=\(added), tray \(before)→\(vm.tray.items.count) (want +2)")
            let testItems = Array(vm.tray.items.suffix(added))

            func finish() {
                for item in testItems { vm.tray.remove(item) }
                clipboard.releaseGlobally()
                testExtras()
            }

            vm.tab = .tray
            after(0.8) {
                let views = itemViews(in: panel.contentView!).sorted { frame($0).minX < frame($1).minX }
                guard views.count >= 2 else {
                    log("found only \(views.count) tray item views")
                    finish()
                    return
                }
                let first = frame(views[views.count - 2])
                let second = frame(views[views.count - 1])

                vm.tray.clearSelection()
                click(NSPoint(x: first.midX, y: first.midY))
                log("click: \(vm.tray.selection.count) selected (want 1)")
                click(NSPoint(x: second.midX, y: second.midY), .command)
                log("⌘-click: \(vm.tray.selection.count) selected (want 2)")

                vm.tray.clearSelection()
                drag(from: NSPoint(x: second.maxX + 40, y: second.maxY - 4),
                     to: NSPoint(x: first.minX + 10, y: first.minY + 10))
                after(0.3) {
                    log("box select: \(vm.tray.selection.count) selected (want 2)")
                    vm.tray.selectAll()
                    let copied = vm.tray.copy(vm.tray.selectedItems, to: clipboard)
                    let onClipboard = (clipboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.count ?? 0
                    log("⌘A then copy: \(copied) copied, clipboard holds \(onClipboard) (want \(vm.tray.items.count))")
                    finish()
                }
            }
        }

        func testTabs() {
            vm.chargingFlash = false
            vm.tab = .nook
            vm.isOpen = true
            after(0.8) {
                log("panel level=\(panel.level.rawValue) canBecomeKey=\(panel.canBecomeKey) (want 27, false)")
                click(trayTab)
                after(0.6) {
                    log("after clicking Tray: tab=\(vm.tab.rawValue) (want tray)")
                    click(gear)
                    after(0.4) {
                        log("after clicking gear: settingsOpened=\(settingsOpened) (want true)")
                        testTray()
                    }
                }
            }
        }

        /// Two-finger scroll events, as the trackpad sends them, through the app's event monitors.
        func swipe() {
            for phase: Int64 in [1, 2, 2, 2, 2, 2] {  // began, then changed
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                       wheel1: 12, wheel2: 0, wheel3: 0) else { return }
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                if let event = NSEvent(cgEvent: cg) { NSApp.sendEvent(event) }
            }
        }

        func testLiveActivity() {
            let midX = NotchController.windowSize.width / 2
            let side = NSPoint(x: midX - vm.shapeSize.width / 2 + 30, y: height - 16)
            let middle = NSPoint(x: midX, y: height - 16)
            log("live activity showing: \(vm.liveActivity.map { "\($0)" } ?? "none") (want charging)")
            click(side)
            after(0.3) {
                // Something else (e.g. music that's playing) may take its place, so check the
                // charging notice itself went away.
                log("click on its side: hidden=\(vm.liveActivity != .charging) (want true)")
                vm.chargingFlash = true
                click(middle)
                after(0.4) {
                    log("click on the notch itself: open=\(vm.isOpen) (want true)")
                    vm.isOpen = false
                    vm.chargingFlash = true
                    after(0.3) {
                        swipe()
                        log("two-finger swipe on it: hidden=\(vm.liveActivity != .charging) (want true)")
                        testTabs()
                    }
                }
            }
        }

        after(0.8) { testLiveActivity() }
    }

    /// `--cameratest`: open the Nook and flip the Mirror on and off, slow then fast, so its preview view
    /// comes and goes each time. Before the shared preview layer, the second "on" aborted the app.
    /// Results also go to cameratest.log, since the camera grant needs the app launched with `open`.
    static func runCamera(vm: NotchViewModel, notch: NotchController) {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchNest/cameratest.log")
        try? "".write(to: file, atomically: true, encoding: .utf8)
        func note(_ line: String) {
            log(line)
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(Data((line + "\n").utf8))
                try? handle.close()
            }
        }
        vm.tab = .nook
        notch.showForTest()
        vm.isOpen = true
        let gaps: [Double] = [1.5, 1.5, 1.0, 1.0, 0.6, 0.6, 0.3, 0.3, 0.15, 0.15, 0.8, 0.8]
        func step(_ i: Int) {
            guard i < gaps.count else {
                vm.camera.stop()
                after(1.0) {
                    note("survived \(gaps.count) toggles (want this line)")
                    exit(0)
                }
                return
            }
            vm.camera.toggle()
            note("toggle \(i + 1): running=\(vm.camera.isRunning) denied=\(vm.camera.denied) open=\(vm.isOpen)")
            after(gaps[i]) { step(i + 1) }
        }
        after(1.0) { step(0) }
    }

    private static func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
    }

    private static func log(_ line: String) {
        print("selftest:", line)
        fflush(stdout)
    }
}
