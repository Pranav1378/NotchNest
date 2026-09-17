import AppKit
import Network

/// Claude Code asking to use a tool, waiting on Allow or Deny.
struct ClaudeRequest: Identifiable, Equatable {
    let id = UUID()
    let tool: String
    /// One line: the command, or "Edit NotchViews.swift".
    let summary: String
    let project: String
    /// The app Claude Code runs in (Terminal, iTerm, VS Code…), when the hook could tell.
    let hostApp: String?
}

/// Claude Code finished its turn.
struct ClaudeFinished: Equatable {
    let project: String
    let message: String
    let hostApp: String?
}

/// Your Claude plan's usage, exactly as Claude Code reports it to its status line: the rolling
/// 5-hour session window and the weekly window, each with a percentage and a reset time.
struct ClaudeUsage: Codable, Equatable {
    struct Window: Codable, Equatable {
        var used: Double
        var resetsAt: Date
    }

    var session: Window?
    var week: Window?
    var model: String?
    var updated: Date

    static func from(_ json: [String: Any], now: Date = .now) -> ClaudeUsage? {
        guard let limits = json["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> Window? {
            guard let entry = limits[key] as? [String: Any],
                  let used = (entry["used_percentage"] as? NSNumber)?.doubleValue,
                  let reset = (entry["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            return Window(used: used, resetsAt: Date(timeIntervalSince1970: reset))
        }
        let session = window("five_hour")
        let week = window("seven_day")
        guard session != nil || week != nil else { return nil }
        return ClaudeUsage(session: session, week: week,
                           model: (json["model"] as? [String: Any])?["display_name"] as? String, updated: now)
    }

    /// The one-line summary Claude Code's own status line shows (NotchNest answers the status line
    /// request with it).
    static func statusLine(_ json: [String: Any], usage: ClaudeUsage?) -> String {
        var parts: [String] = []
        if let model = (json["model"] as? [String: Any])?["display_name"] as? String { parts.append(model) }
        if let context = ((json["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue {
            parts.append("context \(Int(context.rounded()))%")
        }
        if let session = usage?.session {
            parts.append("session \(Int(session.used.rounded()))% (resets \(session.resetsAt.formatted(date: .omitted, time: .shortened)))")
        }
        if let week = usage?.week { parts.append("week \(Int(week.used.rounded()))%") }
        return parts.joined(separator: " · ")
    }
}

/// Receives Claude Code's hooks on a local port. The hooks (see `ClaudeHooks`) are one `curl`
/// each: PermissionRequest waits for the answer given in the notch, Stop just reports in.
/// When NotchNest isn't running, curl fails quietly and Claude Code asks in the terminal as usual.
@Observable @MainActor
final class ClaudeBridge {
    static let defaultPort: UInt16 = 47823

    enum Answer: String { case allow, deny, terminal }

    private(set) var pending: [ClaudeRequest] = []
    private(set) var problem: String?
    /// The latest plan usage Claude Code reported (kept between launches).
    private(set) var usage: ClaudeUsage?
    /// Whether NotchNest's hooks are in Claude Code's settings (Settings → Claude Code → Connect).
    private(set) var connected = ClaudeHooks.isInstalled()
    let port: UInt16

    func refreshConnected() { connected = ClaudeHooks.isInstalled() }
    @ObservationIgnored var onRequest: () -> Void = {}
    @ObservationIgnored var onFinished: (ClaudeFinished) -> Void = { _ in }
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var waiting: [UUID: NWConnection] = [:]

    init(port: UInt16 = defaultPort) {
        self.port = port
        // Test runs use their own port and don't read or write the saved usage.
        if port == Self.defaultPort, let data = UserDefaults.standard.data(forKey: Prefs.claudeUsage) {
            usage = try? JSONDecoder().decode(ClaudeUsage.self, from: data)
        }
    }

    private func record(_ usage: ClaudeUsage) {
        if usage.session?.used != self.usage?.session?.used || usage.week?.used != self.usage?.week?.used {
            ActivityLog.note("claude usage: session \(usage.session.map { "\(Int($0.used))%" } ?? "–"), week \(usage.week.map { "\(Int($0.used))%" } ?? "–")")
        }
        self.usage = usage
        if port == Self.defaultPort, let data = try? JSONEncoder().encode(usage) {
            UserDefaults.standard.set(data, forKey: Prefs.claudeUsage)
        }
    }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    if case .failed(let error) = state {
                        self?.problem = "Couldn't listen on port \(self?.port ?? 0): \(error.localizedDescription)"
                        ActivityLog.note("claude bridge: \(error)")
                    } else if case .ready = state {
                        self?.problem = nil
                        ActivityLog.note("claude bridge listening on \(self?.port ?? 0)")
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Answers the request (or hands it back to the terminal's own prompt).
    func answer(_ id: UUID, _ answer: Answer) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: index)
        guard let connection = waiting.removeValue(forKey: id) else { return }
        ActivityLog.note("claude: \(answer.rawValue) \(request.tool)")
        respond(connection, body: Self.decision(answer))
    }

    static func decision(_ answer: Answer) -> String {
        switch answer {
        case .allow:
            return #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        case .deny:
            return #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from the notch (NotchNest)."}}}"#
        case .terminal:
            return ""  // no decision: Claude Code shows its normal prompt
        }
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = HTTPRequest(buffer) {
                    self.handle(request, on: connection)
                } else if complete || error != nil || buffer.count > 2_000_000 {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        // Browsers can't add custom headers without a preflight we never answer, so web pages
        // can't post here.
        guard request.headers["x-notchnest"] != nil else {
            respond(connection, status: "403 Forbidden", body: "")
            return
        }
        let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        let host = request.headers["x-app"].flatMap { $0.isEmpty ? nil : $0 }
        switch request.path {
        case "/claude/permission": permission(json, host: host, connection: connection)
        case "/claude/stop":
            respond(connection, body: "")
            finished(json, host: host)
        case "/claude/status":
            if let usage = ClaudeUsage.from(json) { record(usage) }
            respond(connection, body: ClaudeUsage.statusLine(json, usage: ClaudeUsage.from(json)), type: "text/plain")
        default:
            respond(connection, status: "404 Not Found", body: "")
        }
    }

    private func permission(_ json: [String: Any], host: String?, connection: NWConnection) {
        let tool = json["tool_name"] as? String ?? "a tool"
        guard Prefs.bool(Prefs.claudeAlerts) else {
            respond(connection, body: "")
            return
        }
        // Looking at the terminal already? Then its own prompt is the quickest place to answer.
        if let host, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == host {
            ActivityLog.note("claude: \(tool) asked while \(host) is in front; left to the terminal")
            respond(connection, body: "")
            return
        }
        let request = ClaudeRequest(tool: tool, summary: Self.summary(json), project: Self.project(json), hostApp: host)
        pending.append(request)
        waiting[request.id] = connection
        ActivityLog.note("claude: asks for \(tool) in \(request.project)")
        watchForHangUp(connection, id: request.id)
        onRequest()
        // Unanswered? Fall back to the terminal's prompt.
        let wait = Double(max(10, Prefs.int(Prefs.claudeWait)))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated { self?.answer(request.id, .terminal) }
        }
    }

    /// If Claude Code gives up on the hook (answered elsewhere, or the session ended), drop it.
    private func watchForHangUp(_ connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, complete || error != nil, self.waiting[id] != nil else { return }
                self.waiting[id] = nil
                self.pending.removeAll { $0.id == id }
                ActivityLog.note("claude: request withdrawn")
            }
        }
    }

    private func finished(_ json: [String: Any], host: String?) {
        guard Prefs.bool(Prefs.claudeAlerts) else { return }
        if let host, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == host { return }
        let message = (json["last_assistant_message"] as? String ?? "")
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        onFinished(ClaudeFinished(project: Self.project(json), message: message, hostApp: host))
    }

    private func respond(_ connection: NWConnection, status: String = "200 OK", body: String,
                         type: String = "application/json") {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type); charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Describing a request

    static func project(_ json: [String: Any]) -> String {
        (json["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude Code"
    }

    static func summary(_ json: [String: Any]) -> String {
        let tool = json["tool_name"] as? String ?? ""
        let input = json["tool_input"] as? [String: Any] ?? [:]
        func file(_ key: String) -> String? {
            (input[key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        }
        let text: String
        switch tool {
        case "Bash":
            text = input["command"] as? String ?? "Run a command"
        case "Edit", "MultiEdit", "Write", "Read":
            text = "\(tool) \(file("file_path") ?? "a file")"
        case "NotebookEdit":
            text = "Edit \(file("notebook_path") ?? "a notebook")"
        case "WebFetch":
            text = "Fetch \((input["url"] as? String).flatMap { URL(string: $0)?.host } ?? "a web page")"
        case "WebSearch":
            text = "Search “\(input["query"] as? String ?? "")”"
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
                text = parts.count >= 3 ? "\(parts[1]): \(parts[2...].joined(separator: "_"))" : tool
            } else {
                text = json["message"] as? String ?? (tool.isEmpty ? "Use a tool" : tool)
            }
        }
        return text.replacingOccurrences(of: "\n", with: " ⏎ ")
    }
}

/// Just enough HTTP/1.1 to read one request with a body.
private struct HTTPRequest {
    let path: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        path = String(requestLine[1])
        self.headers = headers
        body = data.subdata(in: bodyStart..<(bodyStart + length))
    }
}

/// Adds NotchNest's two hooks to Claude Code's user settings (~/.claude/settings.json), or takes
/// them out again. Only entries tagged `# notchnest` are touched; everything else is kept.
enum ClaudeHooks {
    static let marker = "# notchnest"
    static let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    static func command(path: String, port: UInt16, maxTime: Int, quiet: Bool) -> String {
        let output = quiet ? ">/dev/null 2>&1" : "2>/dev/null"
        return "curl -s -m \(maxTime) -H 'Expect:' -H 'X-NotchNest: 1' -H \"X-App: $__CFBundleIdentifier\" "
            + "--data-binary @- http://127.0.0.1:\(port)\(path) \(output) || true \(marker)"
    }

    private static func entries(port: UInt16) -> [(event: String, command: String, timeout: Int)] {
        [("PermissionRequest", command(path: "/claude/permission", port: port, maxTime: 590, quiet: false), 600),
         ("Stop", command(path: "/claude/stop", port: port, maxTime: 3, quiet: true), 10)]
    }

    /// The status line command: sends Claude Code's status data (which includes your plan usage) to
    /// NotchNest and prints the line NotchNest sends back. Someone else's status line is kept: it
    /// still gets the same data and still decides what's printed.
    static func statusCommand(port: UInt16, wrapping existing: String?) -> String {
        let send = "curl -s -m 1 -H 'Expect:' -H 'X-NotchNest: 1' --data-binary @- http://127.0.0.1:\(port)/claude/status 2>/dev/null"
        guard let existing, !existing.isEmpty else { return "\(send) || true \(marker)" }
        return "input=$(cat); printf '%s' \"$input\" | \(send) >/dev/null; \(wrapPrefix)\(existing)\(wrapSuffix)"
    }

    private static let wrapPrefix = "printf '%s' \"$input\" | { "
    private static let wrapSuffix = " ; } \(marker)"

    /// The status line that was there before NotchNest wrapped it, if any.
    private static func unwrapped(_ command: String) -> String? {
        guard command.hasSuffix(wrapSuffix), let start = command.range(of: wrapPrefix, options: .backwards) else { return nil }
        return String(command[start.upperBound..<command.index(command.endIndex, offsetBy: -wrapSuffix.count)])
    }

    static func statusLineInstalled(at url: URL = settingsURL) -> Bool {
        guard let root = try? load(url), let line = root["statusLine"] as? [String: Any] else { return false }
        return (line["command"] as? String)?.contains(marker) == true
    }

    private static func installStatusLine(_ root: inout [String: Any], port: UInt16) {
        var line = root["statusLine"] as? [String: Any] ?? [:]
        let current = line["command"] as? String
        let original = current.map { $0.contains(marker) ? unwrapped($0) : $0 } ?? nil
        line["type"] = "command"
        line["command"] = statusCommand(port: port, wrapping: original)
        root["statusLine"] = line
    }

    private static func uninstallStatusLine(_ root: inout [String: Any]) {
        guard var line = root["statusLine"] as? [String: Any], let command = line["command"] as? String,
              command.contains(marker) else { return }
        if let original = unwrapped(command) {
            line["command"] = original
            root["statusLine"] = line
        } else {
            root.removeValue(forKey: "statusLine")
        }
    }

    static func isInstalled(at url: URL = settingsURL) -> Bool {
        guard let root = try? load(url), let hooks = root["hooks"] as? [String: Any] else { return false }
        let groups = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        return groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
        }
    }

    static func install(at url: URL = settingsURL, port: UInt16 = ClaudeBridge.defaultPort) throws {
        var root = try load(url)
        var hooks = stripped(root["hooks"] as? [String: Any] ?? [:])
        for entry in entries(port: port) {
            var groups = hooks[entry.event] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": entry.command, "timeout": entry.timeout]]])
            hooks[entry.event] = groups
        }
        root["hooks"] = hooks
        installStatusLine(&root, port: port)
        try save(root, to: url)
        ActivityLog.note("claude hooks installed in \(url.path)")
    }

    static func uninstall(at url: URL = settingsURL) throws {
        var root = try load(url)
        let hooks = stripped(root["hooks"] as? [String: Any] ?? [:])
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        uninstallStatusLine(&root)
        try save(root, to: url)
        ActivityLog.note("claude hooks removed from \(url.path)")
    }

    /// The hooks with NotchNest's entries taken out (and anything left empty removed).
    private static func stripped(_ hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                result[event] = value
                continue
            }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let list = group["hooks"] as? [[String: Any]] else { return group }
                let others = list.filter { ($0["command"] as? String)?.contains(marker) != true }
                if others.isEmpty { return nil }
                var copy = group
                copy["hooks"] = others
                return copy
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    private static func load(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return root
    }

    private static func save(_ root: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the first original, in case anything about the rewrite is unwelcome.
        let backup = url.appendingPathExtension("notchnest-backup")
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) {
            try? fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
