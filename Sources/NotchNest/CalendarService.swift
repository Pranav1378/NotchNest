import AppKit
import SwiftUI

struct CalEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: Color
    let meetLink: URL?
    let htmlLink: URL?

    var timeText: String {
        if isAllDay { return "All day" }
        return "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    /// Opens the event in Google Calendar on the web.
    @MainActor func openInCalendar() {
        if let htmlLink { NSWorkspace.shared.open(htmlLink) }
    }
}

struct GoogleCalendarInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let color: Color
    let isPrimary: Bool
    let selectedInGoogle: Bool
}

enum CalendarError: LocalizedError {
    case api(String)
    var errorDescription: String? { if case .api(let message) = self { return message }; return nil }
}

/// Reads the next week of events from the Google Calendar API, plus Apple Calendar when it's on.
@Observable @MainActor
final class CalendarService {
    let auth: GoogleAuth
    let apple: AppleEventKit
    /// Google's events.
    private(set) var events: [CalEvent] = []
    private(set) var appleEvents: [CalEvent] = []
    /// Both, without duplicates: what the notch shows.
    private(set) var combined: [CalEvent] = []
    private(set) var calendars: [GoogleCalendarInfo] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var lastUpdated: Date?
    /// A timed event starting within 10 minutes (or that started in the last 5).
    private(set) var imminentEvent: CalEvent?
    /// Per-calendar on/off chosen in Settings; calendars not listed follow Google's own checkbox.
    private var overrides: [String: Bool]

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ticks = 0

    init(auth: GoogleAuth, apple: AppleEventKit) {
        self.auth = auth
        self.apple = apple
        overrides = UserDefaults.standard.dictionary(forKey: Prefs.calendarOverrides) as? [String: Bool] ?? [:]
        apple.whenChanged { [weak self] in Task { @MainActor in await self?.refresh() } }
        auth.whenSignedIn { [weak self] in Task { @MainActor in await self?.refresh() } }
        auth.whenSignedOut { [weak self] in
            self?.events = []
            self?.calendars = []
            self?.imminentEvent = nil
            self?.lastUpdated = nil
            self?.lastError = nil
            self?.combine()
        }
    }

    static let writeScope = "https://www.googleapis.com/auth/calendar.events"

    /// The day the week strip should jump to (set after quick-adding an event).
    private(set) var focusDay: Date?

    var googleShown: Bool { auth.isSignedIn && Prefs.bool(Prefs.googleCalendar) }
    var hasAccess: Bool { googleShown || apple.calendarReady }
    var canAddEvents: Bool { auth.hasScope(Self.writeScope) }

    /// Creates an event from plain English ("Study group Thu 7pm") with Google's quick-add, then
    /// refreshes and jumps the week strip to its day.
    func quickAdd(_ text: String) async throws -> CalEvent? {
        let token = try await auth.accessTokenValue()
        // Encode strictly: in a query string '+' would otherwise arrive as a space ("C++" → "C  ").
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        var request = URLRequest(url: URL(string:
            "https://www.googleapis.com/calendar/v3/calendars/primary/events/quickAdd?text=\(query)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let message = (try? JSONDecoder().decode(APIError.self, from: data))?.error.message
            throw CalendarError.api(message ?? "Google Calendar returned HTTP \(http.statusCode)")
        }
        let item = try JSONDecoder().decode(EventsResponse.Item.self, from: data)
        let event = Self.makeEvent(item, color: calendars.first(where: \.isPrimary)?.color ?? .blue)
        ActivityLog.note("quick-added \(event?.title ?? "an event")")
        await refresh()
        if let event { focusDay = Calendar.current.startOfDay(for: event.start) }
        return event
    }

    func start() {
        Task { await refresh() }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.minuteTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
    }

    private func minuteTick() {
        ticks += 1
        updateImminent()
        if ticks % 5 == 0 { Task { await refresh() } }
    }

    // MARK: Queries used by the views

    /// The week strip: yesterday through five days from now.
    var days: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        return (-1...5).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
    }

