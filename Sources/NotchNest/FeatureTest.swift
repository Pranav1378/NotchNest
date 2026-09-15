import AppKit
import SwiftUI

/// `NotchNest --featuretest`: checks the timer, the Claude Code bridge and hooks, notch placement
/// on other screens, clipboard actions, Tray tools and download detection. Works in temporary
/// folders and on a spare port; never touches your settings, clipboard, Tray or microphone.
@MainActor
enum FeatureTest {
    static func run(vm: NotchViewModel, notch: NotchController) {
        Task {
            geometry()
            clipboard()
            await files()
            await downloads()
            await devices()
            await timer()
            await claude(vm: vm)
            await clicks(vm: vm, notch: notch)
            hooks()
            log("done")
            exit(0)
        }
    }

    // MARK: Displays

    private static func geometry() {
        let builtIn = NotchGeometry.make(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                         visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950), safeTop: 32,
                                         leftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                         rightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32))
        log("built-in 14\": notch=\(builtIn.hasNotch) \(size(builtIn)) at x=\(Int(builtIn.notchMidX)) (want true, 185×32, 756)")
        let monitor = NotchGeometry.make(frame: CGRect(x: 1512, y: -200, width: 2560, height: 1440),
                                         visibleFrame: CGRect(x: 1512, y: -200, width: 2560, height: 1415), safeTop: 0,
                                         leftArea: nil, rightArea: nil)
        log("external 2560×1440 to the right: notch=\(monitor.hasNotch) pill \(size(monitor)) at x=\(Int(monitor.notchMidX)), top=\(Int(monitor.screenTop)) (want false, 180×25, 2792, 1240)")
        let air = NotchGeometry.make(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                     visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875), safeTop: 0,
                                     leftArea: nil, rightArea: nil)
        log("M1 Air 1440×900: notch=\(air.hasNotch) pill \(size(air)) at x=\(Int(air.notchMidX)) (want false, 180×25, 720)")
        let hiddenBar = NotchGeometry.make(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                           visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeTop: 0,
                                           leftArea: nil, rightArea: nil)
        log("menu bar set to hide: pill \(size(hiddenBar)) (want 180×24)")
        let screens = NSScreen.screens.map { "\(Int($0.frame.width))×\(Int($0.frame.height))\($0.safeAreaInsets.top > 0 ? " notch" : "")" }
        log("this Mac's screens: \(screens.joined(separator: ", ")); every mode picks: "
            + DisplayMode.allCases.map { "\($0.rawValue)→\(NotchGeometry.screen(for: $0, mouse: NSEvent.mouseLocation).map { "\(Int($0.frame.width))" } ?? "none")" }.joined(separator: " "))
    }

    private static func size(_ geo: NotchGeometry) -> String { "\(Int(geo.notchSize.width))×\(Int(geo.notchSize.height))" }

    // MARK: Clipboard

    private static func clipboard() {
        func clip(_ text: String) -> ClipItem {
            ClipItem(content: .text(text), key: text, preview: nil, appBundleID: nil, date: .now)
        }
        let links = ["https://github.com/Pranav1378/NotchNest", "www.apple.com", "see https://x.com", "hello"]
            .map { "\($0)→\(clip($0).linkURL != nil)" }
        log("links: \(links.joined(separator: ", ")) (want true, true, false, false)")
        let emails = ["pranav@example.com", " friend.name+tag@uni.edu \n", "not an email@", "a@b"]
            .map { "\($0.trimmingCharacters(in: .whitespacesAndNewlines))→\(clip($0).emailAddress != nil)" }
        log("emails: \(emails.joined(separator: ", ")) (want true, true, false, false)")
        let colors = ["#ff8800", "#abc", "#11223344", "rgb(255, 0, 0)", "rgba(0,0,0,0.5)", "facade", "#12345", "rgb(300,0,0)"]
            .map { "\($0)→\(clip($0).swatch != nil)" }
        log("colours: \(colors.joined(separator: ", ")) (want true, true, true, true, true, false, false, false)")
    }

    // MARK: Tray tools

    private static func files() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchNest-featuretest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 10, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        let png = folder.appendingPathComponent("Photo.png")
        try? bitmap.representation(using: .png, properties: [:])?.write(to: png)
        var results: [String] = []
        for format in [FileTools.ImageFormat.jpeg, .heic, .png] {
            do {
                let out = try FileTools.convert(png, to: format, in: folder)
                let source = CGImageSourceCreateWithURL(out as CFURL, nil)
                let props = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                results.append("\(out.lastPathComponent) \(props?[kCGImagePropertyPixelWidth] ?? 0)×\(props?[kCGImagePropertyPixelHeight] ?? 0)")
            } catch {
                results.append("\(format.title) failed: \(error.localizedDescription)")
            }
        }
        log("convert: \(results.joined(separator: ", ")) (want Photo.jpg, Photo.heic, Photo 2.png, all 20×10)")
        let note = folder.appendingPathComponent("Notes.txt")
        try? "hello".write(to: note, atomically: true, encoding: .utf8)
        for set in [[png], [png, note]] {
            do {
                let archive = try await FileTools.zip(set, in: folder)
                log("zip \(set.count) file(s): \(archive.lastPathComponent) contains \(zipEntries(archive)) (want \(set.count == 1 ? "Photo.png" : "Archive/Photo.png, Archive/Notes.txt"))")
            } catch {
                log("zip failed: \(error.localizedDescription)")
            }
        }
    }

    private static func zipEntries(_ url: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").filter { !$0.hasSuffix("/") && !$0.contains("__MACOSX") }.joined(separator: ", ")
    }

    // MARK: Downloads

    private static func downloads() async {
        let names = ["report.pdf", "Unconfirmed 123.crdownload", "movie.mp4.part", "big.zip.download", ".DS_Store"]
        log("partial downloads: \(names.map { "\($0)→\(DownloadWatcher.isPartial($0))" }.joined(separator: ", ")) (want false, true, true, true, true)")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchNest-downloads-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var reported: [String] = []
        let watcher = DownloadWatcher(directory: folder) { reported.append($0.lastPathComponent) }
        watcher.start()
        // A browser-style download: partial file first, renamed when done, tagged with where it came from.
        let partial = folder.appendingPathComponent("Lecture 7.pdf.crdownload")
        try? Data(repeating: 1, count: 4096).write(to: partial)
        try? await Task.sleep(for: .seconds(1.5))
        let final = folder.appendingPathComponent("Lecture 7.pdf")
        try? FileManager.default.moveItem(at: partial, to: final)
        _ = "0081;00000000;Safari;".withCString { setxattr(final.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        // A file you make yourself (no tag) shouldn't count.
        try? "mine".write(to: folder.appendingPathComponent("my notes.txt"), atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .seconds(4))
        watcher.stop()
        log("downloads noticed: \(reported) (want [\"Lecture 7.pdf\"])")
    }

    // MARK: Devices

    private static func devices() async {
        let fixture = #"{"SPBluetoothDataType":[{"device_connected":[{"Magic Mouse":{"device_minorType":"Mouse","device_batteryLevelMain":"45%"}},{"Pranav’s AirPods Pro":{"device_minorType":"Headphones","device_batteryLevelLeft":"80%","device_batteryLevelRight":"70%","device_batteryLevelCase":"62%"}},{"Some Speaker":{"device_minorType":"Speaker"}}]}]}"#
        let parsed = HeadphoneBattery.devices(in: Data(fixture.utf8)).map { "\($0.name) \($0.level)% \($0.symbol)" }
        log("bluetooth batteries (sample data): \(parsed) (want Magic Mouse 45% magicmouse.fill, AirPods Pro 70% airpodspro)")
        let live = await HeadphoneBattery.connectedDevices().map { "\($0.name) \($0.level)%" }
        log("bluetooth batteries now: \(live.isEmpty ? "none connected" : live.joined(separator: ", "))")
        log("sound outputs: \(AudioOutput.all().map(\.name)); current: \(AudioOutput.current?.name ?? "none")")
        let privacy = PrivacyMonitor()
        privacy.poll()
        log("camera in use: \(privacy.cameraInUse), microphone in use: \(privacy.micInUse), microphones: \(PrivacyMonitor.inputs().compactMap(SystemVolume.name))")
        let awake = KeepAwake()
        awake.on()
        let during = assertions().contains("NotchNest Keep Awake")
        awake.off()
        let after = assertions().contains("NotchNest Keep Awake")
        log("keep awake: held=\(during) released=\(!after) (want true, true)")
    }

    private static func assertions() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: Timer

    private static func timer() async {
        let timer = FocusTimer()
        var finished: String?
        timer.onFinish = { title, detail in finished = "\(title) (\(detail))" }
        timer.start(minutes: 1.5 / 60)
        try? await Task.sleep(for: .seconds(2.6))
        log("1.5-second timer: \(finished ?? "didn't finish") active=\(timer.isActive) (want Time's up, false)")
        timer.start(minutes: 1)
        timer.pause()
        let paused = timer.remaining()
        try? await Task.sleep(for: .seconds(1.1))
        let stillPaused = timer.remaining()
        timer.resume()
        timer.addMinute()
        log("pause holds: \(paused == stillPaused), after +1 min: \(FocusTimer.format(timer.remaining())) (want true, 2:00)")
        timer.stop()
        timer.startPomodoro()
        let first = timer.kind
        timer.skip()
        log("pomodoro: \(first) then skip → \(timer.kind), \(FocusTimer.format(timer.remaining())) (want focus, rest, \(FocusTimer.breakMinutes):00)")
        timer.stop()
    }

    // MARK: Claude Code

    private static func claude(vm: NotchViewModel) async {
        let bridge = vm.claude
        bridge.start()
        try? await Task.sleep(for: .seconds(0.5))
        let port = bridge.port
        let bash: [String: Any] = ["hook_event_name": "PermissionRequest", "tool_name": "Bash", "cwd": "/Users/me/NotchNest",
                                   "tool_input": ["command": "rm -rf build", "description": "Clean"]]

        let (forbidden, _) = await post(port, "/claude/permission", bash, headers: [:])
        log("claude: request without the NotchNest header → HTTP \(forbidden) (want 403)")

        // Allow from the notch.
        let asking = Task { await post(port, "/claude/permission", bash, headers: ["X-NotchNest": "1", "X-App": "com.example.term"]) }
        try? await Task.sleep(for: .seconds(0.6))
        let shown = vm.claudeRequest
        log("claude: notch shows \(vm.liveActivity.map { "\($0)" } ?? "nothing") “\(shown?.summary ?? "")” in \(shown?.project ?? "?") (want claudeAsk “rm -rf build” in NotchNest)")
        if let shown { bridge.answer(shown.id, .allow) }
        let (_, allowBody) = await asking.value
        log("claude: Allow sends \(allowBody.contains(#""behavior":"allow""#) ? "allow" : "“\(allowBody)”") (want allow)")

        // Terminal in front: stay out of the way.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        let (_, frontBody) = await post(port, "/claude/permission", bash, headers: ["X-NotchNest": "1", "X-App": front])
        log("claude: asked while its app (\(front)) is in front → \(frontBody.isEmpty ? "left to the terminal" : frontBody), waiting=\(bridge.pending.count) (want left to the terminal, 0)")

        // The exact hook command Claude Code runs, through the shell, answered with Deny.
        let edit: [String: Any] = ["hook_event_name": "PermissionRequest", "tool_name": "Edit", "cwd": "/tmp/proj",
                                   "tool_input": ["file_path": "/tmp/proj/Sources/App.swift"]]
        let command = ClaudeHooks.command(path: "/claude/permission", port: port, maxTime: 20, quiet: false)
        let hook = Task.detached { shell(command, input: edit) }
        try? await Task.sleep(for: .seconds(1))
        let editRequest = bridge.pending.first
        log("claude: hook command shows “\(editRequest?.summary ?? "nothing")” (want “Edit App.swift”)")
        if let editRequest { bridge.answer(editRequest.id, .deny) }
        let hookOutput = await hook.value
        log("claude: hook prints \(hookOutput.contains(#""behavior":"deny""#) ? "deny" : "“\(hookOutput)”") (want deny)")

        // Claude Code gives up on the hook (answered in the terminal): the notch lets go too.
        let impatient = ClaudeHooks.command(path: "/claude/permission", port: port, maxTime: 1, quiet: false)
        let gaveUp = Task.detached { shell(impatient, input: bash) }
        try? await Task.sleep(for: .seconds(0.5))
        let before = bridge.pending.count
        _ = await gaveUp.value
        try? await Task.sleep(for: .seconds(0.5))
        log("claude: withdrawn request: waiting \(before) → \(bridge.pending.count) (want 1 → 0)")

        // Finished.
        let stop: [String: Any] = ["hook_event_name": "Stop", "cwd": "/Users/me/NotchNest",
                                   "last_assistant_message": "All 25 checks pass.\nDetails below."]
        let stopCommand = ClaudeHooks.command(path: "/claude/stop", port: port, maxTime: 3, quiet: true)
        let stopOutput = await Task.detached { shell(stopCommand, input: stop) }.value
        try? await Task.sleep(for: .seconds(0.3))
        log("claude: Stop → \(vm.liveActivity.map { "\($0)" } ?? "nothing") “\(vm.claudeDone?.message ?? "")” · \(vm.claudeDone?.project ?? "") hook output=“\(stopOutput)” (want claudeDone “All 25 checks pass.” · NotchNest, empty)")
        vm.openClaudeHost(nil)

        // NotchNest not running: the hook must stay silent so Claude Code asks normally.
        let offline = ClaudeHooks.command(path: "/claude/permission", port: 1, maxTime: 2, quiet: false)
        let offlineOutput = await Task.detached { shell(offline, input: bash) }.value
        log("claude: NotchNest not running → hook output “\(offlineOutput)” (want empty)")
    }

    /// Real mouse events on the closed notch's Allow and Deny buttons (the row under the notch has
    /// to take its own clicks), and on the notch itself (which should still open it).
    private static func clicks(vm: NotchViewModel, notch: NotchController) async {
        notch.showForTest()
        let panel = notch.panel
        let window = NotchController.windowSize
        func click(_ point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                                  clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                    panel.sendEvent(event)
                }
            }
        }
        let bash: [String: Any] = ["tool_name": "Bash", "cwd": "/tmp/proj", "tool_input": ["command": "make test"]]
        for (label, offset, want) in [("Allow", 23.0, "allow"), ("Deny", 74.0, "deny")] {
            let asking = Task { await post(vm.claude.port, "/claude/permission", bash, headers: ["X-NotchNest": "1", "X-App": "com.example.term"]) }
            try? await Task.sleep(for: .seconds(0.8))
            // Right edge of the row's content, then back to the button's centre; the row sits under the notch.
            let right = window.width / 2 + vm.shapeSize.width / 2 - (NotchViewModel.closedFlare + 8)
            let y = window.height - (vm.geometry.notchSize.height + 18)
            click(NSPoint(x: right - offset, y: y))
            let answered = Task { await asking.value }
            try? await Task.sleep(for: .seconds(0.5))
            if !vm.claude.pending.isEmpty, let id = vm.claude.pending.first?.id { vm.claude.answer(id, .terminal) }
            let (_, body) = await answered.value
            log("click \(label) under the closed notch → \(body.contains("\"\(want)\"") ? want : "no answer (“\(body)”)") (want \(want))")
        }
        vm.isOpen = false
        try? await Task.sleep(for: .seconds(0.4))
        click(NSPoint(x: window.width / 2, y: window.height - vm.geometry.notchSize.height / 2))
        try? await Task.sleep(for: .seconds(0.4))
        log("click the notch itself → open=\(vm.isOpen) (want true)")
        vm.isOpen = false
    }

    private static func post(_ port: UInt16, _ path: String, _ json: [String: Any], headers: [String: String]) async -> (Int, String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (0, "") }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
    }

    /// Runs a hook command the way Claude Code does: sh -c, the event's JSON on stdin.
    nonisolated private static func shell(_ command: String, input: [String: Any]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment["__CFBundleIdentifier"] = "com.example.term"
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try? process.run()
        stdin.fileHandleForWriting.write((try? JSONSerialization.data(withJSONObject: input)) ?? Data())
        try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: Hook installer

    private static func hooks() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchNest-hooks-\(UUID().uuidString)")
        let url = folder.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        try? original.write(to: url, atomically: true, encoding: .utf8)
        do {
            try ClaudeHooks.install(at: url, port: 47823)
            try ClaudeHooks.install(at: url, port: 47823)  // twice: must not duplicate
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let ours = text.components(separatedBy: ClaudeHooks.marker).count - 1
            log("hooks installed: detected=\(ClaudeHooks.isInstalled(at: url)) ours=\(ours) keeps model=\(text.contains("\"opus\"")) keeps their Stop hook=\(text.contains("say done")) backup=\(FileManager.default.fileExists(atPath: url.path + ".notchnest-backup")) (want true, 2, true, true, true)")
            try ClaudeHooks.uninstall(at: url)
            let after = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            log("hooks removed: detected=\(ClaudeHooks.isInstalled(at: url)) theirs kept=\(after.contains("say done")) PermissionRequest gone=\(!after.contains("PermissionRequest")) (want false, true, true)")
            try ClaudeHooks.install(at: folder.appendingPathComponent("fresh/settings.json"), port: 47823)
            log("hooks into a missing settings file: detected=\(ClaudeHooks.isInstalled(at: folder.appendingPathComponent("fresh/settings.json"))) (want true)")
        } catch {
            log("hooks failed: \(error.localizedDescription)")
        }
    }

    private static func log(_ line: String) {
        print("featuretest:", line)
        fflush(stdout)
    }
}
