import Foundation
import SwiftUI

struct GTask: Identifiable, Hashable {
    let id: String
    let title: String
    let due: Date?
    let isSubtask: Bool
    var completed: Bool
}

struct GTaskList: Identifiable, Hashable {
    let id: String
    let title: String
}

enum TaskSort: String {
    case date, myOrder
}

enum GoogleAPIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Google Tasks through the same Google sign-in as the calendar: read the open tasks of one
/// list, tick them off, and add new ones.
@Observable @MainActor
final class TasksService {
    static let scope = "https://www.googleapis.com/auth/tasks"

    let auth: GoogleAuth
    let apple: AppleEventKit
    private(set) var lists: [GTaskList] = []
    private(set) var tasks: [GTask] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var lastUpdated: Date?
    var draft = ""
    var sort: TaskSort = TaskSort(rawValue: UserDefaults.standard.string(forKey: Prefs.tasksSort) ?? "") ?? .date {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: Prefs.tasksSort) }
    }
    var selectedListID: String? {
        didSet {
            UserDefaults.standard.set(selectedListID, forKey: Prefs.tasksList)
            if oldValue != selectedListID { Task { await refresh() } }
        }
    }

    @ObservationIgnored private var timer: Timer?

    init(auth: GoogleAuth, apple: AppleEventKit) {
        self.auth = auth
        self.apple = apple
        selectedListID = UserDefaults.standard.string(forKey: Prefs.tasksList)
        auth.whenSignedIn { [weak self] in Task { @MainActor in await self?.refresh() } }
        auth.whenSignedOut { [weak self] in
            self?.lists = []
            self?.tasks = []
            self?.lastUpdated = nil
            self?.lastError = nil
            Task { @MainActor in await self?.refresh() }  // Reminders may still be there
        }
        apple.whenChanged { [weak self] in Task { @MainActor in await self?.refresh() } }
    }

    /// Google Tasks or Apple Reminders is available.
    var hasSource: Bool { googleShown || apple.remindersReady }
    var googleShown: Bool { auth.isSignedIn && Prefs.bool(Prefs.googleTasks) }

    /// Signed in, but from before Tasks was part of the sign-in (and no Reminders to show instead).
    var needsReconnect: Bool { googleShown && !auth.hasScope(Self.scope) && !apple.remindersReady }
    var currentList: GTaskList? { lists.first { $0.id == selectedListID } }

    /// `tasks` stays in Google's order; by date, the earliest due comes first, undated last,
    /// and ties keep Google's order.
    var displayedTasks: [GTask] {
        guard sort == .date else { return tasks }
        return tasks.enumerated().sorted { a, b in
            switch (a.element.due, b.element.due) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }
        .map(\.element)
    }

    func start() {
        Task { await refresh() }
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refreshIfStale() {
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < 60 { return }
        Task { await refresh() }
    }

    func refresh() async {
        let googleReady = googleShown && auth.hasScope(Self.scope)
        guard !isLoading else { return }
        guard googleReady || apple.remindersReady else {
            lists = []
            tasks = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        let started = Date()
        do {
            var found: [GTaskList] = []
            var token: String?
            if googleReady {
                let value = try await auth.accessTokenValue()
                token = value
                ActivityLog.note("tasks: token ready after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                let listResponse: ListsResponse = try await request(
                    "https://tasks.googleapis.com/tasks/v1/users/@me/lists?maxResults=100", token: value)
                found = (listResponse.items ?? []).map { GTaskList(id: $0.id, title: $0.title ?? "Untitled") }
            }
            lists = found + apple.reminderLists()
            if currentList == nil { selectedListID = lists.first?.id }
            guard let listID = selectedListID else {
                tasks = []
                lastUpdated = Date()
                return
            }
            if currentList?.isApple == true {
                tasks = await apple.reminders(inList: listID)
            } else if let token {
                let response: TasksResponse = try await request(
                    "https://tasks.googleapis.com/tasks/v1/lists/\(Self.path(listID))/tasks?showCompleted=false&maxResults=100",
                    token: token)
                tasks = Self.ordered(response.items ?? []).map(Self.makeTask)
            }
            lastError = nil
            lastUpdated = Date()
            ActivityLog.note("tasks: \(lists.count) list(s), \(tasks.count) open task(s) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            let preview = displayedTasks.prefix(6).map { $0.due?.formatted(.dateTime.month(.abbreviated).day()) ?? "no date" }
            ActivityLog.note("tasks order (\(sort.rawValue)): \(preview.joined(separator: ", "))")
        } catch {
            lastError = error.localizedDescription
            ActivityLog.note("tasks error after \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(error.localizedDescription)")
        }
    }

    /// Shows the tick straight away, then removes the task once Google confirms.
    func complete(_ task: GTask) {
        guard let listID = selectedListID, let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].completed = true
        if currentList?.isApple == true {
            Task {
                do {
                    try apple.complete(reminderID: task.id)
                    try? await Task.sleep(for: .seconds(0.7))
                    withAnimation(.smooth(duration: 0.25)) { tasks.removeAll { $0.id == task.id } }
                } catch {
                    if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index].completed = false }
                    lastError = error.localizedDescription
                }
            }
            return
        }
        Task {
            do {
                let token = try await auth.accessTokenValue()
                let _: TaskItem = try await request(
                    "https://tasks.googleapis.com/tasks/v1/lists/\(Self.path(listID))/tasks/\(Self.path(task.id))",
                    method: "PATCH", body: ["status": "completed"], token: token)
                try? await Task.sleep(for: .seconds(0.7))
                withAnimation(.smooth(duration: 0.25)) { tasks.removeAll { $0.id == task.id } }
            } catch {
                if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index].completed = false }
                lastError = error.localizedDescription
            }
        }
    }

    /// Adds `draft` to the top of the current list.
    func addTask() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let listID = selectedListID else { return }
        draft = ""
        if currentList?.isApple == true {
            do {
                if let created = try apple.addReminder(title, toList: listID) {
                    withAnimation(.smooth(duration: 0.25)) { tasks.insert(created, at: 0) }
                }
            } catch {
                draft = title
                lastError = error.localizedDescription
            }
            return
        }
        Task {
            do {
                let token = try await auth.accessTokenValue()
                let created: TaskItem = try await request(
                    "https://tasks.googleapis.com/tasks/v1/lists/\(Self.path(listID))/tasks",
                    method: "POST", body: ["title": title], token: token)
                withAnimation(.smooth(duration: 0.25)) { tasks.insert(Self.makeTask(created), at: 0) }
            } catch {
                draft = title
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: HTTP

    private func request<T: Decodable>(_ url: String, method: String = "GET", body: [String: String]? = nil,
                                       token: String) async throws -> T {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(APIError.self, from: data))?.error.message
            throw GoogleAPIError.message(message ?? "Google Tasks returned HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func path(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? id
    }

    // MARK: Decoding

    /// Google's own order: top-level tasks by position, each followed by its subtasks.
    private static func ordered(_ items: [TaskItem]) -> [TaskItem] {
        let byPosition: (TaskItem, TaskItem) -> Bool = { ($0.position ?? "") < ($1.position ?? "") }
        var result: [TaskItem] = []
        for parent in items.filter({ $0.parent == nil }).sorted(by: byPosition) {
            result.append(parent)
            result += items.filter { $0.parent == parent.id }.sorted(by: byPosition)
        }
        let placed = Set(result.map(\.id))
        return result + items.filter { !placed.contains($0.id) }
    }

    private static func makeTask(_ item: TaskItem) -> GTask {
        let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return GTask(id: item.id, title: title.isEmpty ? "(No title)" : title, due: parseDue(item.due),
                     isSubtask: item.parent != nil, completed: item.status == "completed")
    }

    /// Due dates are whole days sent as midnight UTC; read the date part so it doesn't shift.
    private static func parseDue(_ text: String?) -> Date? {
        guard let text, text.count >= 10 else { return nil }
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private struct ListsResponse: Decodable {
        let items: [Entry]?
        struct Entry: Decodable {
            let id: String
            let title: String?
        }
    }

    private struct TasksResponse: Decodable {
        let items: [TaskItem]?
    }

    private struct TaskItem: Decodable {
        let id: String
        let title: String?
        let due: String?
        let status: String?
        let parent: String?
        let position: String?
    }

    private struct APIError: Decodable {
        let error: Body
        struct Body: Decodable { let message: String }
    }
}
