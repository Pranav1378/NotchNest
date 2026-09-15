import AppKit

/// A countdown in the notch: a plain timer, or Pomodoro (focus and break, back and forth).
@Observable @MainActor
final class FocusTimer {
    enum Kind: Equatable { case timer, focus, rest }

    private(set) var kind: Kind = .timer
    private(set) var total: TimeInterval = 0
    /// Set while counting down.
    private(set) var endDate: Date?
    /// Set while paused.
    private(set) var pausedRemaining: TimeInterval?
    /// Changes with every new countdown, so a hidden live activity comes back for the next one.
    private(set) var runID = UUID()
    private(set) var focusSessionsToday = 0
    @ObservationIgnored var onFinish: (_ title: String, _ detail: String) -> Void = { _, _ in }
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var countedDay = Calendar.current.startOfDay(for: .now)

    var isActive: Bool { endDate != nil || pausedRemaining != nil }
    var isPaused: Bool { pausedRemaining != nil }
    var isPomodoro: Bool { kind != .timer }

    static var focusMinutes: Int { max(1, Prefs.int(Prefs.pomodoroFocus)) }
    static var breakMinutes: Int { max(1, Prefs.int(Prefs.pomodoroBreak)) }

    var title: String {
        switch kind {
        case .timer: return "Timer"
        case .focus: return "Focus"
        case .rest: return "Break"
        }
    }

    func remaining(at date: Date = .now) -> TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        guard let endDate else { return 0 }
        return max(0, endDate.timeIntervalSince(date))
    }

    func start(minutes: Double) { begin(.timer, seconds: minutes * 60) }
    func startPomodoro() { begin(.focus, seconds: Double(Self.focusMinutes) * 60) }

    func pause() {
        guard let endDate else { return }
        pausedRemaining = max(0, endDate.timeIntervalSinceNow)
        self.endDate = nil
        ticker?.invalidate()
        ticker = nil
    }

    func resume() {
        guard let pausedRemaining else { return }
        endDate = Date().addingTimeInterval(pausedRemaining)
        self.pausedRemaining = nil
        startTicker()
    }

    func addMinute() {
        if let pausedRemaining { self.pausedRemaining = pausedRemaining + 60 }
        if let endDate { self.endDate = endDate.addingTimeInterval(60) }
        total += 60
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        endDate = nil
        pausedRemaining = nil
        kind = .timer
        ActivityLog.note("timer stopped")
    }

    /// Pomodoro: jump straight to the next phase.
    func skip() {
        guard isPomodoro else { return }
        next(after: kind, announce: false)
    }

    private func begin(_ kind: Kind, seconds: TimeInterval) {
        self.kind = kind
        total = seconds
        endDate = Date().addingTimeInterval(seconds)
        pausedRemaining = nil
        runID = UUID()
        startTicker()
        ActivityLog.note("timer: \(title.lowercased()) \(Self.format(seconds))")
    }

    private func startTicker() {
        ticker?.invalidate()
        let ticker = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func check() {
        guard let endDate, endDate <= Date() else { return }
        ticker?.invalidate()
        ticker = nil
        if kind == .timer {
            let length = total
            self.endDate = nil
            ActivityLog.note("timer finished")
            onFinish("Time's up", Self.format(length) + " timer")
        } else {
            next(after: kind, announce: true)
        }
    }

    private func next(after finished: Kind, announce: Bool) {
        let today = Calendar.current.startOfDay(for: .now)
        if today != countedDay {
            countedDay = today
            focusSessionsToday = 0
        }
        if finished == .focus && announce { focusSessionsToday += 1 }
        let upcoming: Kind = finished == .focus ? .rest : .focus
        let minutes = upcoming == .focus ? Self.focusMinutes : Self.breakMinutes
        if Prefs.bool(Prefs.pomodoroAuto) || !announce {
            begin(upcoming, seconds: Double(minutes) * 60)
        } else {
            // Wait on the next phase, paused at its full length, until you press play.
            kind = upcoming
            total = Double(minutes) * 60
            endDate = nil
            pausedRemaining = total
            runID = UUID()
        }
        if announce {
            onFinish(finished == .focus ? "Focus done" : "Break's over",
                     upcoming == .focus ? "Focus · \(minutes) min" : "Break · \(minutes) min")
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
