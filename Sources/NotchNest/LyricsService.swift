import Foundation

struct LyricLine: Hashable {
    let time: Double
    let text: String
}

/// Time-synced lyrics from LRCLIB (free, no account), looked up by title and artist.
@Observable @MainActor
final class LyricsService {
    private(set) var lines: [LyricLine] = []
    /// The track `lines` belong to, as `MediaController.trackIdentity`.
    private(set) var trackKey = ""
    @ObservationIgnored private var cache: [String: [LyricLine]] = [:]

    /// Loads lyrics for the track if they aren't loaded already. Songs only: video has no artist.
    func load(title: String, artist: String, duration: Double) {
        let key = "\(title)|\(artist)"
        guard key != trackKey else { return }
        trackKey = key
        lines = cache[key] ?? []
        guard cache[key] == nil, !title.isEmpty, !artist.isEmpty else { return }
        Task {
            let found = await Self.fetch(title: title, artist: artist, duration: duration)
            cache[key] = found
            if trackKey == key { lines = found }
            ActivityLog.note("lyrics: \(found.isEmpty ? "none" : "\(found.count) lines") for \(title)")
        }
    }

    /// The line being sung at `time` (seconds into the song), if the song has started.
    func index(at time: Double) -> Int? {
        guard let first = lines.first, time >= first.time - 0.25 else { return nil }
        var low = 0, high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].time <= time + 0.25 { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private struct SearchResult: Decodable {
        let duration: Double?
        let syncedLyrics: String?
    }

    private static func fetch(title: String, artist: String, duration: Double) async -> [LyricLine] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("NotchNest/0.1 (personal notch app)", forHTTPHeaderField: "User-Agent")
        guard let response = try? await URLSession.shared.data(for: request),
              let results = try? JSONDecoder().decode([SearchResult].self, from: response.0) else { return [] }
        let synced = results.filter { !($0.syncedLyrics ?? "").isEmpty }
        // Several versions of a song can match; the one closest in length keeps the timing right.
        let best = duration > 0
            ? synced.min { abs(($0.duration ?? 0) - duration) < abs(($1.duration ?? 0) - duration) }
            : synced.first
        return best?.syncedLyrics.map(parse) ?? []
    }

    /// `[mm:ss.xx] text` lines; a line can carry several timestamps.
    static func parse(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in lrc.split(separator: "\n") {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let stamp = rest[rest.index(after: rest.startIndex)..<close].split(separator: ":")
                if stamp.count == 2, let minutes = Double(stamp[0]), let seconds = Double(stamp[1]) {
                    times.append(minutes * 60 + seconds)
                }
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            lines += times.map { LyricLine(time: $0, text: text) }
        }
        return lines.sorted { $0.time < $1.time }
    }
}
