import AppKit
import SwiftUI

/// Now Playing state for whatever app is playing (Spotify, Music, browsers…).
///
/// Since macOS 15.4 MediaRemote only answers Apple-signed processes, so the data comes from a
/// long-running `osascript` (JavaScript for Automation) helper that polls MediaRemote and
/// prints a JSON line whenever something changes. Commands go through one-shot osascript calls.
@Observable @MainActor
final class MediaController {
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var album = ""
    private(set) var appName = ""
    private(set) var bundleID = ""
    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    private(set) var artwork: NSImage?
    private(set) var appIcon: NSImage?
    private(set) var accent: Color = .white
    /// Bumps when playback starts fresh (another app, or after a 10s+ pause), so a live
    /// activity the user hid stays hidden for that listening session only.
    private(set) var playSession = 0
    private var elapsedBase: Double = 0
    private var elapsedStamp = Date()

    @ObservationIgnored private var pausedAt: Date?
    @ObservationIgnored private var artKey = ""
    @ObservationIgnored private var trackKey = ""
    @ObservationIgnored private var artCache: [String: NSImage] = [:]
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var launchedAt = Date()

    /// Something is loaded in a player, even when the page didn't share a title (some video sites
    /// only report the app, a duration and the position).
    var hasTrack: Bool { !title.isEmpty || (!bundleID.isEmpty && duration > 0) }
    var displayTitle: String { title.isEmpty ? "\(appName.isEmpty ? "Unknown" : appName) media" : title }
    var subtitle: String {
        if !artist.isEmpty { return artist }
        return title.isEmpty ? "No title from this page" : appName
    }
    var trackIdentity: String { "\(title)|\(artist)" }

    func elapsed(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        let value = elapsedBase + (isPlaying ? date.timeIntervalSince(elapsedStamp) : 0)
        return min(max(value, 0), duration)
    }

    // MARK: Helper process

