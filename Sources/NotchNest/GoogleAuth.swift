import AppKit
import CryptoKit
import Network
import Security

enum GoogleAuthError: LocalizedError {
    case timedOut, cancelled, notSignedIn, expired
    case denied(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .timedOut: return "Sign-in timed out. Try again."
        case .cancelled: return "Sign-in cancelled."
        case .notSignedIn: return "Not signed in to Google."
        case .expired: return "Your Google sign-in expired. Sign in again."
        case .denied(let reason): return "Google sign-in was denied (\(reason))."
        case .badResponse(let message): return message
        }
    }
}

/// "Sign in with Google" for a desktop app: OAuth 2 authorization code + PKCE with a loopback
/// redirect. The user supplies their own Desktop-app OAuth client; the refresh token and
/// client secret live in the Keychain.
@Observable @MainActor
final class GoogleAuth {
    /// Calendar (read, plus creating events for quick-add) and Google Tasks (read/write, so
    /// tasks can be ticked off and added). Adding a scope means the user signs in once more.
    static let scopes = ["https://www.googleapis.com/auth/calendar.readonly", CalendarService.writeScope, TasksService.scope]

    var clientID: String { didSet { UserDefaults.standard.set(clientID, forKey: Prefs.googleClientID) } }
    var clientSecret: String { didSet { if !restoring { Keychain.set(clientSecret, for: "clientSecret") } } }
    var accountEmail: String? { didSet { UserDefaults.standard.set(accountEmail, forKey: Prefs.googleEmail) } }
    private(set) var isSignedIn: Bool
    private(set) var isSigningIn = false
    var statusMessage: String?
    /// What the user actually granted (Google reports it with every token).
    private(set) var grantedScopes: Set<String>

    @ObservationIgnored private var signInHandlers: [() -> Void] = []
    @ObservationIgnored private var signOutHandlers: [() -> Void] = []
    @ObservationIgnored private var refreshToken: String?
    @ObservationIgnored private var secretsLoaded: Task<Void, Never>?
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var pendingRefresh: Task<String, Error>?
    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var accessExpiry = Date.distantPast
    @ObservationIgnored private var server: LoopbackServer?

    init() {
        clientID = UserDefaults.standard.string(forKey: Prefs.googleClientID) ?? ""
        clientSecret = ""
        accountEmail = UserDefaults.standard.string(forKey: Prefs.googleEmail)
        // The Keychain can take seconds to answer, so it's read off the main thread (once, then
        // kept in memory). Until it answers, the remembered flag says whether we're signed in.
        isSignedIn = UserDefaults.standard.bool(forKey: Prefs.googleSignedIn)
        grantedScopes = Set(UserDefaults.standard.stringArray(forKey: Prefs.googleScopes) ?? [])
        secretsLoaded = Task { await loadSecrets() }
    }

