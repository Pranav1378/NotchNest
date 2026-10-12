import AppKit
import ApplicationServices

/// Opens another app's own usage window the way you would: bring the app forward, press ⌘, for its
/// settings, then click the "Usage" item. Its settings open over whatever you were doing, so your
/// chat stays where it was. Needs macOS Accessibility permission; without it the caller falls back
/// to opening the usage page in the browser.
@MainActor
enum AppAutomation {
    enum Outcome: String {
        case pressed          // settings opened and the usage item was clicked
        case settingsOnly     // settings opened, but the item wasn't found
        case notTrusted       // no Accessibility permission
        case noApp            // the app isn't installed
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's "allow Accessibility" prompt. The user still flips the switch themselves.
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// How an app shows its usage.
    enum Route {
        /// Click the app's menu-bar icon: its menu carries the usage rows (the Claude app).
        case menuBarItem
        /// ⌘, then click a named item in the app's settings (the Gemini app).
        case settingsItem([String])
    }

    /// Claude has no usage screen its settings can reach, and its menu-bar icon opens a chat box.
    /// So: open a brand-new Claude window and send that one to the usage page, leaving the chat you
    /// were in exactly where it was.
    static func openClaudeUsageInNewWindow(bundleID: String, link: String, completion: @escaping (Outcome) -> Void) {
        guard isTrusted else {
            completion(.notTrusted)
            return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            completion(.noApp)
            return
        }
        app.activate()
        let pid = app.processIdentifier
        AXSearch.queue.async {
            let opened = AXSearch.pressItem(pid: pid, names: ["New Session in New Window", "New Window"],
                                            until: Date().addingTimeInterval(3))
            Thread.sleep(forTimeInterval: opened ? 1.4 : 0)
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL(string: link)!)
                ActivityLog.note("claude usage: new window=\(opened), then \(link)")
                completion(opened ? .pressed : .settingsOnly)
            }
        }
    }

    /// Opens the app's menu-bar menu, which shows usage without switching apps or losing your place.
    static func openMenuBarItem(bundleID: String, completion: @escaping (Outcome) -> Void) {
        guard isTrusted else {
            completion(.notTrusted)
            return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            completion(.noApp)  // not running: nothing in the menu bar to click
            return
        }
        let pid = app.processIdentifier
        AXSearch.queue.async {
            let pressed = AXSearch.pressMenuBarItem(pid: pid)
            DispatchQueue.main.async { completion(pressed ? .pressed : .settingsOnly) }
        }
    }

    static func openUsage(bundleID: String, itemNames: [String], completion: @escaping (Outcome) -> Void) {
        guard isTrusted else {
            completion(.notTrusted)
            return
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            completion(.noApp)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, _ in
            guard let app else {
                DispatchQueue.main.async { completion(.noApp) }
                return
            }
            let pid = app.processIdentifier
            // Give it a moment to come forward, or ⌘, goes to the app you were just in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated {
                    app.activate()
                    settingsShortcut(to: pid)
                    AXSearch.queue.async {
                        let pressed = AXSearch.pressItem(pid: pid, names: itemNames,
                                                         until: Date().addingTimeInterval(8))
                        DispatchQueue.main.async { completion(pressed ? .pressed : .settingsOnly) }
                    }
                }
            }
        }
    }

    /// Brings the app up, opens its settings, clicks a panel, reads every line of text, then closes
    /// the window again. The caller puts focus back where it was.
    static func readUsagePanel(bundleID: String, item: String, completion: @escaping ([String]) -> Void) {
        guard isTrusted, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            completion([])
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, _ in
            guard let app else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let pid = app.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    app.activate()
                    settingsShortcut(to: pid)
                    AXSearch.queue.async {
                        let pressed = AXSearch.pressItem(pid: pid, names: [item], until: Date().addingTimeInterval(5))
                        Thread.sleep(forTimeInterval: pressed ? 1.0 : 0)
                        let lines = AXSearch.texts(pid: pid)
                        DispatchQueue.main.async {
                            closeWindowShortcut(to: pid)
                            ActivityLog.note("read \(item) in \(bundleID): pressed=\(pressed), \(lines.count) lines")
                            completion(lines)
                        }
                    }
                }
            }
        }
    }

    /// Reads a settings panel with nothing appearing on screen: the app is never brought forward,
    /// its settings window opens in the background, the row is selected the way a screen reader
    /// would, the text is read, and the window is closed again.
    static func quietUsageRead(bundleID: String, item: String, completion: @escaping ([String]) -> Void) {
        guard isTrusted, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            completion([])  // not running: launching it would put it on screen, which is the thing to avoid
            return
        }
        let pid = app.processIdentifier
        AXSearch.queue.async {
            // Note the windows that are already open, so the new one can be told apart.
            let before = AXSearch.windowIDs(pid: pid)
            DispatchQueue.main.async { settingsShortcut(to: pid) }
            // Catch it the moment it appears and park it off-screen, so it's never seen.
            let window = AXSearch.waitForNewWindow(pid: pid, notIn: before, until: Date().addingTimeInterval(3))
            let parked = window.map { AXSearch.moveOffScreen($0) } ?? false
            let picked = AXSearch.selectRowQuietly(pid: pid, named: item)
            Thread.sleep(forTimeInterval: picked ? 0.8 : 0)
            let lines = picked ? AXSearch.texts(pid: pid) : []
            if let window { AXSearch.closeWindow(window) }
            DispatchQueue.main.async {
                if window == nil { closeWindowShortcut(to: pid) }
                ActivityLog.note("quiet read of \(item): parked=\(parked), picked=\(picked), \(lines.count) lines")
                completion(lines)
            }
        }
    }

    /// Experiment: which accessibility trick can switch a settings panel while the window is NOT in
    /// front? If one works, Gemini's numbers can be refreshed with nothing appearing on screen.
    static func quietStrategies(bundleID: String, item: String, completion: @escaping ([String]) -> Void) {
        guard isTrusted, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            completion(["app isn't running"])
            return
        }
        let pid = app.processIdentifier
        settingsShortcut(to: pid)
        AXSearch.queue.asyncAfter(deadline: .now() + 1.5) {
            let results = AXSearch.trySelecting(pid: pid, named: item)
            DispatchQueue.main.async {
                closeWindowShortcut(to: pid)
                completion(results)
            }
        }
    }

    /// Experiment: open an app's settings WITHOUT bringing it to the front, read a panel, close it.
    /// If this works, Gemini's numbers can land in the notch with no app switch at all.
    static func quietRead(bundleID: String, item: String, completion: @escaping ([String]) -> Void) {
        guard isTrusted, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            completion([])
            return
        }
        let pid = app.processIdentifier
        settingsShortcut(to: pid)
        AXSearch.queue.asyncAfter(deadline: .now() + 1.2) {
            let pressed = AXSearch.selectItem(pid: pid, named: item)
            Thread.sleep(forTimeInterval: 1.2)
            let lines = AXSearch.texts(pid: pid)
            DispatchQueue.main.async {
                closeWindowShortcut(to: pid)
                ActivityLog.note("quiet read of \(item): \(pressed), \(lines.count) lines")
                completion(lines)
            }
        }
    }

    /// ⌘W, to put the window away again.
    static func closeWindowShortcut(to pid: pid_t) {
        let w: CGKeyCode = 0x0D
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: w, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: w, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
    }

    /// `--axdump <bundle id>`: opens the app's settings and prints every named element, so the
    /// item to click can be found by its real label instead of a guess.
    static func dumpSettingsTree(bundleID: String, pressing items: [String] = [], completion: @escaping () -> Void) {
        guard isTrusted, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            print("axdump: not trusted, or \(bundleID) isn't installed")
            completion()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, _ in
            guard let app else {
                completion()
                return
            }
            let pid = app.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated {
                    app.activate()
                    // "asis" dumps what's already on screen instead of opening settings first.
                    if !items.contains("asis") { settingsShortcut(to: pid) }
                    AXSearch.queue.asyncAfter(deadline: .now() + 2.5) {
                        for item in items where item != "asis" {
                            let pressed = AXSearch.pressItem(pid: pid, names: [item],
                                                             until: Date().addingTimeInterval(4))
                            print("axdump: pressing “\(item)” → \(pressed)")
                            Thread.sleep(forTimeInterval: 1.5)
                        }
                        AXSearch.dump(pid: pid)
                        DispatchQueue.main.async { completion() }
                    }
                }
            }
        }
    }

    /// ⌘, — the standard Settings shortcut every Mac app has.
    private static func settingsShortcut(to pid: pid_t) {
        let comma: CGKeyCode = 0x2B
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: comma, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: comma, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
    }
}

