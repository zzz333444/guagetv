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
        // v1.06: enough context to re-open the detail page or resume
        // playback straight from the history list.
        var lineID: String = ""
        var siteName: String = ""
        var episodeID: String = ""
        var playFlag: String = ""
        var playHeader: [String: String] = [:]
        var id: String { siteKey + "|" + vodId }

        enum CodingKeys: String, CodingKey {
            case vodId, siteKey, name, pic, episodeName, episodeURL
            case positionSeconds, durationSeconds, watchedSeconds, updatedAt
            case isFavourite, isWatchlist, lineID, siteName, episodeID
            case playFlag, playHeader
        }

        init(vodId: String, siteKey: String, name: String, pic: String,
             episodeName: String, episodeURL: String, positionSeconds: Double,
             durationSeconds: Double, watchedSeconds: Double, updatedAt: Date,
             isFavourite: Bool = false, isWatchlist: Bool = false,
             lineID: String = "", siteName: String = "", episodeID: String = "",
             playFlag: String = "", playHeader: [String: String] = [:]) {
            self.vodId = vodId; self.siteKey = siteKey; self.name = name
            self.pic = pic; self.episodeName = episodeName
            self.episodeURL = episodeURL; self.positionSeconds = positionSeconds
            self.durationSeconds = durationSeconds
            self.watchedSeconds = watchedSeconds; self.updatedAt = updatedAt
            self.isFavourite = isFavourite; self.isWatchlist = isWatchlist
            self.lineID = lineID; self.siteName = siteName
            self.episodeID = episodeID; self.playFlag = playFlag
            self.playHeader = playHeader
        }

        /// Tolerant decoding: entries written before v1.06 lack the
        /// context fields and must still load.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            vodId = try c.decode(String.self, forKey: .vodId)
            siteKey = try c.decode(String.self, forKey: .siteKey)
            name = try c.decode(String.self, forKey: .name)
            pic = try c.decode(String.self, forKey: .pic)
            episodeName = try c.decode(String.self, forKey: .episodeName)
            episodeURL = try c.decode(String.self, forKey: .episodeURL)
            positionSeconds = try c.decode(Double.self, forKey: .positionSeconds)
            durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
            watchedSeconds = try c.decode(Double.self, forKey: .watchedSeconds)
            updatedAt = try c.decode(Date.self, forKey: .updatedAt)
            isFavourite = try c.decodeIfPresent(Bool.self, forKey: .isFavourite) ?? false
            isWatchlist = try c.decodeIfPresent(Bool.self, forKey: .isWatchlist) ?? false
            lineID = try c.decodeIfPresent(String.self, forKey: .lineID) ?? ""
            siteName = try c.decodeIfPresent(String.self, forKey: .siteName) ?? ""
            episodeID = try c.decodeIfPresent(String.self, forKey: .episodeID) ?? ""
            playFlag = try c.decodeIfPresent(String.self, forKey: .playFlag) ?? ""
            playHeader = try c.decodeIfPresent([String: String].self, forKey: .playHeader) ?? [:]
        }
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

    /// Player heartbeat: keep the resume point (and rough watch time)
    /// current, and float the entry to the top of the list.
    func updatePosition(id: String, position: Double, duration: Double,
                        playing: Bool, accumulate: Bool = true) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].positionSeconds = position
        if duration > 0 { entries[i].durationSeconds = duration }
        if playing && accumulate { entries[i].watchedSeconds += 5 }
        entries[i].updatedAt = Date()
        let entry = entries.remove(at: i)
        entries.insert(entry, at: 0)
        save()
    }

    func remove(id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        entries.removeAll()
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

/// What a detail page needs to file a history entry for its playback.
struct HistorySeed {
    let lineID: String
    let siteKey: String
    let siteName: String
    let vodId: String
}