    func events(on day: Date) -> [CalEvent] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        return combined.filter { $0.start < end && $0.end > start }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }

    func hasEvents(on day: Date) -> Bool { !events(on: day).isEmpty }

    func isEnabled(_ calendar: GoogleCalendarInfo) -> Bool { overrides[calendar.id] ?? calendar.selectedInGoogle }

    func setEnabled(_ calendar: GoogleCalendarInfo, _ enabled: Bool) {
        overrides[calendar.id] = enabled
        UserDefaults.standard.set(overrides, forKey: Prefs.calendarOverrides)
        Task { await refresh() }
    }

    // MARK: Fetching

    func refresh() async {
        guard !isLoading else { return }
        let window = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: .now))!
        appleEvents = apple.events(from: window, to: Calendar.current.date(byAdding: .day, value: 8, to: window)!)
        combine()
        guard googleShown else {
            if !events.isEmpty {
                events = []
                combine()
            }
            if apple.calendarReady {
                lastError = nil
                lastUpdated = Date()
            }
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let token = try await auth.accessTokenValue()
            let list: CalendarListResponse = try await get(
                URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList?minAccessRole=reader")!,
                token: token)
            let infos = list.items.filter { $0.hidden != true }.map {
                GoogleCalendarInfo(id: $0.id, name: $0.summaryOverride ?? $0.summary ?? $0.id,
                                   color: Color(hex: $0.backgroundColor ?? "#4285F4"),
                                   isPrimary: $0.primary == true, selectedInGoogle: $0.selected == true)
            }
            calendars = infos.sorted { ($0.isPrimary ? 0 : 1, $0.name) < ($1.isPrimary ? 0 : 1, $1.name) }
            if let primary = infos.first(where: \.isPrimary) { auth.accountEmail = primary.id }

            let cal = Calendar.current
            let from = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: .now))!
            let to = cal.date(byAdding: .day, value: 8, to: from)!
            let iso = ISO8601DateFormatter()

            var collected: [CalEvent] = []
            for calendar in calendars where isEnabled(calendar) {
                let path = calendar.id.addingPercentEncoding(
                    withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? calendar.id
                var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(path)/events")!
                components.queryItems = [
                    URLQueryItem(name: "timeMin", value: iso.string(from: from)),
                    URLQueryItem(name: "timeMax", value: iso.string(from: to)),
                    URLQueryItem(name: "singleEvents", value: "true"),
                    URLQueryItem(name: "orderBy", value: "startTime"),
                    URLQueryItem(name: "maxResults", value: "250"),
                ]
                let response: EventsResponse = try await get(components.url!, token: token)
                collected += (response.items ?? []).compactMap { Self.makeEvent($0, color: calendar.color) }
            }
            events = collected.sorted { $0.start < $1.start }
            lastError = nil
            lastUpdated = Date()
            combine()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func combine() {
        combined = Self.merge(google: events, apple: appleEvents)
        updateImminent()
    }

    /// A calendar added both to Google and to the Mac's Calendar app shouldn't show its events twice.
    static func merge(google: [CalEvent], apple: [CalEvent]) -> [CalEvent] {
        func key(_ event: CalEvent) -> String { "\(event.title.lowercased())|\(Int(event.start.timeIntervalSince1970))" }
        let seen = Set(google.map(key))
        return (google + apple.filter { !seen.contains(key($0)) }).sorted { $0.start < $1.start }
    }

    private func updateImminent() {
        let now = Date()
        let next = combined.first {
            !$0.isAllDay && $0.start <= now.addingTimeInterval(10 * 60) && $0.start >= now.addingTimeInterval(-5 * 60)
        }
        if next != imminentEvent { imminentEvent = next }
    }

    private func get<T: Decodable>(_ url: URL, token: String) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let message = (try? JSONDecoder().decode(APIError.self, from: data))?.error.message
            throw CalendarError.api(message ?? "Google Calendar returned HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Decoding

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func parse(_ when: EventsResponse.When?) -> (Date, Bool)? {
        if let text = when?.dateTime, let date = isoPlain.date(from: text) ?? isoFractional.date(from: text) {
            return (date, false)
        }
        if let text = when?.date, let date = dayFormatter.date(from: text) { return (date, true) }
        return nil
    }

    private static func makeEvent(_ item: EventsResponse.Item, color: Color) -> CalEvent? {
        guard item.status != "cancelled",
              item.attendees?.first(where: { $0.isSelf == true })?.responseStatus != "declined",
              let (start, allDay) = parse(item.start), let (end, _) = parse(item.end) else { return nil }
        let video = item.hangoutLink
            ?? item.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri
        return CalEvent(id: item.id, title: item.summary ?? "(No title)", start: start, end: end,
                        isAllDay: allDay, color: color, meetLink: video.flatMap(URL.init(string:)),
                        htmlLink: item.htmlLink.flatMap(URL.init(string:)))
    }

    private struct CalendarListResponse: Decodable {
        let items: [Entry]
        struct Entry: Decodable {
            let id: String
            let summary: String?
            let summaryOverride: String?
            let backgroundColor: String?
            let selected: Bool?
            let primary: Bool?
            let hidden: Bool?
        }
    }

    private struct EventsResponse: Decodable {
        let items: [Item]?
        struct Item: Decodable {
            let id: String
            let status: String?
            let summary: String?
            let start: When?
            let end: When?
            let hangoutLink: String?
            let htmlLink: String?
            let conferenceData: Conference?
            let attendees: [Attendee]?
        }
        struct When: Decodable {
            let date: String?
            let dateTime: String?
        }
        struct Conference: Decodable {
            let entryPoints: [EntryPoint]?
        }
        struct EntryPoint: Decodable {
            let entryPointType: String?
            let uri: String?
        }
        struct Attendee: Decodable {
            let isSelf: Bool?
            let responseStatus: String?
            enum CodingKeys: String, CodingKey {
                case isSelf = "self"
                case responseStatus
            }
        }
    }

    private struct APIError: Decodable {
        let error: Body
        struct Body: Decodable { let message: String }
    }
}