extension AXSearch {
    /// Clicks an app's menu-bar (status) icon, which hangs off its own attribute rather than the
    /// app's windows.
    static func pressMenuBarItem(pid: pid_t, rightClick: Bool = false) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        var extras: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extras) == .success,
              let bar = extras, CFGetTypeID(bar) == AXUIElementGetTypeID() else {
            ActivityLog.note("ax: no menu-bar item for pid \(pid)")
            return false
        }
        for item in childElements(of: bar as! AXUIElement) {
            if rightClick {
                click(item, rightButton: true)
                ActivityLog.note("ax: right-clicked the menu-bar item")
                return true
            }
            if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
                ActivityLog.note("ax: opened the menu-bar menu")
                return true
            }
        }
        ActivityLog.note("ax: couldn't press the menu-bar item")
        return false
    }
}

/// Finds a named item in another app's window and clicks it, through the Accessibility interface
/// apps expose for screen readers.
enum AXSearch {
    static let queue = DispatchQueue(label: "NotchNest.accessibility")

    /// Looks for the item until the deadline (settings windows take a moment to appear).
    static func pressItem(pid: pid_t, names: [String], until deadline: Date) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        // Electron and Chrome apps (the Claude app is one) only build the accessibility tree other
        // apps can read once someone asks for it.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.8)
        clearSearchFields(app)
        let wanted = Set(names.map { $0.lowercased() })
        var visited = 0
        var fallback: AXUIElement?
        repeat {
            if let found = find(app, wanted: wanted, visited: &visited, weak: &fallback) {
                press(found)
                ActivityLog.note("ax: clicked \(describe(found)) after \(visited) nodes")
                return true
            }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        if let fallback {
            press(fallback)
            ActivityLog.note("ax: clicked text \(describe(fallback)) after \(visited) nodes")
            return true
        }
        ActivityLog.note("ax: nothing named \(names.joined(separator: "/")) in \(visited) nodes")
        return false
    }

