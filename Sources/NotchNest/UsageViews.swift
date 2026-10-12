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

    /// Where the notch's Claude numbers come from: the Claude app's own file, or Claude Code's
    /// status line when that's fresher (it also knows the reset times).
    static func best(file: ClaudePlanUsage.Sample?, statusLine: ClaudeUsage?) -> (session: Double, week: Double,
                                                                                  at: Date, resets: ClaudeUsage?)? {
        if let statusLine, let file {
            return statusLine.updated > file.at
                ? (statusLine.session?.used ?? 0, statusLine.week?.used ?? 0, statusLine.updated, statusLine)
                : (file.session, file.week, file.at, statusLine)
        }
        if let file { return (file.session, file.week, file.at, nil) }
        if let statusLine { return (statusLine.session?.used ?? 0, statusLine.week?.used ?? 0, statusLine.updated, statusLine) }
        return nil
    }

    /// Settings → "Open usage inside the apps" is off by default: the notch shows the numbers itself.
    static func openClaude() {
        if Prefs.bool(Prefs.usageInAppWindow), AppAutomation.isTrusted, hasClaudeApp,
           NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundle).first != nil {
            AppAutomation.openClaudeUsageInNewWindow(bundleID: claudeBundle,
                                                     link: "claude://claude.ai/settings/usage") { outcome in
                if outcome != .pressed { announce("Opened Claude's usage page") }
            }
            return
        }
        if Prefs.bool(Prefs.claudeUsageInApp) && hasClaudeApp {
            // The Claude app's own link scheme: claude://claude.ai/<page> opens that page in the app.
            open("claude://claude.ai/settings/usage", "Claude (in the app)")
        } else {
            open("https://claude.ai/settings/usage", "Claude")
        }
    }

    /// Gemini keeps no usage on this Mac, so the notch opens the app's own Usage limits screen
    /// (⌘, then the sidebar item). The web page is the fallback.
    static func openGemini() {
        if Prefs.bool(Prefs.geminiOpensApp),
           inAppWindow(bundleID: geminiBundle, names: ["Usage limits", "Usage"], appName: "Gemini") { return }
        open("https://gemini.google.com/usage", "Gemini")
    }

    /// ⌘, in the app, then its Usage item. Returns false when that isn't possible (no permission or
    /// the app isn't installed) so the caller falls back to the usage page.
    private static func inAppWindow(bundleID: String, names: [String], appName: String) -> Bool {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else { return false }
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

    /// claude.ai's usage page, for the exact figures and usage credits.
    static func openClaudePage() {
        open(Prefs.bool(Prefs.claudeUsageInApp) && hasClaudeApp
             ? "claude://claude.ai/settings/usage" : "https://claude.ai/settings/usage", "Claude")
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
    var vm: NotchViewModel?
    
    @State private var hovering = false

    var body: some View {
        Button { press() } label: {
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

    /// Claude shows its numbers in the notch; Gemini has none to read, so its button opens the page.
    /// For --usagetest: the same thing a click does.
    func pressForTest() { press() }

    private func press() {
        if kind == .claude, Prefs.bool(Prefs.usageInAppWindow) {
            UsagePages.openClaude()
        } else if kind == .gemini, Prefs.bool(Prefs.geminiOpensApp) {
            UsagePages.openGemini()  // for people who'd rather jump into Gemini itself
        } else {
            vm?.toggleUsageCard(refreshGemini: kind == .gemini)
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

/// Claude's and Gemini's usage in the notch: no app switching to read them. Claude's come from the
/// Claude app's own file on this Mac; Gemini's are read from its Usage limits screen on request and
/// kept here afterwards.
struct UsageCard: View {
    let vm: NotchViewModel
    @AppStorage(Prefs.geminiUsage) private var geminiEnabled = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 8) {
                claude(now: context.date)
                if geminiEnabled {
                    Divider().overlay(Color.white.opacity(0.08))
                    gemini(now: context.date)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 272, alignment: .leading)
        .background(shape.fill(Color(white: 0.11)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }

    // MARK: Claude

    @ViewBuilder private func claude(now: Date) -> some View {
        let best = UsagePages.best(file: vm.planUsage.latest, statusLine: vm.claude.usage)
        HStack(spacing: 5) {
            Image(systemName: "sparkle").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.claude)
            Text("Claude").font(.system(size: 11, weight: .semibold)).fixedSize()
            if let best { Text("· \(age(best.at, now: now))").font(.system(size: 9)).foregroundStyle(.secondary) }
            Spacer()
            refreshButton(help: "Re-read Claude's numbers (it writes them every 15 minutes)") {
                vm.planUsage.reload()
                let at = UsagePages.best(file: vm.planUsage.latest, statusLine: vm.claude.usage)?.at
                let minutes = at.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
                UsagePages.announce(minutes < 1 ? "Claude's numbers are current"
                                    : "Claude wrote these \(minutes) min ago; it refreshes every 15")
            }
            link("claude.ai") { UsagePages.openClaudePage() }
        }
        if let best {
            bar("Current session", best.session, resets: best.resets?.session?.resetsAt, now: now)
            bar("This week", best.week, resets: best.resets?.week?.resetsAt, now: now)
        } else {
            Text("Open the Claude app once and its numbers appear here.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Gemini

    @ViewBuilder private func gemini(now: Date) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.gemini)
            Text("Gemini").font(.system(size: 11, weight: .semibold)).fixedSize()
            if let reading = vm.gemini.latest {
                Text("· \(age(reading.at, now: now))").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer()
            if vm.gemini.isReading {
                ProgressView().controlSize(.mini)
            } else {
                refreshButton(help: "Read Gemini's usage (its window flashes up for a second)") { vm.gemini.refresh() }
            }
            link("open") { UsagePages.openGemini() }
        }
        if let reading = vm.gemini.latest {
            bar("Current usage", reading.session, now: now, note: reading.sessionResets)
            bar("Weekly limit", reading.week, now: now, note: reading.weekResets)
        } else {
            Text(vm.gemini.isReading ? "Reading Gemini's usage…"
                 : "Press ↻ to read it from the Gemini app; Google keeps no numbers on this Mac.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Pieces

    private func bar(_ title: String, _ used: Double, resets: Date? = nil, now: Date, note: String = "") -> some View {
        let colour = used >= 90 ? Color(red: 0.87, green: 0.33, blue: 0.30) : Color(red: 0.33, green: 0.52, blue: 0.93)
        let caption = resets.map { $0 > now ? "Resets \($0.formatted(date: .omitted, time: .shortened))" : "" } ?? note
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text("\(Int(used.rounded()))% used")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(used >= 90 ? colour : Color.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(colour).frame(width: max(used > 0 ? 4 : 0, geo.size.width * min(used, 100) / 100))
                }
            }
            .frame(height: 5)
            if !caption.isEmpty {
                Text(caption).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private func refreshButton(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(title)
                Image(systemName: "arrow.up.right")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "live" while an app is writing, otherwise how old the numbers are.
    private func age(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 2 { return "live" }
        if minutes < 60 { return "\(minutes) min ago" }
        if minutes < 1440 { return "\(minutes / 60)h ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

extension Color {
    /// Gemini's blue-purple, for its icon and bars.
    static let gemini = Color(red: 0.32, green: 0.55, blue: 0.98)
}
