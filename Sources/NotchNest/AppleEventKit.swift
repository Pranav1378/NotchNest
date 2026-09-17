import EventKit
import SwiftUI

/// Apple Calendar and Apple Reminders through EventKit: the calendars and lists already on this Mac
/// (iCloud, Exchange, anything added in System Settings → Internet Accounts). Each stays off until
/// it's turned on in Settings → Apple, which is when macOS asks for access.
@Observable @MainActor
final class AppleEventKit {
    nonisolated static let listPrefix = "apple:"

    @ObservationIgnored let store = EKEventStore()
    private(set) var eventsStatus = EKEventStore.authorizationStatus(for: .event)
    private(set) var remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
    @ObservationIgnored private var handlers: [() -> Void] = []
    /// Calendars and Reminders lists switched off in Settings → Apple.
    private(set) var hidden = Set(UserDefaults.standard.stringArray(forKey: Prefs.appleHiddenCalendars) ?? [])

    struct Source: Identifiable, Hashable {
        let id: String
        let title: String
        let color: Color
    }

    var eventCalendars: [Source] { eventsStatus == .fullAccess ? sources(for: .event) : [] }
    var reminderCalendars: [Source] { remindersStatus == .fullAccess ? sources(for: .reminder) : [] }

    func isShown(_ id: String) -> Bool { !hidden.contains(id) }

    func setShown(_ id: String, _ shown: Bool) {
        if shown { hidden.remove(id) } else { hidden.insert(id) }
        UserDefaults.standard.set(Array(hidden), forKey: Prefs.appleHiddenCalendars)
        changed()
    }

    private func sources(for type: EKEntityType) -> [Source] {
        store.calendars(for: type)
            .map { Source(id: $0.calendarIdentifier, title: $0.title, color: Color(cgColor: $0.cgColor)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var calendarReady: Bool { Prefs.bool(Prefs.appleCalendar) && eventsStatus == .fullAccess }
    var remindersReady: Bool { Prefs.bool(Prefs.appleReminders) && remindersStatus == .fullAccess }

    init() {
        // Edits made in Calendar or Reminders (or synced from iCloud) show up in the notch.
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        }
    }

    func whenChanged(_ handler: @escaping () -> Void) { handlers.append(handler) }

    func refreshStatus() {
        eventsStatus = EKEventStore.authorizationStatus(for: .event)
        remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
    }

    private func changed() {
        refreshStatus()
        handlers.forEach { $0() }
    }

    /// Asks macOS for access; the prompt only appears the first time.
    func requestCalendarAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        ActivityLog.note("apple calendar access: \(granted)")
        changed()
        return granted
    }

    func requestRemindersAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        ActivityLog.note("apple reminders access: \(granted)")
        changed()
        return granted
    }

    // MARK: Calendar

    func events(from start: Date, to end: Date) -> [CalEvent] {
        guard calendarReady else { return [] }
        let shown = store.calendars(for: .event).filter { isShown($0.calendarIdentifier) }
        guard !shown.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: shown)
        return store.events(matching: predicate).compactMap(Self.makeEvent)
    }

    static func makeEvent(_ event: EKEvent) -> CalEvent? {
        guard event.status != .canceled,
              event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined,
              let start = event.startDate, let end = event.endDate else { return nil }
        let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Clicking the event opens it in the Calendar app.
        let show = identifier.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            .flatMap { URL(string: "ical://ekevent/\($0)?method=show&options=more") }
        return CalEvent(id: "\(listPrefix)\(identifier):\(Int(start.timeIntervalSince1970))",
                        title: title.isEmpty ? "(No title)" : title, start: start, end: end,
                        isAllDay: event.isAllDay, color: event.calendar?.cgColor.map { Color(cgColor: $0) } ?? .blue,
                        meetLink: meetingLink(event), htmlLink: show)
    }

    private static let meetingHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com",
                                       "webex.com", "facetime.apple.com"]

    /// A video call link from the event's URL, location or notes, for the Join button.
    static func meetingLink(_ event: EKEvent) -> URL? {
        if let url = event.url, isMeeting(url) { return url }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        guard !text.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).first(where: isMeeting)
    }

    private static func isMeeting(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: Reminders

    func reminderLists() -> [GTaskList] {
        guard remindersReady else { return [] }
        return store.calendars(for: .reminder)
            .filter { isShown($0.calendarIdentifier) }
            .map { GTaskList(id: Self.listPrefix + $0.calendarIdentifier, title: $0.title) }
    }

    func reminders(inList listID: String) async -> [GTask] {
        guard remindersReady, let list = calendar(for: listID) else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list])
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(Self.makeTask))
            }
        }
    }

    nonisolated static func makeTask(_ reminder: EKReminder) -> GTask {
        let title = reminder.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        return GTask(id: reminder.calendarItemIdentifier, title: title.isEmpty ? "(No title)" : title, due: due,
                     isSubtask: false, completed: reminder.isCompleted)
    }

    func complete(reminderID: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: reminderID) as? EKReminder else { return }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
    }

    func addReminder(_ title: String, toList listID: String) throws -> GTask? {
        guard let list = calendar(for: listID) else { return nil }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        try store.save(reminder, commit: true)
        return Self.makeTask(reminder)
    }

    private func calendar(for listID: String) -> EKCalendar? {
        store.calendar(withIdentifier: String(listID.dropFirst(Self.listPrefix.count)))
    }
}

extension GTaskList {
    var isApple: Bool { id.hasPrefix(AppleEventKit.listPrefix) }
}