    /// Breadth-first: settings items sit near the window's surface, while web views run deep.
    private static func find(_ app: AXUIElement, wanted: Set<String>, visited: inout Int,
                             weak fallback: inout AXUIElement?) -> AXUIElement? {
        var queue: [(element: AXUIElement, depth: Int)] = [(app, 0)]
        var index = 0
        while index < queue.count, visited < 25_000 {
            let (element, depth) = queue[index]
            index += 1
            visited += 1
            // Menu items in a closed menu have no size yet, but pressing them still works.
            if let role = string(element, kAXRoleAttribute), label(element, wanted) != nil,
               role == kAXMenuItemRole || onScreen(element) {
                if clickableRoles.contains(role) { return element }
                // Plain text is a last resort: its clickable parent is usually what we want.
                if role == kAXStaticTextRole && fallback == nil { fallback = element }
            }
            guard depth < 40 else { continue }
            for child in children(of: element) { queue.append((child, depth + 1)) }
        }
        return nil
    }

    /// Something to tell windows apart by: their position and size as a string.
    static func windowIDs(pid: pid_t) -> Set<String> {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return Set(windows.map { describeWindow($0) })
    }

    private static func describeWindow(_ window: AXUIElement) -> String {
        let title = string(window, kAXTitleAttribute) ?? ""
        let origin = point(window, kAXPositionAttribute) ?? .zero
        let size = size(window, kAXSizeAttribute) ?? .zero
        return "\(title)|\(Int(size.width))x\(Int(size.height))|\(Int(origin.x)),\(Int(origin.y))"
    }

