import Combine
import Foundation

/// Local watch history + favourites, persisted as JSON in the app sandbox.
/// Feeds three Rex-style surfaces: 继续观看 on Discover, the Profile stats
/// （今日时长 / 热力格 / 计数）, and resume-position in the player.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    struct Entry: Codable, Identifiable {
        var vodId: String
        var siteKey: String
        var name: String
        var pic: String
        var episodeName: String
        var episodeURL: String
        var positionSeconds: Double     // resume point
        var durationSeconds: Double
        var watchedSeconds: Double      // accumulated watch time (for stats)
        var updatedAt: Date
        var isFavourite: Bool = false
        var isWatchlist: Bool = false
        var id: String { siteKey + "|" + vodId }
    }

    @Published private(set) var entries: [Entry] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init() { load() }

    func record(_ entry: Entry) {
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            var merged = entry
            merged.watchedSeconds += entries[i].watchedSeconds
            merged.isFavourite = entries[i].isFavourite
            merged.isWatchlist = entries[i].isWatchlist
            entries[i] = merged
        } else {
            entries.insert(entry, at: 0)
        }
        save()
    }

    func toggleFavourite(siteKey: String, vodId: String) {
        guard let i = entries.firstIndex(where: { $0.siteKey == siteKey && $0.vodId == vodId }) else { return }
        entries[i].isFavourite.toggle()
        save()
    }

    var favourites: [Entry] { entries.filter(\.isFavourite) }
    var watchlist: [Entry] { entries.filter(\.isWatchlist) }
    var continueWatching: [Entry] {
        entries.filter { $0.durationSeconds > 0 && $0.positionSeconds < $0.durationSeconds * 0.95 }
    }

    /// Total watched seconds whose last update falls on the given day.
    func watchedSeconds(on day: Date) -> Double {
        let cal = Calendar.current
        return entries.filter { cal.isDate($0.updatedAt, inSameDayAs: day) }
            .reduce(0) { $0 + $1.watchedSeconds }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
