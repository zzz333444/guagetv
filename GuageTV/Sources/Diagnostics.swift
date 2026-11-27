import Foundation

/// In-app diagnostics ring buffer (v1.38): spider failures and
/// playback failures land here with timestamps so the user can
/// export one text file and hand it over — no more guessing from
/// a one-line error page. Stored in UserDefaults, capped, and
/// every message is trimmed (a traceback's first lines carry the
/// signal; its tail is noise).
enum Diagnostics {
    private static let key = "diagnostics.log.v1"
    private static let cap = 200

    struct Entry: Codable {
        var t: TimeInterval
        var c: String
        var m: String
    }

    static func log(_ category: String, _ message: String) {
        // Keep the TAIL of long messages: a Python traceback puts
        // the actual exception (the one line that matters) at the
        // very end, and the first version of this log cut exactly
        // that off at 600 chars.
        let trimmed: String
        if message.count > 900 {
            trimmed = String(message.prefix(250)) + "\n…（中略）…\n" + String(message.suffix(650))
        } else {
            trimmed = message
        }
        DispatchQueue.global(qos: .utility).async {
            var list = entries()
            list.append(Entry(t: Date().timeIntervalSince1970, c: category, m: trimmed))
            if list.count > cap { list.removeFirst(list.count - cap) }
            if let data = try? JSONEncoder().encode(list) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    static func entries() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return list
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - 起播三段打点（v2.31）

    /// Aggregated playback timing, kept apart from the 200-line
    /// text log: per-stage counts / totals / slow counts plus the
    /// auto-line-failover ledger, so Settings → 关于 can show
    /// "最慢一段是哪段" without scrolling a log. Slow = resolve
    /// >3s, first frame >5s, HLS playlist/segment >2s.
    struct TimingStats: Codable {
        var resolveCount = 0
        var resolveTotalMs = 0
        var resolveSlow = 0
        var firstFrameCount = 0
        var firstFrameTotalMs = 0
        var firstFrameSlow = 0
        /// v2.63 首帧分桶：引擎（原生/mpv）× 内容（点播/直播）。
        /// 键形如 "原生·点播"；旧数据无此字段时解码取空字典，
        /// 从零累计，不影响旧汇总字段（两者并行记）。
        struct FirstFrameBucket: Codable {
            var count = 0
            var totalMs = 0
            var slow = 0
        }
        var firstFrameBuckets: [String: FirstFrameBucket] = [:]
        var playlistCount = 0
        var playlistTotalMs = 0
        var playlistSlow = 0
        var playlistCacheHits = 0
        var segmentCount = 0
        var segmentTotalMs = 0
        var segmentSlow = 0
        var segmentCacheHits = 0
        var failoverAttempts = 0
        var failoverSuccess = 0
        var failoverByReason: [String: Int] = [:]
    }

    private static let timingKey = "diagnostics.playbackTiming.v1"
    private static let timingQueue = DispatchQueue(label: "guage.diagnostics.timing")

    private static func updateTiming(_ mutate: @escaping (inout TimingStats) -> Void) {
        timingQueue.async {
            var stats = timingStats()
            mutate(&stats)
            if let data = try? JSONEncoder().encode(stats) {
                UserDefaults.standard.set(data, forKey: timingKey)
            }
        }
    }

    static func timingStats() -> TimingStats {
        guard let data = UserDefaults.standard.data(forKey: timingKey),
              let stats = try? JSONDecoder().decode(TimingStats.self, from: data)
        else { return TimingStats() }
        return stats
    }

    /// 解析段：spider playerContent / 解析接口整段耗时。
    /// Callers pass the start date; the ms math lives here so
    /// every call site measures the same way.
    static func recordResolve(started: Date, ok: Bool) {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        updateTiming { stats in
            stats.resolveCount += 1
            stats.resolveTotalMs += ms
            if ms > 3000 { stats.resolveSlow += 1 }
        }
        _ = ok
    }

    /// 引擎段：打开播放器到首次进入播放状态（首帧近似值）。
    /// v2.63：engine/isLive 不再丢弃——按引擎（原生/mpv）×
    /// 内容（点播/直播）进分桶；总汇总字段仍并行记，旧数据
    /// 与旧口径（慢阈值 >5s）不变。
    static func recordFirstFrame(ms: Int, engine: String, isLive: Bool) {
        let engineLabel = engine == "mpv" ? "mpv" : "原生"
        let bucketKey = engineLabel + "·" + (isLive ? "直播" : "点播")
        updateTiming { stats in
            stats.firstFrameCount += 1
            stats.firstFrameTotalMs += ms
            if ms > 5000 { stats.firstFrameSlow += 1 }
            var bucket = stats.firstFrameBuckets[bucketKey] ?? TimingStats.FirstFrameBucket()
            bucket.count += 1
            bucket.totalMs += ms
            if ms > 5000 { bucket.slow += 1 }
            stats.firstFrameBuckets[bucketKey] = bucket
        }
    }

    /// 首帧分桶汇总（固定桶序：原生·点播、原生·直播、
    /// mpv·点播、mpv·直播；只列有样本的桶）。诊断卡与导出
    /// 文本共用 timingSummary()，分桶行由其一并带出。
    static func firstFrameBucketSummary() -> String {
        let s = timingStats()
        let order = ["原生·点播", "原生·直播", "mpv·点播", "mpv·直播"]
        let parts = order.compactMap { key -> String? in
            guard let b = s.firstFrameBuckets[key], b.count > 0 else { return nil }
            return "\(key)平均 \(b.totalMs / b.count)ms（\(b.count) 次，慢 \(b.slow) 次）"
        }
        guard !parts.isEmpty else { return "" }
        return "首帧分桶：" + parts.joined(separator: " · ")
    }

    /// 代理段：HLS 播放列表上游取回耗时（去广告代理内）。
    static func recordHLSPlaylist(ms: Int) {
        updateTiming { stats in
            stats.playlistCount += 1
            stats.playlistTotalMs += ms
            if ms > 2000 { stats.playlistSlow += 1 }
        }
    }

    static func recordHLSPlaylistCacheHit() {
        updateTiming { $0.playlistCacheHits += 1 }
    }

    /// 代理段：单个分片上游取回耗时（缓存命中不计入）。
    static func recordHLSSegment(ms: Int) {
        updateTiming { stats in
            stats.segmentCount += 1
            stats.segmentTotalMs += ms
            if ms > 2000 { stats.segmentSlow += 1 }
        }
    }

    static func recordSegmentCacheHit() {
        updateTiming { $0.segmentCacheHits += 1 }
    }

    /// 自动换线：attempt 在换线触发时记，success 只在新线路
    /// 解析出播放地址时记（“换线后解析成功”，不是“播出来了”——
    /// 播出来由首帧打点另行证明）。
    static func recordFailover(reason: String, success: Bool) {
        updateTiming { stats in
            stats.failoverAttempts += 1
            stats.failoverByReason[reason, default: 0] += 1
            if success { stats.failoverSuccess += 1 }
        }
    }

    static func timingSummary() -> String {
        let s = timingStats()
        guard s.resolveCount + s.firstFrameCount + s.playlistCount + s.segmentCount > 0 else {
            return "起播打点：暂无数据，播一部片后这里显示解析 / 首帧 / HLS 各段平均耗时与自动换线统计。"
        }
        func avg(_ total: Int, _ count: Int) -> Int { count > 0 ? total / count : 0 }
        var stages: [(String, Int)] = []
        if s.resolveCount > 0 { stages.append(("解析", avg(s.resolveTotalMs, s.resolveCount))) }
        if s.firstFrameCount > 0 { stages.append(("首帧", avg(s.firstFrameTotalMs, s.firstFrameCount))) }
        if s.playlistCount > 0 { stages.append(("HLS 播放列表", avg(s.playlistTotalMs, s.playlistCount))) }
        if s.segmentCount > 0 { stages.append(("HLS 分片", avg(s.segmentTotalMs, s.segmentCount))) }
        let slowest = stages.max(by: { $0.1 < $1.1 })?.0 ?? "—"
        var out = "起播打点 · 解析平均 \(avg(s.resolveTotalMs, s.resolveCount))ms（\(s.resolveCount) 次，慢 \(s.resolveSlow) 次）"
            + " · 首帧平均 \(avg(s.firstFrameTotalMs, s.firstFrameCount))ms（\(s.firstFrameCount) 次，慢 \(s.firstFrameSlow) 次）"
            + " · HLS 播放列表平均 \(avg(s.playlistTotalMs, s.playlistCount))ms（\(s.playlistCount) 次，缓存命中 \(s.playlistCacheHits) 次）"
            + " · 分片平均 \(avg(s.segmentTotalMs, s.segmentCount))ms（\(s.segmentCount) 次，缓存命中 \(s.segmentCacheHits) 次）"
            + " · 最慢一段：\(slowest)"
        let buckets = firstFrameBucketSummary()
        if !buckets.isEmpty { out += " · " + buckets }
        if s.failoverAttempts > 0 {
            let reasons = s.failoverByReason
                .sorted(by: { $0.value > $1.value })
                .map { "\($0.key)×\($0.value)" }.joined(separator: "、")
            out += " · 自动换线 \(s.failoverAttempts) 次，换线后解析成功 \(s.failoverSuccess) 次（\(reasons)）"
        }
        return out
    }

    /// 同类消息折叠（v1.70）：同一分类 + 同一文本只留一组，
    /// 记出现次数与首末时间。重复刷屏的同一条蜘蛛报错
    /// （比如冷启动重试时连刷十几条）在导出里只占一行。
    struct FoldedEntry {
        var c: String
        var m: String
        var count: Int
        var first: TimeInterval
        var last: TimeInterval
    }

    static func foldedEntries() -> [FoldedEntry] {
        var order: [String] = []
        var map: [String: FoldedEntry] = [:]
        for e in entries() {
            let k = e.c + "\n" + e.m
            if var f = map[k] {
                f.count += 1
                f.last = e.t
                map[k] = f
            } else {
                map[k] = FoldedEntry(c: e.c, m: e.m, count: 1, first: e.t, last: e.t)
                order.append(k)
            }
        }
        return order.compactMap { map[$0] }
    }

    static func exportText() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm:ss"
        let folded = foldedEntries()
        var out = "呱壳诊断日志（共 \(entries().count) 条，折叠后 \(folded.count) 组）\n"
        out += timingSummary() + "\n"
        // 按分类汇总一行，扫一眼就知道哪类问题最多。
        var byCategory: [(String, Int)] = []
        for f in folded {
            if let i = byCategory.firstIndex(where: { $0.0 == f.c }) {
                byCategory[i].1 += f.count
            } else {
                byCategory.append((f.c, f.count))
            }
        }
        if !byCategory.isEmpty {
            out += "分类统计：" + byCategory.map { "\($0.0)×\($0.1)" }.joined(separator: "、") + "\n"
        }
        for f in folded {
            if f.count > 1 {
                out += "[\(fmt.string(from: Date(timeIntervalSince1970: f.first)))～\(fmt.string(from: Date(timeIntervalSince1970: f.last)))] [\(f.c)] ×\(f.count) \(f.m)\n"
            } else {
                out += "[\(fmt.string(from: Date(timeIntervalSince1970: f.first)))] [\(f.c)] \(f.m)\n"
            }
        }
        return out
    }
}

/// 冷启动二段打点（v2.46）：进程启动时刻由 GuageTVApp.init 在
/// 最早时机记下；首帧、线路解析、模块索引三处各记一条诊断
/// 日志（分类「冷启动」），供设置 → 关于 → 诊断里核对二段
/// 化前后耗时。start() 只在首次调用时记时刻，重复调用不
/// 覆盖；首帧只记一次（ContentView.onAppear 在切 tab 时也
/// 会触发，不应重复记）。
enum StartupTiming {
    private static var t0: CFAbsoluteTime?
    private static var firstFrameMarked = false
    /// v2.57: 发现内容首出只记一次（与首帧守卫同款）。
    private static var firstContentMarked = false

    static func start() {
        if t0 == nil { t0 = CFAbsoluteTimeGetCurrent() }
    }

    /// 相对进程启动的毫秒数（start 未调过时返回 0，不崩）。
    static func msSinceStart() -> Int {
        guard let t0 else { return 0 }
        return Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    static func mark(_ stage: String) {
        Diagnostics.log("冷启动", "\(stage) · 启动后 \(msSinceStart())ms")
    }

    static func markFirstFrameOnce() {
        guard !firstFrameMarked else { return }
        firstFrameMarked = true
        mark("首帧已出")
    }

    /// v2.57: 发现页内容首次上屏（缓存画出或首个 trending
    /// 列表落定）。v2.46 的三处打点只剩两处——「模块索引」
    /// 那一处随 v2.50 模块推荐行移除而消失（发现页不再读
    /// index.json，FWDStore.records() 只在模块页 onAppear
    /// 调用、不在启动路径上）；补这一处恢复三段对照：壳出
    /// （首帧）与内容出之间的差值就是首屏可交互的真实耗时。
    static func markFirstContentOnce() {
        guard !firstContentMarked else { return }
        firstContentMarked = true
        mark("发现内容已出")
    }
}
