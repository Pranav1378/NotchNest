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
                                                         until: Date().addingTimeInterval(5))
                        DispatchQueue.main.async { completion(pressed ? .pressed : .settingsOnly) }
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

/// Finds a named item in another app's window and clicks it, through the Accessibility interface
/// apps expose for screen readers.
enum AXSearch {
    static let queue = DispatchQueue(label: "NotchNest.accessibility")

    /// Looks for the item until the deadline (settings windows take a moment to appear).
    static func pressItem(pid: pid_t, names: [String], until deadline: Date) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        let wanted = Set(names.map { $0.lowercased() })
        repeat {
            var budget = 6000  // keep the search bounded on big interfaces
            if let item = search(app, wanted: wanted, depth: 0, budget: &budget) {
                press(item)
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    private static func search(_ element: AXUIElement, wanted: Set<String>, depth: Int, budget: inout Int) -> AXUIElement? {
        guard depth < 16, budget > 0 else { return nil }
        budget -= 1
        if matches(element, wanted) { return element }
        for child in children(of: element) {
            if let found = search(child, wanted: wanted, depth: depth + 1, budget: &budget) { return found }
        }
        return nil
    }

    private static func matches(_ element: AXUIElement, _ wanted: Set<String>) -> Bool {
        guard let role = string(element, kAXRoleAttribute), clickableRoles.contains(role) else { return false }
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            guard let text = string(element, attribute)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  wanted.contains(text) else { continue }
            return true
        }
        return false
    }

    /// Roles a settings item can have: a button or link in a web view, a row in a native list.
    private static let clickableRoles: Set<String> = [
        kAXButtonRole, kAXRadioButtonRole, kAXMenuItemRole, kAXCheckBoxRole,
        kAXCellRole, kAXRowRole, kAXStaticTextRole,
        // Web views (the Claude app's settings are a web page) report these as plain strings.
        "AXLink", "AXTab", "AXListItem", "AXMenuListOption",
    ]

    private static func press(_ element: AXUIElement) {
        AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)  // it may be down the list
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return }
        // Plain text has nothing to press: click where it sits instead.
        guard let point = point(element, kAXPositionAttribute), let size = size(element, kAXSizeAttribute) else { return }
        let centre = CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
        let source = CGEventSource(stateID: .combinedSessionState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: centre, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    // MARK: Reading attributes

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