    /// Waits for a window that wasn't there before (the settings window ⌘, just opened).
    static func waitForNewWindow(pid: pid_t, notIn before: Set<String>, until deadline: Date) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        repeat {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
               let windows = value as? [AXUIElement],
               let fresh = windows.first(where: { !before.contains(describeWindow($0)) }) {
                return fresh
            }
            Thread.sleep(forTimeInterval: 0.05)  // catch it before it can be seen
        } while Date() < deadline
        return nil
    }

    /// Parks a window far off every screen while it's read.
    static func moveOffScreen(_ window: AXUIElement) -> Bool {
        var corner = CGPoint(x: -30_000, y: -30_000)
        guard let value = AXValueCreate(.cgPoint, &corner) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    /// Closes a window with its own close button, rather than ⌘W, which would go to whatever is key.
    static func closeWindow(_ window: AXUIElement) {
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success,
              let button, CFGetTypeID(button) == AXUIElementGetTypeID() else { return }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    }

    /// Selects a sidebar row without the window being in front. Setting AXSelected on the row (the
    /// element two levels above the label) is what Gemini's settings respond to.
    static func selectRowQuietly(pid: pid_t, named name: String) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        guard let label = element(in: app, named: name) else { return false }
        var current = label
        for _ in 0..<4 {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = parent as! AXUIElement
            guard AXUIElementSetAttributeValue(current, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success
            else { continue }
            Thread.sleep(forTimeInterval: 0.9)
            if texts(pid: pid).contains(where: { $0.contains("% used") }) { return true }
        }
        return false
    }

    /// Tries every way of choosing a sidebar row without the window being in front, and reports
    /// which one actually changed the panel.
    static func trySelecting(pid: pid_t, named name: String) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        guard let row = element(in: app, named: name) else { return ["couldn't find “\(name)”"] }
        var notes: [String] = []
        func panelChanged() -> Bool {
            Thread.sleep(forTimeInterval: 1.0)
            return texts(pid: pid).contains { $0.contains("% used") }
        }
        // 1. The row's own actions.
        var actions: CFArray?
        AXUIElementCopyActionNames(row, &actions)
        notes.append("row is \(string(row, kAXRoleAttribute) ?? "?") with actions \((actions as? [String] ?? []).joined(separator: ","))")
        for action in (actions as? [String] ?? []) {
            if AXUIElementPerformAction(row, action as CFString) == .success, panelChanged() {
                return notes + ["WORKS: row action \(action)"]
            }
        }
        // 2. Mark the row selected, or focused.
        for attribute in [kAXSelectedAttribute, kAXFocusedAttribute] {
            if AXUIElementSetAttributeValue(row, attribute as CFString, kCFBooleanTrue) == .success, panelChanged() {
                return notes + ["WORKS: set \(attribute) on the row"]
            }
        }
        // 3. Climb the ancestors: the selectable thing is usually a row, or the outline above it.
        var ancestors: [AXUIElement] = []
        var current = row
        for _ in 0..<6 {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = parent as! AXUIElement
            ancestors.append(current)
        }
        notes.append("ancestors: \(ancestors.compactMap { string($0, kAXRoleAttribute) }.joined(separator: " → "))")
        for (depth, ancestor) in ancestors.enumerated() {
            let role = string(ancestor, kAXRoleAttribute) ?? "?"
            var actions: CFArray?
            AXUIElementCopyActionNames(ancestor, &actions)
            for action in (actions as? [String] ?? []) {
                if AXUIElementPerformAction(ancestor, action as CFString) == .success, panelChanged() {
                    return notes + ["WORKS: \(action) on the \(role) \(depth) levels up"]
                }
            }
            for attribute in [kAXSelectedAttribute, kAXFocusedAttribute] {
                if AXUIElementSetAttributeValue(ancestor, attribute as CFString, kCFBooleanTrue) == .success, panelChanged() {
                    return notes + ["WORKS: set \(attribute) on the \(role) \(depth) levels up"]
                }
            }
            // Tell a list/outline which of its rows is chosen.
            for attribute in [kAXSelectedChildrenAttribute, kAXSelectedRowsAttribute] {
                for candidate in [row] + ancestors.prefix(depth) {
                    if AXUIElementSetAttributeValue(ancestor, attribute as CFString, [candidate] as CFArray) == .success,
                       panelChanged() {
                        return notes + ["WORKS: set \(attribute) on the \(role) \(depth) levels up"]
                    }
                }
            }
        }
        return notes + ["nothing worked while the window was in the background"]
    }

    private static func element(in app: AXUIElement, named name: String) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(app, 0)]
        var index = 0
        let wanted = name.lowercased()
        while index < queue.count, index < 20_000 {
            let (element, depth) = queue[index]
            index += 1
            let matches = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                .compactMap { string(element, $0)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .contains(wanted)
            if matches { return element }
            if depth < 40 { for child in children(of: element) { queue.append((child, depth + 1)) } }
        }
        return nil
    }

    /// Picks a row in a window that isn't in front, where a mouse click would land on the wrong app:
    /// tries the actions a screen reader would use, and reports which one took.
    static func selectItem(pid: pid_t, named name: String) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        var queue: [(AXUIElement, Int)] = [(app, 0)]
        var index = 0
        let wanted = name.lowercased()
        while index < queue.count, index < 20_000 {
            let (element, depth) = queue[index]
            index += 1
            let matches = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                .compactMap { string(element, $0)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .contains(wanted)
            if matches {
                for action in ["AXPick", kAXPressAction, "AXOpen", "AXShowMenu"] {
                    if AXUIElementPerformAction(element, action as CFString) == .success {
                        Thread.sleep(forTimeInterval: 0.8)
                        if texts(pid: pid).contains(where: { $0.contains("%") || $0.lowercased().contains("resets") }) {
                            return action
                        }
                    }
                }
                if AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success {
                    Thread.sleep(forTimeInterval: 0.8)
                    return "selected"
                }
                // Its parent row may be the selectable one.
                var parent: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                   let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() {
                    let row = parent as! AXUIElement
                    for action in ["AXPick", kAXPressAction] where AXUIElementPerformAction(row, action as CFString) == .success {
                        Thread.sleep(forTimeInterval: 0.8)
                        return "parent \(action)"
                    }
                }
                return "found, nothing worked"
            }
            if depth < 40 { for child in children(of: element) { queue.append((child, depth + 1)) } }
        }
        return "not found"
    }

    /// Every readable line of text in the app's windows (not menus), for reading a panel.
    static func texts(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        var queue: [(AXUIElement, Int)] = [(app, 0)]
        var index = 0
        var lines: [String] = []
        while index < queue.count, index < 8000 {
            let (element, depth) = queue[index]
            index += 1
            let role = string(element, kAXRoleAttribute) ?? ""
            if role == kAXMenuRole || role == kAXMenuBarRole { continue }
            if role == kAXStaticTextRole || role == kAXHeadingRole || role == "AXUnknown",
               let text = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
                   .compactMap({ string(element, $0) })
                   .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                lines.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if depth < 40 { for child in children(of: element) { queue.append((child, depth + 1)) } }
        }
        return lines
    }

    /// Prints every named element, depth-tagged, for `--axdump`.
    static func dump(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 1.5)  // the tree appears a moment after being switched on
        clearSearchFields(app)
        var queue: [(AXUIElement, Int)] = [(app, 0)]
        // Menu-bar (status item) menus hang off a separate attribute, not the app's children.
        var extras: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extras) == .success,
           let bar = extras, CFGetTypeID(bar) == AXUIElementGetTypeID() {
            print("axdump: this app has a menu-bar item")
            queue.append((bar as! AXUIElement, 1))
        }
        var index = 0
        var printed = 0
        while index < queue.count, index < 40_000 {
            let (element, depth) = queue[index]
            index += 1
            let role = string(element, kAXRoleAttribute) ?? "?"
            let names = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                .compactMap { string(element, $0) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if let name = names.first, name.count < 60 {
                print("axdump \(depth)\t\(role)\t\(name)")
                printed += 1
            }
            if depth < 40 { for child in children(of: element) { queue.append((child, depth + 1)) } }
        }
        print("axdump: \(printed) named elements of \(index) visited")
        fflush(stdout)
    }

    /// A settings search box with text in it hides most of the list, so empty it first.
    static func clearSearchFields(_ app: AXUIElement) {
        var queue: [(AXUIElement, Int)] = [(app, 0)]
        var index = 0
        while index < queue.count, index < 4000 {
            let (element, depth) = queue[index]
            index += 1
            if string(element, kAXRoleAttribute) == kAXTextFieldRole {
                let hints = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute]
                    .compactMap { string(element, $0)?.lowercased() }
                if hints.contains(where: { $0.contains("search") }),
                   let current = string(element, kAXValueAttribute), !current.isEmpty {
                    AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, "" as CFTypeRef)
                    ActivityLog.note("ax: cleared a settings search box that said “\(current)”")
                    Thread.sleep(forTimeInterval: 0.6)
                }
            }
            if depth < 30 { for child in children(of: element) { queue.append((child, depth + 1)) } }
        }
    }

    /// The element's name, when it matches one we're looking for.
    private static func label(_ element: AXUIElement, _ wanted: Set<String>) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            guard let text = string(element, attribute)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  wanted.contains(text) else { continue }
            return text
        }
        return nil
    }

    private static func describe(_ element: AXUIElement) -> String {
        let role = string(element, kAXRoleAttribute) ?? "?"
        let name = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute)
            ?? string(element, kAXValueAttribute) ?? "?"
        return "\(role) “\(name)”"
    }

    /// Roles a settings item can have: a button or link in a web view, a row in a native list.
    private static let clickableRoles: Set<String> = [
        kAXButtonRole, kAXRadioButtonRole, kAXMenuItemRole, kAXCheckBoxRole,
        kAXCellRole, kAXRowRole, kAXPopUpButtonRole,
        // Web views report these as plain strings.
        "AXLink", "AXTab", "AXListItem", "AXMenuListOption", "AXDisclosureTriangle",
        // Gemini's settings rows report no role at all.
        "AXUnknown", "AXGroup",
    ]

    /// Something with a real place on screen (zero-size nodes are leftovers that can't be clicked).
    private static func onScreen(_ element: AXUIElement) -> Bool {
        guard let size = size(element, kAXSizeAttribute) else { return false }
        return size.width > 1 && size.height > 1
    }

    private static func press(_ element: AXUIElement) {
        AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)  // it may be down the list
        let role = string(element, kAXRoleAttribute) ?? ""
        // A row that reports no role (Gemini's settings list) says AXPress worked when it didn't,
        // so those get a real click where they sit.
        if role != "AXUnknown" && role != kAXGroupRole,
           AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return }
        click(element)
    }

    static func click(_ element: AXUIElement, rightButton: Bool = false) {
        guard let origin = point(element, kAXPositionAttribute), let size = size(element, kAXSizeAttribute) else { return }
        let centre = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        ActivityLog.note("ax: clicking at \(Int(centre.x)),\(Int(centre.y))")
        clickAt(centre, rightButton: rightButton)
    }

    static func clickAt(_ point: CGPoint, rightButton: Bool = false) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let button: CGMouseButton = rightButton ? .right : .left
        let down: CGEventType = rightButton ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = rightButton ? .rightMouseUp : .leftMouseUp
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
        usleep(80_000)
        for type in [down, up] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)?
                .post(tap: .cghidEventTap)
            usleep(40_000)
        }
    }

    // MARK: Reading attributes

    static func childElements(of element: AXUIElement) -> [AXUIElement] { children(of: element) }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let wrapped = value, CFGetTypeID(wrapped) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(wrapped as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let wrapped = value, CFGetTypeID(wrapped) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(wrapped as! AXValue, .cgSize, &size) ? size : nil
    }
}
