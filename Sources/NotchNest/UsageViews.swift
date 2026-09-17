import SwiftUI

extension ClaudeUsage.Window {
    /// Once its reset time passes, a window has started over at 0%.
    func live(at now: Date) -> (used: Double, resetsAt: Date?, wasReset: Bool) {
        resetsAt > now ? (used, resetsAt, false) : (0, nil, true)
    }
}

extension ClaudeUsage {
    /// A one-line verdict, like the Usage page's: limit reached, or on track for the weekly reset.
    func headline(at now: Date) -> String {
        if let session = session?.live(at: now), session.used >= 100, let reset = session.resetsAt {
            return "Session limit reached. It resets at \(reset.formatted(date: .omitted, time: .shortened))."
        }
        guard let week = self.week else { return "Usage from your last Claude Code session." }
        let live = week.live(at: now)
        let day = (live.resetsAt ?? week.resetsAt.addingTimeInterval(7 * 86_400)).formatted(.dateTime.weekday(.wide))
        if live.used >= 100 { return "Weekly limit reached. It resets \(day)." }
        // How far through the week we are, against how much of the week's allowance is used.
        let start = week.resetsAt.addingTimeInterval(-7 * 86_400)
        let elapsed = min(max(now.timeIntervalSince(start) / (7 * 86_400), 0), 1) * 100
        if live.wasReset || live.used <= elapsed + 5 { return "On track. You should reach \(day)'s reset with room to spare." }
        return "Going faster than usual: \(Int(live.used.rounded()))% used, \(Int(elapsed.rounded()))% of the week gone."
    }
}

/// The usage pages with the exact figures.
@MainActor
enum UsagePages {
    static let claudeBundle = "com.anthropic.claudefordesktop"
    static let geminiBundle = "com.google.GeminiMacOS"

    static var hasClaudeApp: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundle) != nil }
    static var hasGeminiApp: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: geminiBundle) != nil }
    /// Says what happened, through the notch's toast.
    static var announce: (String) -> Void = { _ in }
    private static var askedForTrust = false

    static func openClaude() {
        // First choice: the app's own usage window, over whatever you were doing.
        if inAppWindow(bundleID: claudeBundle, names: ["Usage"], appName: "Claude") { return }
        if Prefs.bool(Prefs.claudeUsageInApp) && hasClaudeApp {
            // The Claude app's own link scheme: claude://claude.ai/<page> opens that page in the app.
            open("claude://claude.ai/settings/usage", "Claude (in the app)")
        } else {
            open("https://claude.ai/settings/usage", "Claude")
        }
    }

    static func openGemini() {
        if inAppWindow(bundleID: geminiBundle, names: ["Usage limits", "Usage"], appName: "Gemini") { return }
        // Gemini's usage page on the web, for when its own window can't be opened.
        open("https://gemini.google.com/usage", "Gemini")
    }

    /// ⌘, in the app, then its Usage item. Returns false when that isn't possible (no permission,
    /// app not installed, or the setting is off) so the caller falls back to the usage page.
    private static func inAppWindow(bundleID: String, names: [String], appName: String) -> Bool {
        guard Prefs.bool(Prefs.usageInAppWindow),
              NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else { return false }
        guard AppAutomation.isTrusted else {
            // Ask once per launch, then fall back to the usage page for this click.
            if !askedForTrust {
                askedForTrust = true
                AppAutomation.requestTrust()
                announce("Allow Accessibility to open usage inside \(appName)")
                ActivityLog.note("usage window needs Accessibility permission")
            }
            return false
        }
        AppAutomation.openUsage(bundleID: bundleID, itemNames: names) { outcome in
            ActivityLog.note("\(appName) usage window: \(outcome.rawValue)")
            if outcome == .settingsOnly {
                announce("Opened \(appName) settings — pick \(names[0])")
            }
        }
        return true
    }

    private static func open(_ address: String, _ name: String) {
        ActivityLog.note("opened the \(name) usage page")
        NSWorkspace.shared.open(URL(string: address)!)
    }
}

/// A small header icon that opens Claude's or Gemini's usage page in one click.
struct UsageIconButton: View {
    enum Kind { case claude, gemini }

    let kind: Kind
    let claude: ClaudeBridge
    @State private var hovering = false

    var body: some View {
        Button { if kind == .claude { UsagePages.openClaude() } else { UsagePages.openGemini() } } label: {
            icon
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }

    @ViewBuilder private var icon: some View {
        switch kind {
        case .claude:
            Image(systemName: "sparkle").foregroundStyle(Color.claude)
        case .gemini:
            Image(systemName: "sparkles").foregroundStyle(
                LinearGradient(colors: [Color(red: 0.26, green: 0.52, blue: 0.96), Color(red: 0.62, green: 0.45, blue: 0.93)],
                               startPoint: .bottomLeading, endPoint: .topTrailing))
        }
    }

    private var help: String {
        switch kind {
        case .gemini:
            return "Gemini usage"
        case .claude:
            // If a Terminal session has reported usage, the tooltip carries it.
            guard let session = claude.usage?.session?.live(at: .now), let reset = session.resetsAt else { return "Claude usage" }
            return "Claude usage · session \(Int(session.used.rounded()))%, resets \(reset.formatted(date: .omitted, time: .shortened))"
        }
    }
}