    func start() {
        stopped = false
        launchHelper()
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    private func launchHelper() {
        guard !stopped else { return }
        let script = Self.writeScript(named: "nowplaying.js", contents: Self.watchScript)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-l", "JavaScript", script.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        let errors = Pipe()
        proc.standardError = errors
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(data) } }
        }
        proc.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.helperExited(status: status, stderr: stderr) }
            }
        }
        do {
            try proc.run()
            process = proc
            launchedAt = Date()
        } catch {
            NSLog("NotchNest: couldn't start now-playing helper: \(error)")
        }
    }

    private func helperExited(status: Int32, stderr: String) {
        process = nil
        buffer.removeAll()
        guard !stopped else { return }
        let uptime = Date().timeIntervalSince(launchedAt)
        if uptime < 5 {
            let reason = stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            ActivityLog.note("now-playing helper died after \(Int(uptime))s (status \(status)): \(reason)")
        }
        // The helper exits on its own every 10 minutes; retry sooner if it died right away.
        let delay: TimeInterval = uptime < 5 ? 3 : 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.launchHelper() }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                apply(object)
            }
        }
    }

    private func apply(_ o: [String: Any]) {
        title = o["title"] as? String ?? ""
        artist = o["artist"] as? String ?? ""
        album = o["album"] as? String ?? ""
        appName = o["app"] as? String ?? ""
        let playing = o["playing"] as? Bool ?? false
        let playingApp = o["bundle"] as? String ?? ""
        if playing {
            let resumedAfterBreak = !isPlaying && (pausedAt.map { Date().timeIntervalSince($0) > 10 } ?? true)
            if resumedAfterBreak || playingApp != bundleID { playSession += 1 }
            pausedAt = nil
        } else if isPlaying {
            pausedAt = Date()
        }
        isPlaying = playing
        duration = o["duration"] as? Double ?? 0
        elapsedBase = o["elapsed"] as? Double ?? 0
        let stamp = o["timestamp"] as? Double ?? 0
        elapsedStamp = stamp > 0 ? Date(timeIntervalSince1970: stamp) : Date()

        let bundle = o["bundle"] as? String ?? ""
        if bundle != bundleID {
            bundleID = bundle
            appIcon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
            if artwork == nil { accent = appIcon?.notchAccent ?? .white }
        }

        // Artwork: use what the player sends; otherwise look the song up once per track.
        let key = o["artKey"] as? String ?? ""
        let track = "\(title)|\(artist)"
        if !key.isEmpty {
            if key != artKey, let base64 = o["art"] as? String, let data = Data(base64Encoded: base64),
               let image = NSImage(data: data) {
                artwork = image
                accent = image.notchAccent
            }
        } else if track != trackKey || !artKey.isEmpty {
            artwork = nil
            accent = appIcon?.notchAccent ?? .white
            if !artist.isEmpty { lookUpArtwork(title: title, artist: artist, track: track) }
        }
        artKey = key
        trackKey = track
    }

    /// Cover art from the public iTunes Search API, for players (Spotify, browsers) that don't
    /// hand artwork to macOS. Songs only — there's no artist for video, so it's skipped.
    private func lookUpArtwork(title: String, artist: String, track: String) {
        if let cached = artCache[track] {
            artwork = cached
            accent = cached.notchAccent
            return
        }
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = components.url else { return }
        Task {
            guard let search = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: search.0) as? [String: Any],
                  let results = json["results"] as? [[String: Any]], !results.isEmpty else { return }
            let best = results.first { ($0["trackName"] as? String)?.lowercased() == title.lowercased() } ?? results[0]
            guard let small = best["artworkUrl100"] as? String,
                  let artURL = URL(string: small.replacingOccurrences(of: "100x100bb", with: "600x600bb")),
                  let download = try? await URLSession.shared.data(from: artURL),
                  let image = NSImage(data: download.0) else { return }
            artCache[track] = image
            guard trackKey == track, artKey.isEmpty else { return }
            artwork = image
            accent = image.notchAccent
        }
    }

    // MARK: Commands

    func togglePlayPause() {
        elapsedBase = elapsed(at: Date())
        elapsedStamp = Date()
        isPlaying.toggle()
        if !isPlaying { pausedAt = Date() }
        sendCommand(2)
    }

    func next() { sendCommand(4) }
    func previous() { sendCommand(5) }

    func seek(to seconds: Double) {
        elapsedBase = seconds
        elapsedStamp = Date()
        runOneShot("ObjC.bindFunction('MRMediaRemoteSetElapsedTime',['void',['double']]);$.MRMediaRemoteSetElapsedTime(\(seconds))")
    }

    func openPlayerApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// MRMediaRemoteCommand: 0 play, 1 pause, 2 toggle, 3 stop, 4 next, 5 previous.
    private func sendCommand(_ command: Int) {
        runOneShot("ObjC.bindFunction('MRMediaRemoteSendCommand',['bool',['int','id']]);$.MRMediaRemoteSendCommand(\(command),$.NSDictionary.dictionary)")
    }

    private func runOneShot(_ body: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // MediaRemote sends over XPC asynchronously; exiting right away drops the command.
        proc.arguments = ["-l", "JavaScript", "-e", Self.loadFramework + body + ";delay(0.4)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    }

    // MARK: Scripts

    private static let loadFramework =
        "ObjC.import('Foundation');$.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;"

    private static func writeScript(named name: String, contents: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchNest", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static let watchScript = """
    ObjC.import('Foundation')
    $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load
    const R = $.NSClassFromString('MRNowPlayingRequest')
    const out = $.NSFileHandle.fileHandleWithStandardOutput
    const K = 'kMRMediaRemoteNowPlayingInfo'
    const isNil = v => v === undefined || v === null || v.isNil()
    const str = v => { if (isNil(v)) return ''; const u = ObjC.unwrap(v); return u == null ? '' : String(u) }
    const num = v => { if (isNil(v)) return 0; const n = Number(ObjC.unwrap(v)); return isFinite(n) ? n : 0 }

    function snapshot() {
      const o = { title: '', artist: '', album: '', app: '', bundle: '', playing: false,
                  duration: 0, elapsed: 0, timestamp: 0, artKey: '' }
      let art = null
      const item = R.localNowPlayingItem
      if (!isNil(item)) {
        const info = item.nowPlayingInfo
        if (!isNil(info)) {
          o.title = str(info.valueForKey(K + 'Title'))
          o.artist = str(info.valueForKey(K + 'Artist'))
          o.album = str(info.valueForKey(K + 'Album'))
          o.duration = num(info.valueForKey(K + 'Duration'))
          o.elapsed = num(info.valueForKey(K + 'ElapsedTime'))
          const ts = info.valueForKey(K + 'Timestamp')
          if (!isNil(ts)) o.timestamp = ts.timeIntervalSince1970
          const data = info.valueForKey(K + 'ArtworkData')
          if (!isNil(data)) { art = data; o.artKey = o.title + '|' + o.artist + '|' + data.length }
        }
      }
      const path = R.localNowPlayingPlayerPath
      if (!isNil(path)) {
        const client = path.client
        if (!isNil(client)) { o.app = str(client.displayName); o.bundle = str(client.bundleIdentifier) }
      }
      o.playing = R.localIsPlaying === true
      return [o, art]
    }

    ObjC.bindFunction('getppid', ['int', []])
    let last = '', lastArtKey = null
    const started = Date.now()
    // Exit after 10 minutes (the app restarts us) or as soon as the app is gone.
    while (Date.now() - started < 10 * 60 * 1000 && $.getppid() !== 1) {
      let o, art = null
      try { [o, art] = snapshot() } catch (e) { o = { error: String(e) } }
      const line = JSON.stringify(o)
      if (line !== last) {
        last = line
        if (o.artKey !== lastArtKey) {
          lastArtKey = o.artKey
          if (art) o.art = ObjC.unwrap(art.base64EncodedStringWithOptions(0))
        }
        out.writeData($(JSON.stringify(o) + '\\n').dataUsingEncoding($.NSUTF8StringEncoding))
      }
      delay(0.5)
    }
    """
}
