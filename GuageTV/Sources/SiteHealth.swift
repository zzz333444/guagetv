import Foundation

/// Per-site health memory (v1.40): every py invoke and jar call
/// records success/failure + latency here. Search uses the score
/// to order its pools — proven-fast sites answer first, chronic
/// failures sink — without the user curating anything.
enum SiteHealth {
    private static let defaultsKey = "siteHealth.v1"
    private static let lock = NSLock()
    private static var mirror: [String: [Double]]?

    /// value layout: [okCount, failCount, totalMs]
    private static func load() -> [String: [Double]] {
        if let mirror { return mirror }
        let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [Double]] ?? [:]
        mirror = stored
        return stored
    }

    static func record(_ key: String, ok: Bool, ms: Int) {
        guard !key.isEmpty else { return }
        lock.lock()
        var store = load()
        var entry = store[key] ?? [0, 0, 0]
        entry[ok ? 0 : 1] += 1
        entry[2] += Double(ms)
        store[key] = entry
        mirror = store
        UserDefaults.standard.set(store, forKey: defaultsKey)
        lock.unlock()
    }

    /// 0…1-ish score; unknown sites sit at neutral 0.5 so new
    /// sites are neither boosted nor buried.
    static func score(_ key: String) -> Double {
        lock.lock()
        let store = load()
        lock.unlock()
        guard let entry = store[key], entry[0] + entry[1] >= 2 else { return 0.5 }
        let total = entry[0] + entry[1]
        let rate = (entry[0] + 1) / (total + 2)
        let avgMs = entry[2] / max(total, 1)
        let speedAdjust = avgMs < 800 ? 0.05 : (avgMs > 4000 ? -0.05 : 0)
        return rate + speedAdjust
    }
}