    private func loadSecrets() async {
        let started = Date()
        let secrets: (secret: String?, refresh: String?) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: (Keychain.get("clientSecret"), Keychain.get("refreshToken")))
            }
        }
        ActivityLog.note(String(format: "keychain read (in the background): %.1fs", Date().timeIntervalSince(started)))
        restoring = true
        clientSecret = secrets.secret ?? ""
        restoring = false
        refreshToken = secrets.refresh
        let wasSignedIn = isSignedIn
        isSignedIn = secrets.refresh != nil
        UserDefaults.standard.set(isSignedIn, forKey: Prefs.googleSignedIn)
        // First launch with the flag: nobody has fetched yet, so kick things off now.
        if isSignedIn && !wasSignedIn { signInHandlers.forEach { $0() } }
    }

    func whenSignedIn(_ handler: @escaping () -> Void) { signInHandlers.append(handler) }
    func whenSignedOut(_ handler: @escaping () -> Void) { signOutHandlers.append(handler) }
    func hasScope(_ scope: String) -> Bool { grantedScopes.contains(scope) }

    /// A client built into release builds (from the git-ignored Config/GoogleClient.plist), so
    /// people who install NotchNest can just sign in.
    static let builtInClientID = Bundle.main.object(forInfoDictionaryKey: "NNGoogleClientID") as? String ?? ""
    static let builtInClientSecret = Bundle.main.object(forInfoDictionaryKey: "NNGoogleClientSecret") as? String ?? ""
    static var hasBuiltInClient: Bool { !builtInClientID.isEmpty && !builtInClientSecret.isEmpty }

    /// Your own client if you entered one in Settings, otherwise the built-in one.
    private var usesOwnClient: Bool { !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var trimmedID: String {
        usesOwnClient ? clientID.trimmingCharacters(in: .whitespacesAndNewlines) : Self.builtInClientID
    }
    private var trimmedSecret: String {
        usesOwnClient ? clientSecret.trimmingCharacters(in: .whitespacesAndNewlines) : Self.builtInClientSecret
    }

    func signIn() async {
        await secretsLoaded?.value
        guard !trimmedID.isEmpty, !trimmedSecret.isEmpty else {
            statusMessage = "Paste your Client ID and Client Secret first."
            return
        }
        isSigningIn = true
        statusMessage = "Finish signing in in your browser…"
        defer { isSigningIn = false }

        do {
            let server = try LoopbackServer()
            self.server = server
            let port = try await server.start()
            let redirect = "http://127.0.0.1:\(port)"
            let verifier = Self.randomURLSafe(64)
            let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
            let state = Self.randomURLSafe(24)

            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: trimmedID),
                URLQueryItem(name: "redirect_uri", value: redirect),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
            ]
            NSWorkspace.shared.open(components.url!)

            let callback = try await server.waitForCallback(timeout: 300)
            server.stop()
            self.server = nil

            let query = Dictionary((callback.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                                   uniquingKeysWith: { first, _ in first })
            if let error = query["error"] { throw GoogleAuthError.denied(error) }
            guard query["state"] == state, let code = query["code"] else {
                throw GoogleAuthError.badResponse("Google's reply didn't match this sign-in. Try again.")
            }

            let tokens = try await tokenRequest([
                "code": code, "client_id": trimmedID, "client_secret": trimmedSecret,
                "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier,
            ])
            guard let refresh = tokens.refresh_token else {
                throw GoogleAuthError.badResponse("Google didn't return a refresh token. Try again.")
            }
            Keychain.set(refresh, for: "refreshToken")
            refreshToken = refresh
            store(tokens)
            isSignedIn = true
            UserDefaults.standard.set(true, forKey: Prefs.googleSignedIn)
            statusMessage = nil
            ActivityLog.note("google signed in")
            NSApp.activate(ignoringOtherApps: true)
            signInHandlers.forEach { $0() }
        } catch {
            server?.stop()
            server = nil
            statusMessage = error.localizedDescription
            ActivityLog.note("google sign-in failed: \(error.localizedDescription)")
        }
    }

    func cancelSignIn() {
        server?.stop()
        server = nil
    }

    func signOut(message: String? = nil, revoke: Bool = true) {
        if revoke, let refreshToken { Self.revoke(refreshToken) }
        Keychain.set(nil, for: "refreshToken")
        refreshToken = nil
        pendingRefresh = nil
        UserDefaults.standard.set(false, forKey: Prefs.googleSignedIn)
        accessToken = nil
        accessExpiry = .distantPast
        isSignedIn = false
        accountEmail = nil
        statusMessage = message
        grantedScopes = []
        UserDefaults.standard.removeObject(forKey: Prefs.googleScopes)
        signOutHandlers.forEach { $0() }
    }

    /// A valid access token, refreshed with the stored refresh token when needed.
    func accessTokenValue() async throws -> String {
        if let token = accessToken, accessExpiry > Date().addingTimeInterval(60) { return token }
        await secretsLoaded?.value
        // Calendar and Tasks often ask at the same moment; they share one refresh.
        if let pending = pendingRefresh { return try await pending.value }
        guard let refresh = refreshToken else { throw GoogleAuthError.notSignedIn }
        let refreshing = Task { () throws -> String in
            let started = Date()
            let tokens = try await tokenRequest([
                "client_id": trimmedID, "client_secret": trimmedSecret,
                "refresh_token": refresh, "grant_type": "refresh_token",
            ])
            store(tokens)
            ActivityLog.note(String(format: "google token refresh: %.1fs", Date().timeIntervalSince(started)))
            return tokens.access_token
        }
        pendingRefresh = refreshing
        defer { pendingRefresh = nil }
        do {
            return try await refreshing.value
        } catch GoogleAuthError.expired {
            signOut(message: GoogleAuthError.expired.errorDescription, revoke: false)
            throw GoogleAuthError.expired
        }
    }

    // MARK: Token endpoint

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double?
        let refresh_token: String?
        let scope: String?
    }

    private struct TokenError: Decodable {
        let error: String
        let error_description: String?
    }

    private func store(_ tokens: TokenResponse) {
        accessToken = tokens.access_token
        accessExpiry = Date().addingTimeInterval(tokens.expires_in ?? 3600)
        if let scope = tokens.scope {
            let granted = Set(scope.split(separator: " ").map(String.init))
            if granted != grantedScopes {
                grantedScopes = granted
                UserDefaults.standard.set(Array(granted), forKey: Prefs.googleScopes)
            }
        }
    }

    private func tokenRequest(_ params: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(params).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let error = try? JSONDecoder().decode(TokenError.self, from: data)
            if error?.error == "invalid_grant" { throw GoogleAuthError.expired }
            throw GoogleAuthError.badResponse(error?.error_description ?? error?.error ?? "Google returned HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func revoke(_ token: String) {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncode(["token": token]).utf8)
        URLSession.shared.dataTask(with: request).resume()
    }

    private static func formEncode(_ params: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }

    private static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Tiny HTTP listener on 127.0.0.1 that catches Google's redirect back to the app.
final class LoopbackServer {
    private let listener: NWListener
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<URLComponents, Error>?
    private var earlyResult: URLComponents?
    private var finished = false

    init() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                self.startContinuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.startContinuation?.resume(returning: self.listener.port?.rawValue ?? 0)
                        self.startContinuation = nil
                    case .failed(let error):
                        self.startContinuation?.resume(throwing: error)
                        self.startContinuation = nil
                    default:
                        break
                    }
                }
                self.listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
                self.listener.start(queue: .main)
            }
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> URLComponents {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                if let early = self.earlyResult {
                    continuation.resume(returning: early)
                    return
                }
                self.callbackContinuation = continuation
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(GoogleAuthError.timedOut))
                }
            }
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.listener.cancel()
            self.finish(.failure(GoogleAuthError.cancelled))
        }
    }

    private func finish(_ result: Result<URLComponents, Error>) {
        guard let continuation = callbackContinuation else { return }
        callbackContinuation = nil
        continuation.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: "\r\n").first?
                .split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let components = URLComponents(string: "http://127.0.0.1" + target)
            let items = components?.queryItems ?? []
            let isCallback = items.contains { $0.name == "code" || $0.name == "error" }
            let body = isCallback ? Self.page(success: items.contains { $0.name == "code" }) : "Not found"
            let status = isCallback ? "200 OK" : "404 Not Found"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })

            guard let self, isCallback, let components, !self.finished else { return }
            self.finished = true
            if self.callbackContinuation != nil {
                self.finish(.success(components))
            } else {
                self.earlyResult = components
            }
        }
    }

    private static func page(success: Bool) -> String {
        let title = success ? "NotchNest is connected" : "Sign-in didn't finish"
        let detail = success ? "Your Google Calendar and Tasks will appear in the notch. You can close this tab."
                             : "Head back to NotchNest and try again."
        return """
        <!doctype html><meta charset="utf-8"><title>\(title)</title>
        <body style="margin:0;height:100vh;display:grid;place-items:center;background:#0b0b0c;color:#f4f4f5;
        font:15px -apple-system,BlinkMacSystemFont,sans-serif"><div style="text-align:center">
        <div style="font-size:44px">\(success ? "✓" : "✕")</div><h2 style="margin:8px 0">\(title)</h2>
        <p style="color:#a1a1aa">\(detail)</p></div></body>
        """
    }
}

/// Generic-password Keychain storage scoped to this app.
enum Keychain {
    private static let service = "com.pranav.NotchNest"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Writes happen on a background queue (in order): the Keychain can take seconds to answer.
    private static let writes = DispatchQueue(label: "NotchNest.keychain")

    static func set(_ value: String?, for key: String) {
        writes.async { write(value, for: key) }
    }

    private static func write(_ value: String?, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
