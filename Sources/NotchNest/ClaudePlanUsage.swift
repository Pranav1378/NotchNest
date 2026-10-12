import Foundation

/// Claude's own usage numbers, read from the file the Claude app keeps on this Mac
/// (~/Library/Application Support/Claude/plan-usage-history.json). Each sample holds the 5-hour
/// window ("fh") and the weekly one ("sd") as percentages, so the notch can show them without
/// opening the app, signing in to anything, or touching credentials.
@Observable @MainActor
final class ClaudePlanUsage {
    struct Sample: Equatable {
        var session: Double
        var week: Double
        var at: Date
    }

    private(set) var latest: Sample?
    @ObservationIgnored private var timer: Timer?

    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")

    var isAvailable: Bool { FileManager.default.fileExists(atPath: Self.file.path) }

    func start() {
        reload()
        // The Claude app writes a new sample every few minutes while it runs.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func reload() {
        guard let sample = Self.read() else { return }
        if sample != latest {
            latest = sample
            ActivityLog.note("claude plan usage: session \(Int(sample.session))%, week \(Int(sample.week))%")
        }
    }

    /// The newest sample in the file.
    static func read(from url: URL = file) -> Sample? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> Sample? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = root["samples"] as? [[String: Any]] else { return nil }
        // Samples are in order, but take the newest by timestamp to be safe.
        let newest = samples.compactMap { sample -> Sample? in
            guard let milliseconds = (sample["t"] as? NSNumber)?.doubleValue,
                  let usage = sample["u"] as? [String: Any] else { return nil }
            let session = (usage["fh"] as? NSNumber)?.doubleValue
            let week = (usage["sd"] as? NSNumber)?.doubleValue
            guard session != nil || week != nil else { return nil }
            return Sample(session: session ?? 0, week: week ?? 0,
                          at: Date(timeIntervalSince1970: milliseconds / 1000))
        }
        .max { $0.at < $1.at }
        return newest
    }
}
