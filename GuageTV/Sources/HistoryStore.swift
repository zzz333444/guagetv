import Combine
import Foundation
import UserNotifications

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
        /// 追剧更新： lastRemarks snapshots the site's "更新至第X集"
        /// text at favourite/last-detail time; hasUpdate flips when a
        /// later check sees different remarks.
        var lastRemarks: String = ""
        var hasUpdate: Bool = false
        var id: String { siteKey + "|" + vodId }

        enum CodingKeys: String, CodingKey {
            case vodId, siteKey, name, pic, episodeName, episodeURL
            case positionSeconds, durationSeconds, watchedSeconds, updatedAt
            case isFavourite, isWatchlist, lineID, siteName, episodeID
            case playFlag, playHeader, lastRemarks, hasUpdate
        }

        init(vodId: String, siteKey: String, name: String, pic: String,
             episodeName: String, episodeURL: String, positionSeconds: Double,
             durationSeconds: Double, watchedSeconds: Double, updatedAt: Date,
             isFavourite: Bool = false, isWatchlist: Bool = false,
             lineID: String = "", siteName: String = "", episodeID: String = "",
             playFlag: String = "", playHeader: [String: String] = [:],
             lastRemarks: String = "", hasUpdate: Bool = false) {
            self.vodId = vodId; self.siteKey = siteKey; self.name = name
            self.pic = pic; self.episodeName = episodeName
            self.episodeURL = episodeURL; self.positionSeconds = positionSeconds
            self.durationSeconds = durationSeconds
            self.watchedSeconds = watchedSeconds; self.updatedAt = updatedAt
            self.isFavourite = isFavourite; self.isWatchlist = isWatchlist
            self.lineID = lineID; self.siteName = siteName
            self.episodeID = episodeID; self.playFlag = playFlag
            self.playHeader = playHeader
            self.lastRemarks = lastRemarks
            self.hasUpdate = hasUpdate
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
            lastRemarks = try c.decodeIfPresent(String.self, forKey: .lastRemarks) ?? ""
            hasUpdate = try c.decodeIfPresent(Bool.self, forKey: .hasUpdate) ?? false
        }
    }

    @Published private(set) var entries: [Entry] = []

    /// Single combined store (v2.15): history entries + the daily
    /// watch ledger used to live in two files (history.json,
    /// daily-watch.json) — two disk reads and two JSON decodes on
    /// every cold start, two atomic writes on every heartbeat.
    /// One file, one read, one decode, one write. Legacy files are
    /// migrated on first load and removed after the combined file
    /// lands; a corrupt combined file falls back to the legacy pair.
    private struct CombinedStore: Codable {
        var entries: [Entry]
        var dailyWatched: [String: Double]
    }

    private let storeURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history-store.json")
    }()

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private let dailyFileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("daily-watch.json")
    }()

    init() {
        // v2.03 startup: ContentView mounts all four tabs at launch,
        // so this singleton used to JSON-decode on the main thread
        // before the first frame. Decode happens on a background
        // thread now; the published lists land on the main actor when
        // ready. Until then save() is a no-op (diskLoaded guard) so
        // an early write cannot clobber the not-yet-loaded files
        // with empty lists.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var migratedFromLegacy = false
            let store: CombinedStore = {
                if let data = try? Data(contentsOf: self.storeURL),
                   let decoded = try? JSONDecoder().decode(CombinedStore.self, from: data) {
                    return decoded
                }
                // Legacy pair: read both, then persist combined once.
                migratedFromLegacy = true
                let entries: [Entry] = {
                    guard let data = try? Data(contentsOf: self.fileURL),
                          let decoded = try? JSONDecoder().decode([Entry].self, from: data)
                    else { return [] }
                    return decoded
                }()
                let daily: [String: Double] = {
                    guard let data = try? Data(contentsOf: self.dailyFileURL),
                          let decoded = try? JSONDecoder().decode([String: Double].self, from: data)
                    else { return [:] }
                    return decoded
                }()
                return CombinedStore(entries: entries, dailyWatched: daily)
            }()
            if migratedFromLegacy,
               let data = try? JSONEncoder().encode(store) {
                try? data.write(to: self.storeURL, options: .atomic)
                try? FileManager.default.removeItem(at: self.fileURL)
                try? FileManager.default.removeItem(at: self.dailyFileURL)
            }
            await MainActor.run {
                self.entries = store.entries
                self.dailyWatched = store.dailyWatched
                self.diskLoaded = true
            }
        }
    }

    /// Set once the async init load above has landed; save() and
    /// saveDaily() stay quiet until then (see init).
    private var diskLoaded = false

    /// Last combined write, for the saveDaily() throttle below.
    private var lastPersist = Date.distantPast

    /// The single write path: one encode + one atomic write of the
    /// combined store (v2.15; previously save() and saveDaily()
    /// each wrote their own file).
    private func persist() {
        guard diskLoaded else { return }
        let store = CombinedStore(entries: entries, dailyWatched: dailyWatched)
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: storeURL, options: .atomic)
        lastPersist = Date()
    }

    private func saveDaily() {
        // The heartbeat calls saveDaily() then save() back to back;
        // the save() right after already persists the ledger, so a
        // standalone daily write is throttled to one per 30s.
        guard diskLoaded, Date().timeIntervalSince(lastPersist) > 30 else { return }
        persist()
    }

    func record(_ entry: Entry) {
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            var merged = entry
            merged.watchedSeconds += entries[i].watchedSeconds
            merged.isFavourite = entries[i].isFavourite
            merged.isWatchlist = entries[i].isWatchlist
            if merged.lastRemarks.isEmpty { merged.lastRemarks = entries[i].lastRemarks }
            merged.hasUpdate = entries[i].hasUpdate && merged.lastRemarks == entries[i].lastRemarks
            // v2.22: re-watching used to merge in place, so the show
            // sat buried until the player heartbeat floated it ~5 s
            // into playback. Float it now, like updatePosition does.
            entries.remove(at: i)
            entries.insert(merged, at: 0)
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
        if playing && accumulate {
            entries[i].watchedSeconds += 5
            dailyWatched[Self.dayKey(Date()), default: 0] += 5
            saveDaily()
        }
        entries[i].updatedAt = Date()
        let entry = entries.remove(at: i)
        entries.insert(entry, at: 0)
        save()
    }

    func remove(id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    func remove(ids: Set<String>) {
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    /// Finished = played to (or past) 95% of a known duration — the
    /// same cutoff continueWatching uses for "still watching".
    static func isFinished(_ entry: Entry) -> Bool {
        entry.durationSeconds > 0 && entry.positionSeconds >= entry.durationSeconds * 0.95
    }

    /// Batch-clear finished history (v2.11). Favourites are kept
    /// even when finished — deleting them would also drop the show
    /// from 追剧. Returns how many rows were removed.
    @discardableResult
    func removeFinished() -> Int {
        let before = entries.count
        entries.removeAll { Self.isFinished($0) && !$0.isFavourite }
        let removed = before - entries.count
        if removed > 0 { save() }
        return removed
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

    func isFavourite(siteKey: String, vodId: String) -> Bool {
        entries.first { $0.siteKey == siteKey && $0.vodId == vodId }?.isFavourite ?? false
    }

    /// Favourite from a detail page: flips the flag on the history
    /// entry when one exists; otherwise files the supplied stub (a
    /// detail-page snapshot with no playback yet) so the favourite
    /// survives before the first play.
    func setFavourite(stub: Entry, on: Bool) {
        if let i = entries.firstIndex(where: { $0.id == stub.id }) {
            entries[i].isFavourite = on
        } else if on {
            var fresh = stub
            fresh.isFavourite = true
            entries.insert(fresh, at: 0)
        }
        save()
    }

    /// Opening the detail page acknowledges a pending update: the
    /// badge clears and the remarks snapshot moves to what the page
    /// actually shows now.
    func markUpdateSeen(siteKey: String, vodId: String, remarks: String) {
        guard let i = entries.firstIndex(where: { $0.siteKey == siteKey && $0.vodId == vodId }) else { return }
        entries[i].hasUpdate = false
        if !remarks.isEmpty { entries[i].lastRemarks = remarks }
        save()
    }

    /// 追剧更新检测： re-fetch the detail of every CMS favourite on
    /// its own line and compare the "更新至…" remarks. py/JS
    /// favourites are skipped (their bridges load one spider at a
    /// time; a mass check would thrash them).
    ///
    /// v2.23: the 6-hour throttle lives here, not in the callers.
    /// The 追剧 page and the 记录页 favourites segment each fired
    /// a full re-check on every appearance, so flipping between
    /// the two pages re-fetched every CMS detail. Now an automatic
    /// check within 6 hours of the last one is a no-op; the manual
    /// "检测更新" button passes force: true. The timestamp is
    /// written up front, so two overlapping auto-checks cannot
    /// both run the full fetch.
    private static let favouritesCheckKey = "history.favouritesLastCheck.v1"

    func checkFavouritesForUpdates(force: Bool = false) async {
        let now = Date.now.timeIntervalSince1970
        if !force {
            let last = UserDefaults.standard.double(forKey: Self.favouritesCheckKey)
            if last > 0, now - last < 6 * 3600 { return }
        }
        UserDefaults.standard.set(now, forKey: Self.favouritesCheckKey)
        WatchNotify.requestAuthorizationIfNeeded()
        var newlyUpdated: [String] = []
        for entry in favourites {
            guard !entry.lineID.isEmpty,
                  let config = ConfigLibrary.load(id: entry.lineID),
                  let site = config.sites.first(where: { $0.key == entry.siteKey }),
                  site.kind == .cmsJSON || site.kind == .cmsXML,
                  let detail = try? await CMSClient(site: site).detail(id: entry.vodId),
                  !detail.remarks.isEmpty else { continue }
            let remarks = detail.remarks
            if remarks != entry.lastRemarks, !entry.lastRemarks.isEmpty || entry.hasUpdate == false {
                if remarks != entry.lastRemarks,
                   let i = entries.firstIndex(where: { $0.id == entry.id }) {
                    if !entries[i].hasUpdate { newlyUpdated.append(entries[i].name) }
                    entries[i].hasUpdate = true
                    save()
                }
            }
        }
        WatchNotify.postIfEnabled(titles: newlyUpdated)
    }

    var favourites: [Entry] { entries.filter(\.isFavourite) }
    var watchlist: [Entry] { entries.filter(\.isWatchlist) }
    var continueWatching: [Entry] {
        entries.filter { $0.durationSeconds > 0 && $0.positionSeconds < $0.durationSeconds * 0.95 }
    }

    /// Total watched seconds whose last update falls on the given day.
    /// v1.79: the daily ledger is the source of truth (real seconds
    /// watched that day, accumulated by the player heartbeat). Days
    /// before the ledger existed fall back to attributing each
    /// entry's lifetime total to its last-touch day.
    func watchedSeconds(on day: Date) -> Double {
        let key = Self.dayKey(day)
        if let seconds = dailyWatched[key] { return seconds }
        let cal = Calendar.current
        return entries.filter { cal.isDate($0.updatedAt, inSameDayAs: day) }
            .reduce(0) { $0 + $1.watchedSeconds }
    }

    /// Daily watch-time ledger (v1.79): "yyyy-MM-dd" → seconds actually
    /// watched that day. Drives the Profile heatmap and the
    /// week/month stats; v2.15 stores it in the combined
    /// history-store.json (see the top of this file).
    private(set) var dailyWatched: [String: Double] = [:]

    private static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func save() {
        persist()
    }
}

/// What a detail page needs to file a history entry for its playback.
struct HistorySeed {
    let lineID: String
    let siteKey: String
    let siteName: String
    let vodId: String
}

/// Local notifications for watchlist updates (v1.42). Posted
/// from the same throttled update check that fills the 追剧
/// page — no background fetching is promised: the check runs
/// when the app is opened / the 追剧 page refreshes, and a hit
/// raises a notification so the update is not missed.
enum WatchNotify {
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "watchNotify.enabled") as? Bool ?? true
    }

    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
        }
    }

    static func postIfEnabled(titles: [String]) {
        guard enabled, !titles.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "追剧更新"
            content.body = titles.count == 1
                ? "《\(titles[0])》更新了，点开追剧页就能看"
                : "《\(titles[0])》等 \(titles.count) 部追剧更新了"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "watch-update-\(Int(Date().timeIntervalSince1970))",
                content: content, trigger: nil)
            center.add(request)
        }
    }
}
