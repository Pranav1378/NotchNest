import AppKit

/// Gemini's usage, read from the Gemini app's own "Usage limits" screen. Google keeps nothing on
/// this Mac to read, and its window only fills in when it's in front, so NotchNest brings it up for
/// about a second, reads the text, closes the window and hands focus back. The numbers are then
/// kept here, so the notch can show them without touching Gemini again.
@Observable @MainActor
final class GeminiUsage {
    struct Reading: Codable, Equatable {
        var session: Double
        var sessionResets: String
        var week: Double
        var weekResets: String
        var at: Date
    }

    private(set) var latest: Reading?
    private(set) var isReading = false
    @ObservationIgnored var announce: (String) -> Void = { _ in }

    init() {
        if let data = UserDefaults.standard.data(forKey: Prefs.geminiUsageCache) {
            latest = try? JSONDecoder().decode(Reading.self, from: data)
        }
    }

    var isStale: Bool {
        guard let latest else { return true }
        return Date().timeIntervalSince(latest.at) > 20 * 60
    }

    /// Reads the numbers, unless a read is already running.
    func refresh() {
        guard !isReading, UsagePages.hasGeminiApp else { return }
        guard AppAutomation.isTrusted else {
            announce("Allow Accessibility to read Gemini's usage")
            return
        }
        isReading = true
        let wasFront = NSWorkspace.shared.frontmostApplication
        AppAutomation.readUsagePanel(bundleID: UsagePages.geminiBundle, item: "Usage limits") { [weak self] lines in
            guard let self else { return }
            isReading = false
            wasFront?.activate()  // straight back to what you were doing
            guard let reading = Self.parse(lines) else {
                ActivityLog.note("gemini usage: couldn't read the panel (\(lines.count) lines)")
                announce("Couldn't read Gemini's usage")
                return
            }
            latest = reading
            if let data = try? JSONEncoder().encode(reading) {
                UserDefaults.standard.set(data, forKey: Prefs.geminiUsageCache)
            }
            ActivityLog.note("gemini usage: session \(Int(reading.session))%, week \(Int(reading.week))%")
        }
    }

    /// The panel reads: "Current usage" → "5% used" → "Resets at 3:02 PM", then "Weekly limit" → …
    static func parse(_ lines: [String]) -> Reading? {
        func after(_ heading: String) -> (used: Double, resets: String)? {
            guard let start = lines.firstIndex(where: { $0.caseInsensitiveCompare(heading) == .orderedSame })
            else { return nil }
            var used: Double?
            var resets = ""
            for line in lines[start...].dropFirst().prefix(6) {
                if used == nil, let percent = percentage(line) { used = percent }
                if resets.isEmpty, line.lowercased().hasPrefix("resets") { resets = line }
                if used != nil, !resets.isEmpty { break }
            }
            return used.map { ($0, resets) }
        }
        guard let session = after("Current usage"), let week = after("Weekly limit") else { return nil }
        return Reading(session: session.used, sessionResets: session.resets,
                       week: week.used, weekResets: week.resets, at: Date())
    }

    /// "5% used" → 5
    private static func percentage(_ line: String) -> Double? {
        guard let percent = line.firstIndex(of: "%") else { return nil }
        let digits = line[..<percent].reversed().prefix { $0.isNumber || $0 == "." }.reversed()
        return Double(String(digits))
    }
}
