import SwiftUI
import JavaScriptCore

/// Forward-format JS modules (v1.58) — the module system the user
/// asked to enable. A module is ONE JavaScript file following the
/// public ForwardWidget spec (InchStudio/ForwardWidgets): a global
/// `WidgetMetadata` (id / title / version / modules[] / search),
/// async handler functions named by each module entry's
/// `functionName`, returning VideoItem dictionaries. Handlers talk
/// to the host through `Widget.http` (synchronous native transport,
/// awaited as a plain value), `Widget.html.load` (the SAME bundled
/// cheerio build the drpy engine uses), `Widget.dom`,
/// `Widget.storage` and `Widget.sharedCache`.
///
/// Rex note: Rex exposes no public module format of its own; the
/// JS modules circulating for this class of app follow the Forward
/// spec, which is what runs here. Encrypted modules (FWENC1) are a
/// proprietary envelope and are refused at import with a clear note.
///
/// Playback: an item's own videoUrl plays directly; a module with
/// a `loadResource` (type "stream") entry resolves the URL at play
/// time; otherwise loadDetail(link) is asked for the videoUrl.

// MARK: - Metadata model

struct FWDParam {
    var name: String
    var title: String = ""
    var type: String = "input"
    var value: String = ""
    var enumOptions: [FWDOption] = []
    var desc: String = ""
    /// Suggested values for input params (Forward spec
    /// `placeholders: [{title, value}]`) — e.g. rex-tmdb's 片单
    /// column carries a preset TMDB list URL here. v1.75.
    var placeholders: [FWDOption] = []
}

/// Custom Decodable (same pattern as FWDMeta): fields added after
/// an index file was written must not drop every stored module.
extension FWDParam: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, title, type, value, enumOptions, desc, placeholders
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "input"
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        enumOptions = try c.decodeIfPresent([FWDOption].self, forKey: .enumOptions) ?? []
        desc = try c.decodeIfPresent(String.self, forKey: .desc) ?? ""
        placeholders = try c.decodeIfPresent([FWDOption].self, forKey: .placeholders) ?? []
    }
}

struct FWDOption: Codable {
    var title: String
    var value: String
}

struct FWDModuleEntry: Codable {
    var id: String = ""
    var title: String = ""
    var functionName: String = ""
    var type: String = ""
    var params: [FWDParam] = []
}

struct FWDMeta {
    var id: String = ""
    var title: String = ""
    var version: String = ""
    var author: String = ""
    var description: String = ""
    var site: String = ""
    var icon: String = ""
    var modules: [FWDModuleEntry] = []
    var searchFunction: String?
    var searchParams: [FWDParam] = []
    var globalParams: [FWDParam] = []
    var hasDetail: Bool = false
    /// Column-result cache TTL in seconds, from the module's
    /// declared `cacheDuration` (Forward spec). 0 = not
    /// declared; the app default (30 min) applies. v2.06.
    var cacheDuration: Int = 0

    /// Entries the browse UI can render as lists: everything that
    /// is not a stream resolver or a danmu feed.
    var listModules: [FWDModuleEntry] {
        modules.filter { $0.type != "stream" && $0.type != "danmu" && $0.id != "loadResource" && !$0.functionName.isEmpty }
    }
    var resourceFunction: String? {
        modules.first { $0.id == "loadResource" || $0.type == "stream" }?.functionName
    }
}

/// Hand-rolled Decodable so index files written before a field
/// existed (e.g. `icon`, added in v1.59) still load instead of
/// dropping every imported module.
extension FWDMeta: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, version, author, description, site, icon
        case modules, searchFunction, searchParams, globalParams, hasDetail
        case cacheDuration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        site = try c.decodeIfPresent(String.self, forKey: .site) ?? ""
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? ""
        modules = try c.decodeIfPresent([FWDModuleEntry].self, forKey: .modules) ?? []
        searchFunction = try c.decodeIfPresent(String.self, forKey: .searchFunction)
        searchParams = try c.decodeIfPresent([FWDParam].self, forKey: .searchParams) ?? []
        globalParams = try c.decodeIfPresent([FWDParam].self, forKey: .globalParams) ?? []
        hasDetail = try c.decodeIfPresent(Bool.self, forKey: .hasDetail) ?? false
        cacheDuration = try c.decodeIfPresent(Int.self, forKey: .cacheDuration) ?? 0
    }
}

struct FWDRecord: Codable, Identifiable {
    var id: String
    var fileName: String
    var source: String
    var meta: FWDMeta
}

// MARK: - VideoItem

struct FWDItem: Identifiable {
    var id: String = ""
    var type: String = ""
    var title: String = ""
    var poster: String = ""
    var backdrop: String = ""
    var cover: String = ""
    var releaseDate: String = ""
    var rating: String = ""
    var overview: String = ""
    var mediaType: String = ""
    var link: String = ""
    var videoUrl: String = ""
    var durationText: String = ""
    var genreTitle: String = ""
    var episode: Int?
    var episodeItems: [FWDItem] = []
    var relatedItems: [FWDItem] = []
    var childItems: [FWDItem] = []
    var peoples: [(name: String, role: String)] = []

    var posterURL: String {
        [poster, backdrop, cover].first { !$0.isEmpty } ?? ""
    }
    var backdropURL: String {
        [backdrop, cover, poster].first { !$0.isEmpty } ?? ""
    }

    /// One-line "year · ★rating" caption for recommendation cards.
    var shortMetaLine: String {
        [String(releaseDate.prefix(4)), rating.isEmpty ? "" : "★\(rating)"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    init(_ d: [String: Any]) {
        func str(_ key: String) -> String {
            if let s = d[key] as? String { return s }
            if let n = d[key] as? NSNumber { return n.stringValue }
            return ""
        }
        id = str("id")
        type = str("type")
        title = str("title")
        poster = str("posterPath").isEmpty ? (str("posterUrl").isEmpty ? str("poster_url") : str("posterUrl")) : str("posterPath")
        backdrop = str("backdropPath")
        cover = str("coverUrl")
        // TMDB items carry raw image paths; expand them here so
        // every display slot downstream sees absolute URLs.
        if type == "tmdb" {
            if poster.hasPrefix("/") { poster = TMDBClient.imageURL(poster, size: "w500") }
            if backdrop.hasPrefix("/") { backdrop = TMDBClient.imageURL(backdrop, size: "w780") }
            if cover.hasPrefix("/") { cover = TMDBClient.imageURL(cover, size: "w500") }
        }
        releaseDate = str("releaseDate")
        rating = str("rating")
        overview = str("description")
        mediaType = str("mediaType")
        link = str("link")
        videoUrl = str("videoUrl")
        durationText = str("durationText")
        genreTitle = str("genreTitle")
        if let n = d["episode"] as? NSNumber { episode = n.intValue }
        episodeItems = (d["episodeItems"] as? [[String: Any]] ?? []).map(FWDItem.init)
        relatedItems = (d["relatedItems"] as? [[String: Any]] ?? []).map(FWDItem.init)
        childItems = (d["childItems"] as? [[String: Any]] ?? []).map(FWDItem.init)
        peoples = (d["peoples"] as? [[String: Any]] ?? []).map {
            (name: ($0["title"] as? String) ?? "", role: ($0["role"] as? String) ?? "")
        }.filter { !$0.name.isEmpty }
        if id.isEmpty { id = link.isEmpty ? title : link }
    }
}

extension FWDItem: Hashable {
    static func == (lhs: FWDItem, rhs: FWDItem) -> Bool {
        lhs.id == rhs.id && lhs.link == rhs.link && lhs.title == rhs.title
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(link)
        hasher.combine(title)
    }
}

// MARK: - Store

enum FWDStore {
    struct StoreFailure: Error, CustomStringConvertible, LocalizedError {
        let message: String
        var description: String { message }
        var errorDescription: String? { message }
    }

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("widgets", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func records() -> [FWDRecord] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
              let list = try? JSONDecoder().decode([FWDRecord].self, from: data) else { return [] }
        return list
    }

    private static func save(_ records: [FWDRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: dir.appendingPathComponent("index.json"), options: .atomic)
    }

    static func source(for record: FWDRecord) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(record.fileName), encoding: .utf8)
    }

    @discardableResult
    static func importModule(source: String, origin: String) throws -> FWDRecord {
        if source.hasPrefix("FWENC1") {
            throw StoreFailure(message: "这是加密模块（FWENC1），内容已加密无法读取，暂不支持导入；请向模块作者索取未加密版本")
        }
        guard source.contains("WidgetMetadata") else {
            throw StoreFailure(message: "不是 Forward 模块（找不到 WidgetMetadata）")
        }
        let meta = try FWDRuntime.parseMetadata(source: source)
        guard !meta.id.isEmpty else {
            throw StoreFailure(message: "模块缺少 id")
        }
        let fileName = meta.id.replacingOccurrences(of: "/", with: "_") + ".js"
        try source.write(to: dir.appendingPathComponent(fileName),
                         atomically: true, encoding: .utf8)
        let record = FWDRecord(id: meta.id, fileName: fileName, source: origin, meta: meta)
        var all = records()
        all.removeAll { $0.id == meta.id }
        all.append(record)
        save(all)
        return record
    }

    static func delete(_ record: FWDRecord) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(record.fileName))
        save(records().filter { $0.id != record.id })
        clearCheckResult(for: record.id)
        // v2.07: a deleted module's per-module storage and cached
        // columns go with it — otherwise a later re-import of the
        // same id resurrects stale credentials and stale lists.
        // Widget.sharedCache is intentionally shared across
        // modules (Forward spec) and is left alone.
        UserDefaults.standard.removeObject(forKey: "fwd.storage.\(record.id)")
        FWDColumnCache.clear(moduleID: record.id)
    }

    /// v1.94: per-module self-check result, kept on the card
    /// (last check time + conclusion). Stored in UserDefaults
    /// so it survives restarts; cleared when the module is deleted.
    struct CheckResult: Codable {
        var time: Date
        var ok: Bool
        var summary: String
        /// v2.18: per-column detail (title, pass/fail, item
        /// count or error, duration in ms). Optional so
        /// results saved by older builds still decode.
        var columns: [ColumnCheck]? = nil
    }

    /// One list column's self-check outcome (v2.18).
    struct ColumnCheck: Codable {
        var title: String
        var ok: Bool
        var count: Int
        var error: String
        var ms: Int
    }

    private static let checkResultsKey = "fwd.checkResults.v1"

    static func checkResult(for recordID: String) -> CheckResult? {
        guard let data = UserDefaults.standard.data(forKey: checkResultsKey),
              let all = try? JSONDecoder().decode([String: CheckResult].self, from: data) else { return nil }
        return all[recordID]
    }

    static func saveCheckResult(_ result: CheckResult, for recordID: String) {
        var all: [String: CheckResult] = [:]
        if let data = UserDefaults.standard.data(forKey: checkResultsKey),
           let decoded = try? JSONDecoder().decode([String: CheckResult].self, from: data) {
            all = decoded
        }
        all[recordID] = result
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: checkResultsKey)
        }
    }

    static func clearCheckResult(for recordID: String) {
        guard let data = UserDefaults.standard.data(forKey: checkResultsKey),
              var all = try? JSONDecoder().decode([String: CheckResult].self, from: data) else { return }
        all.removeValue(forKey: recordID)
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: checkResultsKey)
        }
    }

    /// Import from a URL: a bare .js module, or a .fwd subscription
    /// (JSON listing module URLs under widgets / modules / urls,
    /// entries as strings or {url} objects; plain-text line lists
    /// also accepted). Returns how many modules landed.
    static func importRemote(_ urlString: String) async throws -> Int {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw StoreFailure(message: "链接无效")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw StoreFailure(message: "下载内容无法读取")
        }
        if text.contains("WidgetMetadata") || text.hasPrefix("FWENC1") {
            _ = try importModule(source: text, origin: trimmed)
            return 1
        }
        var links: [String] = []
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["widgets", "modules", "urls", "list"] {
                if let arr = json[key] as? [Any] {
                    for entry in arr {
                        if let s = entry as? String { links.append(s) }
                        if let o = entry as? [String: Any] {
                            for k in ["url", "link", "src"] {
                                if let s = o[k] as? String { links.append(s); break }
                            }
                        }
                    }
                }
            }
        }
        if links.isEmpty {
            links = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("http") }
        }
        guard !links.isEmpty else {
            throw StoreFailure(message: "订阅里没找到模块链接")
        }
        var imported = 0
        for link in links {
            guard let u = URL(string: link),
                  let (d, _) = try? await URLSession.shared.data(from: u),
                  let js = String(data: d, encoding: .utf8),
                  (try? importModule(source: js, origin: link)) != nil else { continue }
            imported += 1
        }
        guard imported > 0 else {
            throw StoreFailure(message: "订阅里的模块都没导入成功")
        }
        return imported
    }

    /// Local-file counterpart of importRemote: the picked file is
    /// either a module .js (imported directly) or a .fwd / text
    /// subscription (its links are fetched and imported).
    static func importFileText(_ text: String, origin: String) async throws -> Int {
        if text.contains("WidgetMetadata") || text.hasPrefix("FWENC1") {
            _ = try importModule(source: text, origin: origin)
            return 1
        }
        var links: [String] = []
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["widgets", "modules", "urls", "list"] {
                if let arr = json[key] as? [Any] {
                    for entry in arr {
                        if let s = entry as? String { links.append(s) }
                        if let o = entry as? [String: Any] {
                            for k in ["url", "link", "src"] {
                                if let s = o[k] as? String { links.append(s); break }
                            }
                        }
                    }
                }
            }
        }
        if links.isEmpty {
            links = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("http") }
        }
        guard !links.isEmpty else {
            throw StoreFailure(message: "文件里没找到模块或订阅链接")
        }
        var imported = 0
        for link in links {
            guard let u = URL(string: link),
                  let (d, _) = try? await URLSession.shared.data(from: u),
                  let js = String(data: d, encoding: .utf8),
                  (try? importModule(source: js, origin: link)) != nil else { continue }
            imported += 1
        }
        guard imported > 0 else {
            throw StoreFailure(message: "订阅里的模块都没导入成功")
        }
        return imported
    }
}

/// Column-result cache (v2.06): re-entering a module column
/// replays the last page-1 result instead of re-running the JS
/// handler and the network. Entries live in UserDefaults as one
/// JSON blob per key (rows + savedAt), capped at 30 entries with
/// the oldest evicted. TTL honours the module's declared
/// `cacheDuration` (seconds) when present, otherwise 30 min.
/// Only page-1 list results are cached, never searches, never
/// empty results (a transient 0 must not poison the next visit).
enum FWDColumnCache {
    private static let storeKey = "fwd.columnCache.v1"
    private static let maxEntries = 30
    static let defaultTTL: TimeInterval = 1800

    static func key(moduleID: String, columnID: String, params: [String: Any]) -> String {
        let paramsJSON = (try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return moduleID + "|" + columnID + "|" + paramsJSON
    }

    static func get(key: String, ttl: TimeInterval) -> [[String: Any]]? {
        guard let data = (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: Data])?[key],
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let savedAt = obj["savedAt"] as? TimeInterval,
              Date().timeIntervalSince1970 - savedAt < ttl,
              let rows = obj["rows"] as? [[String: Any]] else { return nil }
        return rows
    }

    static func set(key: String, rows: [[String: Any]]) {
        var dict = (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: Data]) ?? [:]
        if dict.count >= maxEntries {
            var oldestKey: String?
            var oldestAt = TimeInterval.greatestFiniteMagnitude
            for (k, data) in dict {
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let at = obj["savedAt"] as? TimeInterval, at < oldestAt {
                    oldestAt = at
                    oldestKey = k
                }
            }
            if let oldestKey { dict.removeValue(forKey: oldestKey) }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "savedAt": Date().timeIntervalSince1970, "rows": rows]) else { return }
        dict[key] = data
        UserDefaults.standard.set(dict, forKey: storeKey)
    }

    /// Drop every cached column of one module (module delete,
    /// v2.07): keys are "moduleID|columnID|params…".
    static func clear(moduleID: String) {
        guard var dict = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: Data] else { return }
        dict = dict.filter { !$0.key.hasPrefix(moduleID + "|") }
        UserDefaults.standard.set(dict, forKey: storeKey)
    }
}

// MARK: - Runtime

final class FWDRuntime {
    struct FWDfailure: Error, CustomStringConvertible, LocalizedError {
        /// Chinese error class (v2.01): network failure, script
        /// exception and timeout are reported separately instead
        /// of one undifferentiated message, so the module page
        /// and diagnostics name the actual cause. `other` covers
        /// host-side engine/resource failures, which are neither
        /// a network nor a module-script problem.
        enum Kind: String {
            case network = "网络失败"
            case script = "脚本异常"
            case timeout = "超时"
            case other = "模块错误"
        }
        let message: String
        let kind: Kind
        init(message: String, kind: Kind = .other) {
            self.message = message
            self.kind = kind
        }
        var description: String { "[\(kind.rawValue)] \(message)" }
        // Without LocalizedError, localizedDescription degrades
        // to "(GuageTV.FWDRuntime.FWDfailure error 1.)" and the
        // real cause never reaches the screen (device report,
        // v1.76): the message IS the diagnosis, surface it.
        var errorDescription: String? { "[\(kind.rawValue)] \(message)" }

        /// Classify a module rejection message: a sub-request
        /// timeout ("子请求超时") or the 60 s call budget reads
        /// as timeout, transport failures as network, everything
        /// else as a script error. The strings it matches are
        /// the ones this file and JSRuntime.syncFetch produce,
        /// so the classification is deterministic, not a guess
        /// over arbitrary module text.
        static func classifyModuleError(_ text: String) -> Kind {
            if text.contains("超时") { return .timeout }
            if text.contains("网络") || text.contains("无网络")
                || text.contains("无法连接") || text.contains("找不到服务器")
                || text.contains("连接中断") || text.contains("证书") {
                return .network
            }
            return .script
        }
    }

    private let queue = DispatchQueue(label: "guage.fwd")
    private let widgetID: String
    private var lastException: String?

    init(widgetID: String) {
        self.widgetID = widgetID
    }

    static func parseMetadata(source: String) throws -> FWDMeta {
        try FWDRuntime(widgetID: "meta").parseMetadataLocked(source: source)
    }

    func call(function: String, params: [String: Any], source: String) async throws -> Any? {
        let paramsJSON = (try? JSONSerialization.data(withJSONObject: params))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return try await callRaw(function: function, argumentJSON: paramsJSON, source: source)
    }

    /// loadDetail is the one handler that takes a bare string
    /// (the item's link), not a params object.
    func callString(function: String, argument: String, source: String) async throws -> Any? {
        let argumentJSON = (try? JSONSerialization.data(withJSONObject: [argument]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let inner = String(argumentJSON.dropFirst().dropLast())
        return try await callRaw(function: function, argumentJSON: inner, source: source)
    }

    private func callRaw(function: String, argumentJSON: String, source: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.callLocked(function: function, argumentJSON: argumentJSON, source: source)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: context

    private func makeContext(source: String) throws -> JSContext {
        guard let ctx = JSContext() else {
            throw FWDfailure(message: "JS 引擎创建失败")
        }
        lastException = nil
        ctx.exceptionHandler = { [weak self] _, exception in
            self?.lastException = exception?.toString() ?? "unknown JS error"
        }
        installNatives(ctx)
        for file in ["prelude.js", "cheerio.js"] {
            guard let url = Bundle.main.url(forResource: file, withExtension: nil,
                                            subdirectory: "JSBundle"),
                  let src = try? String(contentsOf: url, encoding: .utf8) else {
                throw FWDfailure(message: "JS 资源缺失：\(file)")
            }
            lastException = nil
            ctx.evaluateScript("(function(){\n" + src + "\n})();")
            if let lastException {
                throw FWDfailure(message: "引擎资源加载失败（\(file)）：\(lastException)", kind: .script)
            }
        }
        lastException = nil
        installShim(ctx)
        if let lastException {
            throw FWDfailure(message: "宿主接口安装失败：\(lastException)", kind: .script)
        }
        lastException = nil
        ctx.evaluateScript(source)
        if let lastException {
            throw FWDfailure(message: "模块加载失败：\(lastException)", kind: .script)
        }
        return ctx
    }

    private func parseMetadataLocked(source: String) throws -> FWDMeta {
        let ctx = try makeContext(source: source)
        guard let json = ctx.evaluateScript("JSON.stringify(globalThis.WidgetMetadata || null)")?.toString(),
              json != "null", json != "undefined",
              let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FWDfailure(message: "模块元数据读取失败", kind: .script)
        }
        let hasDetail = ctx.evaluateScript("typeof loadDetail === 'function'")?.toBool() ?? false
        func str(_ d: [String: Any], _ key: String) -> String {
            if let s = d[key] as? String { return s }
            if let n = d[key] as? NSNumber { return n.stringValue }
            return ""
        }
        func params(_ list: [Any]?) -> [FWDParam] {
            (list as? [[String: Any]] ?? []).map { p in
                var desc = str(p, "description")
                if desc.isEmpty { desc = str(p, "placeholder") }
                return FWDParam(name: str(p, "name"), title: str(p, "title"),
                                type: str(p, "type").isEmpty ? "input" : str(p, "type"),
                                value: str(p, "value"),
                                enumOptions: (p["enumOptions"] as? [[String: Any]] ?? []).map {
                                    FWDOption(title: str($0, "title"), value: str($0, "value"))
                                },
                                desc: desc,
                                placeholders: (p["placeholders"] as? [[String: Any]] ?? []).map {
                                    FWDOption(title: str($0, "title"), value: str($0, "value"))
                                })
            }
        }
        var meta = FWDMeta()
        meta.id = str(raw, "id")
        meta.title = str(raw, "title")
        meta.version = str(raw, "version")
        meta.author = str(raw, "author")
        meta.description = str(raw, "description")
        meta.site = str(raw, "site")
        meta.icon = str(raw, "iconurl").isEmpty
            ? (str(raw, "icon").isEmpty ? str(raw, "iconUrl") : str(raw, "icon"))
            : str(raw, "iconurl")
        meta.hasDetail = hasDetail
        // Forward's declared cache TTL (seconds). Accept a
        // number or a numeric string; absent/invalid = 0 and
        // the app default applies (v2.06).
        if let n = raw["cacheDuration"] as? NSNumber {
            meta.cacheDuration = max(0, n.intValue)
        } else if let s = raw["cacheDuration"] as? String,
                  let n = Int(s) {
            meta.cacheDuration = max(0, n)
        }
        meta.globalParams = params(raw["globalParams"] as? [Any])
        meta.modules = (raw["modules"] as? [[String: Any]] ?? []).map { m in
            FWDModuleEntry(id: str(m, "id"), title: str(m, "title"),
                           functionName: str(m, "functionName"),
                           type: str(m, "type"), params: params(m["params"] as? [Any]))
        }
        if let search = raw["search"] as? [String: Any] {
            meta.searchFunction = str(search, "functionName")
            meta.searchParams = params(search["params"] as? [Any])
        }
        return meta
    }

    private func callLocked(function: String, argumentJSON: String, source: String) throws -> Any? {
        let ctx = try makeContext(source: source)
        var settled = false
        var errorText: String?
        var jsonText: String?
        let settle: @convention(block) (String?, String?) -> Void = { err, json in
            errorText = err
            jsonText = json
            settled = true
        }
        ctx.setObject(settle, forKeyedSubscript: "__fwdSettle" as NSString)
        func jsString(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let text = String(data: data, encoding: .utf8) else { return "\"\"" }
            return String(text.dropFirst().dropLast())
        }
        lastException = nil
        ctx.evaluateScript("""
        (function() {
          var fn = globalThis[\(jsString(function))];
          if (typeof fn !== 'function') { __fwdSettle('模块缺少函数 ' + \(jsString(function)), null); return; }
          Promise.resolve().then(function() { return fn(\(argumentJSON)); }).then(
            function(r) {
              try { __fwdSettle(null, JSON.stringify(r === undefined ? null : r)); }
              catch (e) { __fwdSettle('模块结果序列化失败：' + String((e && e.message) || e), null); }
            },
            function(e) { __fwdSettle(String((e && e.message) || e), null); });
        })();
        """)
        // A synchronous throw in the wrapper (bad argument JSON,
        // a poisoned context) reaches the exception handler, not
        // the promise — fail fast with it instead of pumping the
        // full 30 s into a misleading timeout.
        if !settled, let lastException {
            throw FWDfailure(message: lastException, kind: .script)
        }
        // Handlers await Widget.http, which is a synchronous native
        // value here, so every continuation is a promise job. Drain
        // BOTH ways JavaScriptCore schedules those jobs: script
        // evaluations (microtask checkpoint at unwind) and run-loop
        // turns (the VM's job queue is also serviced there), plus
        // the prelude's timer drain for modules using setTimeout.
        // 60 s since v1.77: drive-aggregation modules fan out to
        // many sources with sequential fetches and legitimately
        // need more room than catalogue modules do.
        // v2.01 pump hardening: the prelude's timer drain swallows
        // a throwing timer callback (it only logs it), so without
        // a probe the call would pump the full 60 s and report a
        // misleading timeout. The prelude now records the first
        // timer error in __timerError and the queue depth in
        // __timersPending: fail fast once an error is recorded
        // and no timers are left that could still settle the
        // promise; otherwise keep pumping, and surface the
        // recorded error inside the timeout message. A JS
        // exception landing mid-pump fails fast the same way.
        // (One hard limit stays: a timer callback stuck in an
        // infinite loop never returns from evaluateScript, so no
        // deadline can fire — synchronous JS by design.)
        let deadline = Date().addingTimeInterval(60)
        var pumpTick = 0
        while !settled && Date() < deadline {
            ctx.evaluateScript("0")
            ctx.evaluateScript("if (typeof __drainTimers === 'function') { __drainTimers(); }")
            if !settled, let lastException {
                throw FWDfailure(message: lastException, kind: .script)
            }
            pumpTick += 1
            if !settled, pumpTick % 20 == 0,
               let timerError = FWDRuntime.timerErrorText(ctx), !timerError.isEmpty,
               FWDRuntime.timersPending(ctx) == 0 {
                throw FWDfailure(message: "定时器回调异常：\(timerError)", kind: .script)
            }
            if !RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005)) {
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        if let errorText {
            throw FWDfailure(message: errorText, kind: FWDfailure.classifyModuleError(errorText))
        }
        guard settled, let jsonText, let data = jsonText.data(using: .utf8) else {
            // Self-diagnosing timeout: report what the context
            // actually holds, so a dead runtime names its cause.
            let probe = ctx.evaluateScript("""
            JSON.stringify({
              fn: typeof globalThis[\(jsString(function))],
              widget: typeof globalThis.Widget,
              meta: typeof globalThis.WidgetMetadata
            })
            """)?.toString() ?? "?"
            let extra = lastException.map { "；最近异常：\($0)" } ?? ""
            let timerExtra = FWDRuntime.timerErrorText(ctx)
                .map { "；定时器异常：\($0)" } ?? ""
            throw FWDfailure(message: "模块调用超时（60 秒）[\(probe)]\(extra)\(timerExtra)",
                             kind: .timeout)
        }
        if jsonText == "null" { return nil }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// First timer-callback error recorded by the prelude's
    /// __drainTimers (v2.01), if any. Nil when no timer has
    /// thrown in this context.
    private static func timerErrorText(_ ctx: JSContext) -> String? {
        guard let text = ctx.evaluateScript(
            "typeof globalThis.__timerError === 'string' ? globalThis.__timerError : ''"
        )?.toString(), !text.isEmpty else { return nil }
        return text
    }

    /// Timers still queued in the prelude shim (v2.01). -1 when
    /// the prelude never installed the shim (older bundle /
    /// unexpected context) — callers treat that as unknown.
    private static func timersPending(_ ctx: JSContext) -> Int {
        guard let value = ctx.evaluateScript(
            "typeof globalThis.__timersPending === 'number' ? globalThis.__timersPending : -1"
        ) else { return -1 }
        return Int(value.toInt32())
    }

    // MARK: natives

    private func installNatives(_ ctx: JSContext) {
        let logBlock: @convention(block) (String) -> Void = { message in
            Diagnostics.log("模块", message)
        }
        ctx.setObject(logBlock, forKeyedSubscript: "__fwdLog" as NSString)

        let httpBlock: @convention(block) (String, String, String, String) -> String = { method, url, body, optionsJSON in
            FWDRuntime.httpResponse(method: method, urlString: url, body: body, optionsJSON: optionsJSON)
        }
        ctx.setObject(httpBlock, forKeyedSubscript: "__fwdHttp" as NSString)

        let tmdbBlock: @convention(block) (String, String) -> String = { path, paramsJSON in
            FWDRuntime.tmdbResponse(path: path, paramsJSON: paramsJSON)
        }
        ctx.setObject(tmdbBlock, forKeyedSubscript: "__fwdTmdbGet" as NSString)

        let widgetID = self.widgetID
        let storageGet: @convention(block) (String) -> JSValue? = { key in
            guard let ctx = JSContext.current() else { return nil }
            if let value = FWDRuntime.kvGet(store: "fwd.storage.\(widgetID)", key: key) {
                return JSValue(object: value, in: ctx)
            }
            return JSValue(nullIn: ctx)
        }
        ctx.setObject(storageGet, forKeyedSubscript: "__fwdStorageGet" as NSString)
        let storageSet: @convention(block) (String, String) -> Void = { key, value in
            FWDRuntime.kvSet(store: "fwd.storage.\(widgetID)", key: key, value: value)
        }
        ctx.setObject(storageSet, forKeyedSubscript: "__fwdStorageSet" as NSString)
        let storageRemove: @convention(block) (String) -> Void = { key in
            FWDRuntime.kvSet(store: "fwd.storage.\(widgetID)", key: key, value: nil)
        }
        ctx.setObject(storageRemove, forKeyedSubscript: "__fwdStorageRemove" as NSString)

        let cacheGet: @convention(block) (String, String) -> JSValue? = { ns, key in
            guard let ctx = JSContext.current() else { return nil }
            if let value = FWDRuntime.kvGet(store: "fwd.sharedcache.v1", key: ns + "\u{1}" + key) {
                return JSValue(object: value, in: ctx)
            }
            return JSValue(nullIn: ctx)
        }
        ctx.setObject(cacheGet, forKeyedSubscript: "__fwdCacheGet" as NSString)
        let cacheSet: @convention(block) (String, String, String) -> Void = { ns, key, value in
            FWDRuntime.kvSet(store: "fwd.sharedcache.v1", key: ns + "\u{1}" + key, value: value)
        }
        ctx.setObject(cacheSet, forKeyedSubscript: "__fwdCacheSet" as NSString)
        let cacheRemove: @convention(block) (String, String) -> Void = { ns, key in
            FWDRuntime.kvSet(store: "fwd.sharedcache.v1", key: ns + "\u{1}" + key, value: nil)
        }
        ctx.setObject(cacheRemove, forKeyedSubscript: "__fwdCacheRemove" as NSString)
    }

    private func installShim(_ ctx: JSContext) {
        ctx.evaluateScript("""
        globalThis.console = (function() {
            function fmt(args) {
                var parts = [];
                for (var i = 0; i < args.length; i++) {
                    var a = args[i];
                    try { parts.push(typeof a === 'object' ? JSON.stringify(a) : String(a)); }
                    catch (e) { parts.push('[object]'); }
                }
                return parts.join(' ');
            }
            return {
                log: function() { __fwdLog(fmt(arguments)); },
                error: function() { __fwdLog(fmt(arguments)); },
                warn: function() { __fwdLog(fmt(arguments)); },
                info: function() { __fwdLog(fmt(arguments)); }
            };
        })();
        globalThis.Widget = (function() {
            function httpReq(method, url, body, options) {
                var raw = __fwdHttp(method, String(url), body == null ? '' : String(body),
                                    JSON.stringify(options || {}));
                return JSON.parse(raw);
            }
            var docs = {};
            var docSeq = 0;
            return {
                http: {
                    get: function(url, options) { return httpReq('GET', url, '', options); },
                    post: function(url, body, options) {
                        var b = '';
                        if (body !== undefined && body !== null) {
                            b = (typeof body === 'string') ? body : JSON.stringify(body);
                        }
                        return httpReq('POST', url, b, options);
                    }
                },
                tmdb: {
                    get: function(path, params) {
                        var r = JSON.parse(__fwdTmdbGet(String(path), JSON.stringify(params || {})));
                        // A TMDB-shaped error object (no key, bad
                        // key, no response) is NOT data: the
                        // module would read r.results (undefined)
                        // and die with a cryptic TypeError. Throw
                        // the Chinese status_message instead, so
                        // the column fails with a readable cause
                        // (v2.06). Real TMDB payloads carry no
                        // `success` field, so this never fires on
                        // good data.
                        if (r && r.success === false) {
                            throw new Error(r.status_message || 'TMDB 请求失败');
                        }
                        return r;
                    }
                },
                html: {
                    load: function(html) { return cheerio.load(String(html == null ? '' : html)); }
                },
                dom: {
                    parse: function(html) {
                        var id = ++docSeq;
                        docs[id] = cheerio.load(String(html == null ? '' : html));
                        return id;
                    },
                    select: function(docId, selector) {
                        var $ = docs[docId];
                        if (!$) return [];
                        var out = [];
                        $(selector).each(function(i, el) {
                            var $el = $(el);
                            out.push({ tagName: el.tagName || '', attribs: el.attribs || {},
                                       text: $el.text(), html: $el.html() || '' });
                        });
                        return out;
                    }
                },
                storage: {
                    get: function(k) { var s = __fwdStorageGet(String(k)); return s == null ? null : JSON.parse(s); },
                    set: function(k, v) { __fwdStorageSet(String(k), JSON.stringify(v === undefined ? null : v)); },
                    remove: function(k) { __fwdStorageRemove(String(k)); }
                },
                sharedCache: {
                    get: function(ns, k) { var s = __fwdCacheGet(String(ns), String(k)); return s == null ? null : JSON.parse(s); },
                    set: function(ns, k, v) { __fwdCacheSet(String(ns), String(k), JSON.stringify(v === undefined ? null : v)); },
                    remove: function(ns, k) { __fwdCacheRemove(String(ns), String(k)); }
                }
            };
        })();
        """)
    }

    // MARK: storage + transport helpers

    private static func kvGet(store: String, key: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: store) as? [String: String])?[key]
    }

    private static func kvSet(store: String, key: String, value: String?) {
        var dict = (UserDefaults.standard.dictionary(forKey: store) as? [String: String]) ?? [:]
        if let value { dict[key] = value } else { dict.removeValue(forKey: key) }
        UserDefaults.standard.set(dict, forKey: store)
    }

    /// Widget.tmdb.get: TMDB API through the user's own key
    /// (Settings → TMDB). Returns the raw JSON body, or a
    /// TMDB-shaped error object when no key is configured.
    private static func tmdbResponse(path: String, paramsJSON: String) -> String {
        let key = (UserDefaults.standard.string(forKey: "tmdb.key") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return "{\"success\":false,\"status_code\":7,\"status_message\":\"未配置 TMDB 密钥（设置 → TMDB）\"}"
        }
        var params: [String: Any] = [:]
        if let data = paramsJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            params = parsed
        }
        // Forward's own convention (and what Rex's official TMDB
        // module passes) is Widget.tmdb.get(path, { params: {...} }):
        // unwrap the inner params dict, or every real query value
        // (page, with_genres, sort_by…) is lost and a junk
        // "params=<dict dump>" item goes out instead.
        if let inner = params["params"] as? [String: Any] {
            params = inner
        }
        // Honor the user's configured API base (Settings → TMDB)
        // so module TMDB calls take the same route as the app —
        // official host or the JarProxy forward (v1.75).
        let baseRaw = (UserDefaults.standard.string(forKey: "tmdb.base") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let apiBase = baseRaw.isEmpty ? "https://api.themoviedb.org" : baseRaw
        let fullPath = path.hasPrefix("/3/") ? path
            : ("/3" + (path.hasPrefix("/") ? path : "/" + path))
        guard var comps = URLComponents(string: apiBase + fullPath) else {
            return "{\"success\":false,\"status_message\":\"TMDB 地址无效\"}"
        }
        var query: [URLQueryItem] = [URLQueryItem(name: "api_key", value: key),
                                     URLQueryItem(name: "language", value: "zh-CN")]
        for (k, v) in params where k != "api_key" && k != "language" {
            query.append(URLQueryItem(name: k, value: String(describing: v)))
        }
        comps.queryItems = query
        guard let url = comps.url else {
            return "{\"success\":false,\"status_message\":\"TMDB 路径无效\"}"
        }
        func fetchJSON(_ u: URL) -> String? {
            let r = JSRuntime.syncFetch(urlString: u.absoluteString,
                                        obj: ["method": "GET", "timeout": 12000])
            let c = (r["content"] as? String) ?? ""
            guard let d = c.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: d)) != nil else { return nil }
            return c
        }
        if let content = fetchJSON(url) { return content }
        // The configured route did not answer (themoviedb.org is
        // unreachable on many networks): one retry through the
        // user's own JarProxy forward, so module TMDB columns
        // work with zero setup (v1.76).
        if apiBase != TMDBClient.forwardBase,
           var alt = URLComponents(string: TMDBClient.forwardBase + fullPath) {
            alt.queryItems = query
            if let u = alt.url, let content = fetchJSON(u) { return content }
        }
        return "{\"success\":false,\"status_message\":\"TMDB 无响应\"}"
    }

    /// One synchronous HTTP round trip shaped for Widget.http:
    /// returns a JSON string {data, status, statusCode, headers};
    /// data is the parsed JSON value when the body parses as JSON,
    /// otherwise the raw text. v2.00: status/statusCode are the
    /// REAL HTTP status from the transport (syncFetch), and
    /// headers are the real response headers — previously both
    /// were a hardcoded 200 / whatever the transport happened
    /// to return, so modules could not tell a 404/403/Cloudflare
    /// challenge from a success. status 0 + "error" means the
    /// request never got a response (network failure); data is
    /// still the body when the server answered with one (e.g. a
    /// 404 JSON error), so existing modules keep working.
    /// v2.01: the per-request timeout is capped at 20 s (the
    /// 60 s call budget is untouched) and a timed-out request
    /// additionally reports timedOut=true with a Chinese
    /// "子请求超时（20 秒）" error, distinct from other
    /// transport failures.
    /// v2.07 fetch-compat: the transport options syncFetch
    /// already understands — encoding (gbk…), buffer (2 =
    /// base64 body), redirect (0 = don't follow) and a form
    /// `data` dict — are now forwarded instead of silently
    /// dropped; `url` reports the final URL after redirects;
    /// query/form values are percent-encoded with & = + ? kept
    /// out, so one value can no longer split into several
    /// parameters.
    private static func httpResponse(method: String, urlString: String,
                                     body: String, optionsJSON: String) -> String {
        var options: [String: Any] = [:]
        if let data = optionsJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            options = parsed
        }
        // Query values must not carry & = + ? raw, or one value
        // splits into several parameters (v2.07).
        let valueAllowed = CharacterSet.urlQueryAllowed
            .subtracting(CharacterSet(charactersIn: "&=+?"))
        var url = urlString
        if let params = options["params"] as? [String: Any], !params.isEmpty {
            let query = params.map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? key
                let v = String(describing: value)
                    .addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? ""
                return "\(k)=\(v)"
            }.joined(separator: "&")
            url += (url.contains("?") ? "&" : "?") + query
        }
        var obj: [AnyHashable: Any] = ["method": method]
        // v2.01 sub-request timeout layering: one request may
        // take at most 20 s — the number is unchanged, but it is
        // now enforced as a cap (a module asking for more must
        // not eat the whole 60 s call budget) and its failure is
        // reported separately from other transport failures.
        let requestedMs = (options["timeout"] as? NSNumber)?.doubleValue ?? 20000
        obj["timeout"] = min(max(requestedMs, 1000), 20000)
        if let headers = options["headers"] as? [String: Any] {
            obj["headers"] = headers
        }
        // v2.07: forward the transport options the module asked
        // for — encoding, buffer and redirect used to be dropped
        // here, so gbk pages decoded as mojibake and redirect: 0
        // was silently ignored.
        if let encoding = options["encoding"] as? String { obj["encoding"] = encoding }
        if let buffer = options["buffer"] as? NSNumber { obj["buffer"] = buffer }
        if let redirect = options["redirect"] as? NSNumber { obj["redirect"] = redirect }
        if method == "POST" {
            if !body.isEmpty {
                obj["body"] = body
                let headers = (obj["headers"] as? [String: Any]) ?? [:]
                if headers.keys.first(where: { $0.lowercased() == "content-type" }) == nil {
                    var h = headers
                    h["Content-Type"] = "application/json"
                    obj["headers"] = h
                }
            } else if let data = options["data"] as? [String: Any], !data.isEmpty {
                // Form POST: {data: {k: v}} → url-encoded body.
                // syncFetch sets the form Content-Type when the
                // caller didn't set one (v2.07).
                obj["data"] = data
            } else if let data = options["data"] as? String, !data.isEmpty {
                // v2.19: form data passed as a pre-encoded string
                // ("a=1&b=2") used to be dropped here — only the
                // dict shape was forwarded. Send it through as-is;
                // syncFetch puts a String data straight into the
                // request body.
                obj["data"] = data
            }
        }
        let result = JSRuntime.syncFetch(urlString: url, obj: obj)
        let content = (result["content"] as? String) ?? ""
        let headers = (result["headers"] as? [String: String]) ?? [:]
        let status = (result["status"] as? NSNumber)?.intValue ?? 0
        var dataValue: Any = content
        if let data = content.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            dataValue = parsed
        }
        // v2.19: headers keep the server's casing ("Set-Cookie",
        // "Location"), so a module reading headers["set-cookie"]
        // or headers["location"] lowercase missed them. Ship a
        // lowercase copy of every header alongside the original,
        // so both casings read. The same gap hid multi-value
        // Set-Cookie (allHeaderFields comma-joins them, and the
        // commas inside Expires= dates corrupt the split), so
        // also expose the parsed cookies for the final URL:
        // URLSession already stored them in the shared jar and
        // sends them on later requests — `cookies` just makes
        // them visible to modules that forward cookies by hand.
        var headersOut: [String: String] = headers
        for (key, value) in headers {
            let lower = key.lowercased()
            if headersOut[lower] == nil { headersOut[lower] = value }
        }
        var response: [String: Any] = ["data": dataValue, "status": status,
                                       "statusCode": status, "headers": headersOut]
        if let finalURLString = result["url"] as? String,
           let finalURL = URL(string: finalURLString),
           let cookies = HTTPCookieStorage.shared.cookies(for: finalURL),
           !cookies.isEmpty {
            response["cookies"] = cookies.map { "\($0.name)=\($0.value)" }
        }
        // v2.07: the final URL after redirects, so a module can
        // tell where it actually landed (e.g. a login wall).
        if let finalURL = result["url"] as? String, !finalURL.isEmpty {
            response["url"] = finalURL
        }
        // v2.01: a timed-out sub-request is a distinct outcome —
        // timedOut + a Chinese message naming the 20 s cap — so
        // a module (and the FWDfailure classifier) can tell a
        // slow source from a dead network. Other transport
        // failures keep the Chinese error syncFetch mapped.
        if (result["timedOut"] as? NSNumber)?.boolValue == true {
            response["timedOut"] = true
            response["error"] = "子请求超时（20 秒）：\(URL(string: url)?.host ?? url)"
        } else if let error = result["error"] as? String, !error.isEmpty {
            response["error"] = error
        }
        guard let data = try? JSONSerialization.data(withJSONObject: response),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"data\":\"\",\"status\":\(status),\"statusCode\":\(status),\"headers\":{}}"
        }
        return text
    }
}

// MARK: - Danmu modules (v1.61)

/// Forward danmu modules, per the public ForwardWidgets spec
/// (InchStudio/ForwardWidgets, "弹幕分片加载流程"):
///   searchDanmu(params) → search matches ({animes:[{bangumiId…}]})
///   getCommentsById(params) → the episode's danmu array
///     (params carry commentId / animeId from the search hit,
///     plus tmdbId / type / title / seriesName / episodeName /
///     season / episode / link / videoUrl / segmentTime)
///   getDanmuWithSegmentTime(params) → one time segment's danmu
///     (segmentTime + the tmdbId-keyed cache getCommentsById fills)
/// Accepted danmu shapes (all feed DanmakuStore.load, which also
/// parses bilibili XML / JSON): [{p:"time,mode,size,color,…",
/// m:"text"}] and [[time, mode, color, "", text]].
enum FWDDanmu {
    static func entries(for meta: FWDMeta) -> [FWDModuleEntry] {
        meta.modules.filter {
            $0.type == "danmu"
            || $0.id == "searchDanmu" || $0.id == "getComments"
            || $0.id == "getDanmuWithSegmentTime"
        }
    }

    static func hasDanmu(_ meta: FWDMeta) -> Bool { !entries(for: meta).isEmpty }

    /// Fetch one episode's danmaku from the SAME package's danmu
    /// modules, following the spec flow. Returns raw JSON data
    /// for DanmakuStore.load, or nil when the package has no
    /// danmu modules / nothing matched.
    static func fetch(record: FWDRecord, item: FWDItem, episodeIndex: Int) async -> Data? {
        guard let source = FWDStore.source(for: record) else { return nil }
        let meta = record.meta
        let entries = entries(for: meta)
        guard !entries.isEmpty else { return nil }
        let runtime = FWDRuntime(widgetID: record.id)
        let epNo = item.episode ?? (episodeIndex + 1)
        var params: [String: Any] = [
            "title": item.title,
            "seriesName": item.title,
            "episodeName": item.title,
            "episode": epNo,
            "type": item.mediaType.isEmpty
                ? (item.episodeItems.isEmpty && item.childItems.isEmpty ? "movie" : "tv")
                : item.mediaType,
            "link": item.link,
            "videoUrl": item.videoUrl,
        ]
        if item.type == "tmdb" { params["tmdbId"] = item.id }
        if !item.releaseDate.isEmpty { params["airDate"] = item.releaseDate }
        if !item.durationText.isEmpty { params["runtime"] = item.durationText }
        for p in meta.globalParams where !p.value.isEmpty { params[p.name] = p.value }

        func entry(id: String, fn: String) -> FWDModuleEntry? {
            entries.first { $0.id == id } ?? entries.first { $0.functionName == fn }
        }
        // 1. searchDanmu: match the title to a danmu-side id.
        // Some modules answer with danmu directly — take it.
        var matchedID: String?
        if let search = entry(id: "searchDanmu", fn: "searchDanmu") {
            if let result = try? await runtime.call(function: search.functionName,
                                                    params: params, source: source) {
                if let data = danmuData(from: result) { return data }
                matchedID = matchID(from: result)
            }
        }
        // 2. getCommentsById: the episode's comments.
        if let comments = entry(id: "getComments", fn: "getCommentsById") {
            var p2 = params
            if let matchedID { p2["commentId"] = matchedID; p2["animeId"] = matchedID }
            p2["segmentTime"] = 0
            if let result = try? await runtime.call(function: comments.functionName,
                                                    params: p2, source: source),
               let data = danmuData(from: result) { return data }
        }
        // 3. Segment fetch (optional): reads the tmdbId-keyed
        // cache getCommentsById fills; one probe at 0 is enough
        // to tell whether the cache landed.
        if let segment = entry(id: "getDanmuWithSegmentTime", fn: "getDanmuWithSegmentTime") {
            var p3 = params
            if let matchedID { p3["commentId"] = matchedID; p3["animeId"] = matchedID }
            p3["segmentTime"] = 0
            if let result = try? await runtime.call(function: segment.functionName,
                                                    params: p3, source: source),
               let data = danmuData(from: result) { return data }
        }
        return nil
    }

    /// Serialize a danmu-shaped module result to JSON data, or
    /// nil when it is a search match list / metadata instead.
    private static func danmuData(from result: Any?) -> Data? {
        if let text = result as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return Data(text.utf8)
        }
        if let array = result as? [[String: Any]], let first = array.first,
           isDanmuDict(first) {
            return try? JSONSerialization.data(withJSONObject: array)
        }
        if let array = result as? [[Any]], let first = array.first,
           first.count >= 5, first[0] is NSNumber || first[0] is String {
            return try? JSONSerialization.data(withJSONObject: array)
        }
        if let dict = result as? [String: Any] {
            for key in ["comments", "danmu", "data", "danmuku"] {
                if let nested = dict[key], let data = danmuData(from: nested) { return data }
            }
        }
        return nil
    }

    private static func isDanmuDict(_ obj: [String: Any]) -> Bool {
        if obj["p"] is String, obj["m"] is String { return true }
        let hasTime = obj["time"] != nil || obj["t"] != nil
        let hasText = obj["text"] is String || obj["content"] is String || obj["m"] is String
        return hasTime && hasText
    }

    /// Pull the danmu-side id out of a searchDanmu result:
    /// {animes:[{bangumiId…}]} / {data:[…]} / a bare array.
    private static func matchID(from result: Any?) -> String? {
        func id(of obj: [String: Any]) -> String? {
            for key in ["bangumiId", "animeId", "commentId", "id"] {
                if let s = obj[key] as? String, !s.isEmpty { return s }
                if let n = obj[key] as? NSNumber { return n.stringValue }
            }
            return nil
        }
        if let array = result as? [[String: Any]], let first = array.first {
            return id(of: first)
        }
        if let dict = result as? [String: Any] {
            for key in ["animes", "data", "results", "list", "items"] {
                if let array = dict[key] as? [[String: Any]], let first = array.first {
                    return id(of: first)
                }
            }
            return id(of: dict)
        }
        return nil
    }
}

// MARK: - Official module catalog (v2.02)

/// Built-in directory for the two official Rex modules, so the
/// module page shows something useful before anything is
/// downloaded (ReelFlow keeps the same idea: its RexWidgetCatalog
/// lists official modules with full metadata first, download
/// second). The metadata below is the live WidgetMetadata of the
/// files at the two URLs, verified 2026-11-20 against the
/// official downloads (bangumi 5 columns, rex-tmdb 12 columns).
/// The app downloads the .js from the URL at tap time, so a newer
/// upstream version still imports with its own metadata;
/// importModule replaces a same-id record, so re-downloads never
/// duplicate.
struct FWDCatalogEntry: Identifiable {
    var id: String
    var title: String
    var version: String
    var author: String
    var description: String
    var url: String
    var columnCount: Int
    var icon: String
    /// rex-tmdb calls Widget.tmdb.get, which needs the user's own
    /// TMDB key; without one its tmdb-backed columns fail (known
    /// since v1.74), so the card says so up front.
    var requiresTMDBKey: Bool
}

enum FWDCatalog {
    static let entries: [FWDCatalogEntry] = [
        FWDCatalogEntry(
            id: "rex.tmdb",
            title: "Rex TMDB",
            version: "1.2.4",
            author: "Rex",
            description: "Rex 官方影视数据模块，提供 TMDB 榜单、片单、分类及按语言更新的地区剧集与综艺",
            url: "https://assets.rexnow.tv/scripts/rex-tmdb.js",
            columnCount: 12,
            icon: "https://assets.rexnow.tv/scripts/rex-icon.png",
            requiresTMDBKey: true
        ),
        FWDCatalogEntry(
            id: "rex.bangumi",
            title: "动漫数据",
            version: "1.0.1",
            author: "Rex",
            description: "Rex 动漫数据模块，提供每日放送、近期热门、排行榜、年度新番与分类浏览",
            url: "https://assets.rexnow.tv/scripts/bangumi.js",
            columnCount: 5,
            icon: "https://assets.rexnow.tv/scripts/rex-icon.png",
            requiresTMDBKey: false
        ),
    ]

    /// Entries not yet imported (matched by module id).
    static func pending(importedIDs: Set<String>) -> [FWDCatalogEntry] {
        entries.filter { !importedIDs.contains($0.id) }
    }
}

// MARK: - Modules home

struct ModulesView: View {
    @State private var records: [FWDRecord] = []
    @State private var showFileImporter = false
    @State private var showURLImporter = false
    @State private var importURL = ""
    @State private var note: String?
    @State private var importing = false
    @State private var checking = false
    @State private var checkLines: [String] = []
    @State private var checkVersion = 0
    @State private var downloadingCatalogID: String?

    /// Catalog entries not yet imported (matched by module id).
    private var pendingCatalog: [FWDCatalogEntry] {
        FWDCatalog.pending(importedIDs: Set(records.map(\.id)))
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Button {
                        Haptics.tap()
                        showFileImporter = true
                    } label: {
                        Label("导入文件", systemImage: "doc.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Theme.glass, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        Haptics.tap()
                        importURL = ""
                        showURLImporter = true
                    } label: {
                        Label("导入链接", systemImage: "link.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Theme.glass, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    if importing { ProgressView().tint(Theme.text) }
                }
                HStack(spacing: 10) {
                    Button {
                        Haptics.tap()
                        importing = true
                        Task {
                            defer { importing = false }
                            var count = 0
                            for url in ["https://assets.rexnow.tv/scripts/rex-tmdb.js",
                                        "https://assets.rexnow.tv/scripts/bangumi.js"] {
                                if (try? await FWDStore.importRemote(url)) != nil { count += 1 }
                            }
                            note = count > 0 ? "已导入 Rex 官方模块 \(count) 个"
                                             : "Rex 官方模块导入失败，检查网络后重试"
                            records = FWDStore.records()
                        }
                    } label: {
                        Label("导入 Rex 官方模块", systemImage: "star.square.on.square")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Theme.glass, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        Haptics.tap()
                        Task { await runSelfCheck() }
                    } label: {
                        Label(checking ? "自检中…" : "模块自检", systemImage: "stethoscope")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Theme.glass, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(checking)
                }
                // v2.09: 播出日历入口 —— bangumi 每日放送的周视图
                // （今天 + 周一…周日）；模块没导入时日历页只给
                // 导入指引，不编造数据。
                NavigationLink {
                    BroadcastCalendarView()
                } label: {
                    Label("播出日历", systemImage: "calendar")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Theme.glass, in: Capsule())
                }
                .buttonStyle(.plain)
                // v2.02: official-module directory. Entries not
                // yet imported show as cards with metadata first
                // and a one-tap download; imported ones disappear
                // from the directory (they are in the list below).
                if !pendingCatalog.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("官方模块目录")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                        ForEach(pendingCatalog) { entry in
                            catalogCard(entry)
                        }
                    }
                }
                if !checkLines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(checkLines, id: \.self) { line in
                            Text(line).font(.footnote).foregroundStyle(Theme.textDim)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12))
                }
                if let note {
                    Text(note).font(.footnote).foregroundStyle(Theme.textDim)
                }
                if records.isEmpty {
                    EmptyStateView(icon: "puzzlepiece.extension",
                                   title: "还没有模块",
                                   message: "导入 Forward 规范的 JS 模块文件，或粘贴模块 / .fwd 订阅链接。")
                }
                ForEach(records) { record in
                    NavigationLink {
                        FWDWidgetView(record: record)
                    } label: {
                        HStack(spacing: 12) {
                            if !record.meta.icon.isEmpty {
                                PosterImage(urlString: record.meta.icon, pixelSize: 240)
                                    .frame(width: 38, height: 38)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                            } else {
                                Image(systemName: "puzzlepiece.extension")
                                    .foregroundStyle(Theme.accent)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(record.meta.title.isEmpty ? record.id : record.meta.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.text).lineLimit(1)
                                    // v1.83: badge packages that carry a danmu module —
                                    // their titles play with live danmaku (FWDDanmu.fetch).
                                    if FWDDanmu.hasDanmu(record.meta) {
                                        Text("弹幕")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(Theme.accent)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Theme.glass, in: Capsule())
                                    }
                                }
                                Text(moduleSubtitle(record))
                                    .font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                                // v1.94: last self-check stays on the
                                // card (time + conclusion); the tick
                                // forces a refresh once runSelfCheck
                                // saves new results.
                                Text(checkLine(record, tick: checkVersion))
                                    .font(.caption2).foregroundStyle(Theme.textDim).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(Theme.textDim)
                        }
                        .padding(14)
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            FWDStore.delete(record)
                            records = FWDStore.records()
                        } label: {
                            Label("删除模块", systemImage: "trash")
                        }
                    }
                }
                Text("支持 Forward 规范的 JS 模块（WidgetMetadata）。加密模块（FWENC1）内容已加密、无法导入，请向模块作者索取未加密版本；同包的弹幕模块会在播放时自动匹配弹幕。")
                    .font(.caption2).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 110)
        }
        .background(AmbientBackground(imageURL: nil))
        .navigationTitle("模块")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { records = FWDStore.records() }
        // The import Task's records assignment can be swallowed
        // when the picker sheet tears down (device report: the
        // module only appeared after an app restart). Reload from
        // the live view tree whenever the picker closes — this
        // hook always fires.
        .onChange(of: showFileImporter) { _, presented in
            if !presented { records = FWDStore.records() }
        }
        // v1.75: SwiftUI's fileImporter silently never presented
        // on device for this page (reported: tapping 导入文件 did
        // nothing). Use the app's proven DocumentPicker sheet —
        // the same one config / py / js imports use — with
        // multi-select, importing modules and .fwd files alike.
        .sheet(isPresented: $showFileImporter) {
            DocumentPicker(
                onPick: { urls in
                    importing = true
                    Task {
                        defer { importing = false }
                        var okCount = 0
                        var failures: [String] = []
                        for url in urls {
                            do {
                                let data = try Data(contentsOf: url)
                                guard let text = String(data: data, encoding: .utf8) else {
                                    throw FWDStore.StoreFailure(message: "文件无法读取")
                                }
                                okCount += try await FWDStore.importFileText(
                                    text, origin: url.lastPathComponent)
                            } catch {
                                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                            }
                        }
                        records = FWDStore.records()
                        var parts: [String] = []
                        if okCount > 0 { parts.append("已导入 \(okCount) 个模块") }
                        if !failures.isEmpty { parts.append("失败：" + failures.joined(separator: "；")) }
                        note = parts.joined(separator: " · ")
                        if okCount > 0 { Haptics.success() }
                        else if !failures.isEmpty { Haptics.error() }
                    }
                },
                onCancel: { })
                .ignoresSafeArea()
        }
        .alert("导入链接", isPresented: $showURLImporter) {
            TextField("模块 .js 或 .fwd 订阅链接", text: $importURL)
            Button("导入") {
                let target = importURL
                importing = true
                Task {
                    defer { importing = false }
                    do {
                        let count = try await FWDStore.importRemote(target)
                        note = "已导入 \(count) 个模块"
                        records = FWDStore.records()
                    } catch {
                        note = "导入失败：\(error.localizedDescription)"
                    }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// In-app module self-check (v1.76, v2.18): TMDB key presence,
    /// both TMDB routes, and EVERY imported module's list columns
    /// with real calls — the same checks support would run, in
    /// the user's own network, reported in plain language. Each
    /// column is timed; the per-column outcomes (pass/fail, item
    /// count or error, duration) persist with the result so the
    /// module card keeps them after a restart.
    private func runSelfCheck() async {
        checking = true
        checkLines = []
        defer { checking = false }
        let key = (UserDefaults.standard.string(forKey: "tmdb.key") ?? "")
        checkLines.append(key.isEmpty ? "✗ TMDB 密钥未填（去设置 → TMDB 填入）"
                                      : "✓ TMDB 密钥已填")
        let baseRaw = (UserDefaults.standard.string(forKey: "tmdb.base") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let configured = baseRaw.isEmpty ? "https://api.themoviedb.org" : baseRaw
        checkLines.append(await tmdbPing(configured)
            ? "✓ TMDB 线路（当前设置）可达"
            : "✗ TMDB 线路（当前设置）不通")
        if configured != TMDBClient.forwardBase {
            checkLines.append(await tmdbPing(TMDBClient.forwardBase)
                ? "✓ TMDB 转发线路可达（直连不通时自动走它）"
                : "✗ TMDB 转发线路不通")
        }
        if records.isEmpty {
            checkLines.append("（还没有导入任何模块）")
        }
        for record in records {
            guard let source = FWDStore.source(for: record) else { continue }
            let title = record.meta.title.isEmpty ? record.id : record.meta.title
            // v2.18: check EVERY list column, not just the first
            // one, and time each — a dead 2nd column used to hide
            // behind a healthy 1st. Columns run sequentially on
            // the app's serial JS queue; a full official module
            // takes ~10 s in the Node harness.
            var cols: [FWDStore.ColumnCheck] = []
            var totalItems = 0
            var totalMs = 0
            for module in record.meta.listModules {
                let start = Date()
                do {
                    let result = try await FWDRuntime(widgetID: record.id)
                        .call(function: module.functionName,
                              params: fwdDefaultParams(meta: record.meta, module: module),
                              source: source)
                    let n = Self.fwdResultCount(result)
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    totalItems += n
                    totalMs += ms
                    cols.append(FWDStore.ColumnCheck(title: module.title, ok: n > 0,
                                                     count: n, error: "", ms: ms))
                    checkLines.append(n > 0
                        ? "✓ \(title)「\(module.title)」：\(n) 条 · \(Self.checkDurationText(ms))"
                        : "△ \(title)「\(module.title)」：返回 0 条 · \(Self.checkDurationText(ms))")
                } catch {
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    totalMs += ms
                    cols.append(FWDStore.ColumnCheck(title: module.title, ok: false,
                                                     count: 0,
                                                     error: error.localizedDescription, ms: ms))
                    checkLines.append("✗ \(title)「\(module.title)」：\(error.localizedDescription) · \(Self.checkDurationText(ms))")
                }
            }
            if cols.isEmpty {
                checkLines.append("△ \(title)：没有可自检的栏目")
                continue
            }
            let passed = cols.filter { $0.ok }.count
            // ok = no column threw AND at least one returned
            // items — a module whose only blemish is a 0-item
            // column (e.g. TMDB's Cloudflare-blocked list) still
            // shows its per-column detail on the card line.
            let ok = cols.allSatisfy { $0.error.isEmpty } && totalItems > 0
            let summary = "\(passed)/\(cols.count) 栏 · 共 \(totalItems) 条 · \(Self.checkDurationText(totalMs))"
            // v1.94: leave the conclusion on the card.
            FWDStore.saveCheckResult(
                FWDStore.CheckResult(time: Date(), ok: ok, summary: summary, columns: cols),
                for: record.id)
        }
        checkVersion += 1
    }

    /// Item count of a module column result: a bare array, or a
    /// dict wrapping one under items/list/data/results.
    private static func fwdResultCount(_ result: Any?) -> Int {
        if let array = result as? [Any] { return array.count }
        if let dict = result as? [String: Any] {
            for key in ["items", "list", "data", "results"] {
                if let array = dict[key] as? [Any] { return array.count }
            }
        }
        return 0
    }

    /// "650ms" under a second, "1.2s" above — used by the
    /// self-check lines and the per-module card line.
    private static func checkDurationText(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }

    /// Any JSON back — even a TMDB 401 error body — proves the
    /// route itself answers.
    private func tmdbPing(_ base: String) async -> Bool {
        let key = (UserDefaults.standard.string(forKey: "tmdb.key") ?? "")
        guard let url = URL(string: base + "/3/configuration?api_key=\(key)") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private func checkLine(_ record: FWDRecord, tick: Int) -> String {
        let _ = tick
        guard let result = FWDStore.checkResult(for: record.id) else {
            return "尚未自检"
        }
        let stamp = Self.checkDateFormatter.string(from: result.time)
        return "\(result.ok ? "✓" : "✗") 自检 \(stamp) · \(result.summary)"
    }

    private static let checkDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private func moduleSubtitle(_ record: FWDRecord) -> String {
        var parts: [String] = []
        if !record.meta.author.isEmpty { parts.append(record.meta.author) }
        if !record.meta.version.isEmpty { parts.append("v\(record.meta.version)") }
        parts.append("\(record.meta.listModules.count) 个栏目")
        if let host = URL(string: record.source)?.host { parts.append(host) }
        return parts.joined(separator: " · ")
    }

    /// One directory card (v2.02): metadata first, one tap to
    /// download and enable. importRemote writes the module file
    /// and replaces any same-id record, so a card can never
    /// produce a duplicate.
    private func catalogCard(_ entry: FWDCatalogEntry) -> some View {
        HStack(spacing: 12) {
            if !entry.icon.isEmpty {
                PosterImage(urlString: entry.icon, pixelSize: 240)
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text).lineLimit(1)
                    Text("v\(entry.version)")
                        .font(.caption2).foregroundStyle(Theme.textDim)
                }
                Text("\(entry.author) · \(entry.columnCount) 个栏目")
                    .font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                Text(entry.description)
                    .font(.caption).foregroundStyle(Theme.textDim).lineLimit(2)
                if entry.requiresTMDBKey {
                    Text("需先在设置 → TMDB 填入自己的密钥")
                        .font(.caption2).foregroundStyle(Theme.textDim).lineLimit(1)
                }
            }
            Spacer()
            Button {
                Haptics.tap()
                downloadingCatalogID = entry.id
                Task {
                    defer { downloadingCatalogID = nil }
                    do {
                        _ = try await FWDStore.importRemote(entry.url)
                        records = FWDStore.records()
                        note = "已导入 \(entry.title)"
                        Haptics.success()
                    } catch {
                        note = "\(entry.title) 下载失败：\(error.localizedDescription)"
                        Haptics.error()
                    }
                }
            } label: {
                if downloadingCatalogID == entry.id {
                    ProgressView().tint(Theme.text)
                } else {
                    Text("下载")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.glass, in: Capsule())
                }
            }
            .buttonStyle(.plain)
            .disabled(downloadingCatalogID != nil)
        }
        .padding(14)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Default params for a module's first run (self-check): the
/// same fallback rules as FWDWidgetView.buildParams with no
/// user selections — enumerations take their first option,
/// inputs take their first placeholder suggestion.
func fwdDefaultParams(meta: FWDMeta, module: FWDModuleEntry) -> [String: Any] {
    var params: [String: Any] = [:]
    for p in meta.globalParams where !p.value.isEmpty { params[p.name] = p.value }
    for p in module.params {
        if p.type == "page" || p.name == "page" {
            params[p.name] = 1
        } else if p.type == "count" || p.type == "offset" {
            params[p.name] = Int(p.value) ?? p.value
        } else if p.type == "enumeration" {
            params[p.name] = p.value.isEmpty ? (p.enumOptions.first?.value ?? "") : p.value
        } else if p.type == "input" {
            params[p.name] = p.value.isEmpty ? (p.placeholders.first?.value ?? "") : p.value
        } else if !p.value.isEmpty {
            params[p.name] = p.value
        }
    }
    return params
}

// MARK: - Widget browse

struct FWDWidgetView: View {
    let record: FWDRecord
    @State private var items: [FWDItem] = []
    @State private var loading = true
    @State private var loadingMore = false
    @State private var errorText: String?
    @State private var moduleIndex = 0
    @State private var page = 1
    @State private var selections: [String: String] = [:]
    @State private var searchText = ""
    @State private var detailItem: FWDItem?
    @State private var showSearch = false
    @State private var searchSeed = ""
    /// v2.19: the keyword of the last search, so the error
    /// banner's retry re-runs the SEARCH instead of reloading
    /// the column (the old retry called load(reset:) and the
    /// search failure just came back as an empty column).
    @State private var lastSearchKeyword: String?

    private var meta: FWDMeta { record.meta }
    private var listModules: [FWDModuleEntry] { meta.listModules }
    private var currentModule: FWDModuleEntry? {
        listModules.indices.contains(moduleIndex) ? listModules[moduleIndex] : nil
    }
    private var hasPageParam: Bool {
        currentModule?.params.contains { $0.type == "page" || $0.name == "page" } ?? false
    }

    var body: some View {
        Group {
            if loading {
                ScrollView(showsIndicators: false) {
                    SkeletonPosterGrid()
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 110)
                }
            } else if let errorText, items.isEmpty {
                EmptyStateView(icon: "wifi.exclamationmark",
                               title: "模块没拉到数据",
                               message: errorText,
                               actionTitle: "重新加载",
                               action: { Task { await retryCurrent() } })
                    .padding(.horizontal, 18)
            } else {
                content
            }
        }
        .background(AmbientBackground(imageURL: nil))
        .navigationTitle(meta.title.isEmpty ? record.id : meta.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $detailItem) { item in
            FWDDetailView(record: record, item: item)
        }
        .sheet(isPresented: $showSearch) {
            SearchView(config: ConfigLibrary.activeID().flatMap { ConfigLibrary.load(id: $0) },
                       initialKeyword: searchSeed)
        }
        .task { await load(reset: true) }
    }

    private var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                if meta.searchFunction != nil {
                    HStack {
                        TextField("搜索…", text: $searchText)
                            .font(.subheadline)
                            .padding(10)
                            .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10))
                        Button("搜索") { Task { await runSearch() } }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                if listModules.count > 1 {
                    chipRow(listModules.map(\.title),
                            selected: moduleIndex) { idx in
                        moduleIndex = idx
                        page = 1
                        Task { await load(reset: true) }
                    }
                }
                if (UserDefaults.standard.string(forKey: "tmdb.key") ?? "").isEmpty,
                   record.meta.id.lowercased().contains("tmdb") {
                    Text("提示：TMDB 密钥还没填，这个模块的栏目不出数据。去「设置 → TMDB」填入 v3 密钥即可；线路不通时会自动走 JarProxy 转发，不用梯子。")
                        .font(.caption).foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let module = currentModule {
                    ForEach(module.params.filter { $0.type == "enumeration" && !$0.enumOptions.isEmpty },
                            id: \.name) { param in
                        chipRow(param.enumOptions.map(\.title),
                                selected: param.enumOptions.firstIndex {
                                    $0.value == (selections[param.name] ?? param.value)
                                } ?? 0) { idx in
                            selections[param.name] = param.enumOptions[idx].value
                            page = 1
                            Task { await load(reset: true) }
                        }
                    }
                    ForEach(module.params.filter { $0.type == "input" },
                            id: \.name) { param in
                        inputRow(param)
                    }
                }
                // v2.06: a failed load-more / search no longer
                // dies silently once items exist — the cause
                // stays visible with a retry that refetches.
                if let errorText, !items.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Theme.accent)
                        Text(errorText)
                            .font(.caption).foregroundStyle(Theme.textDim)
                            .lineLimit(2)
                        Spacer()
                        Button("重新加载") {
                            Haptics.tap()
                            Task { await retryCurrent() }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(10)
                    .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10))
                }
                if items.isEmpty {
                    EmptyStateView(icon: "square.stack.3d.up.slash",
                                   title: "这个栏目暂时没有内容",
                                   message: "换个栏目或关键词试试",
                                   actionTitle: "重新加载",
                                   action: { Task { await load(reset: true, bypassCache: true) } },
                                   compact: true)
                } else {
                    posterGrid(items)
                }
                if hasPageParam && !items.isEmpty {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        HStack(spacing: 8) {
                            if loadingMore { ProgressView().tint(Theme.text) }
                            Text("加载更多")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(loadingMore)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 110)
        }
    }

    /// One input-param row (v1.75): a text field whose return key
    /// (or the 加载 button) reloads with the typed value, plus the
    /// metadata's placeholder suggestions as tappable chips.
    @ViewBuilder
    private func inputRow(_ param: FWDParam) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField(param.desc.isEmpty
                            ? (param.title.isEmpty ? param.name : param.title)
                            : param.desc,
                          text: Binding(
                            get: { selections[param.name] ?? param.value },
                            set: { selections[param.name] = $0 }))
                    .font(.subheadline)
                    .padding(10)
                    .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit {
                        page = 1
                        Task { await load(reset: true) }
                    }
                Button("加载") {
                    Haptics.tap()
                    page = 1
                    Task { await load(reset: true) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            }
            if !param.placeholders.isEmpty {
                chipRow(param.placeholders.map(\.title),
                        selected: param.placeholders.firstIndex {
                            $0.value == (selections[param.name]
                                ?? param.placeholders.first?.value ?? "")
                        } ?? 0) { idx in
                    selections[param.name] = param.placeholders[idx].value
                    page = 1
                    Task { await load(reset: true) }
                }
            }
        }
    }

    private func chipRow(_ titles: [String], selected: Int,
                         onPick: @escaping (Int) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(titles.indices, id: \.self) { idx in
                    Text(titles[idx])
                        .font(.subheadline.weight(idx == selected ? .semibold : .regular))
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .background(idx == selected ? Color.white : Theme.glass, in: Capsule())
                        .foregroundStyle(idx == selected ? .black : Theme.text.opacity(0.85))
                        .onTapGesture { onPick(idx) }
                }
            }
        }
    }

    private func posterGrid(_ list: [FWDItem]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                  spacing: 16) {
            ForEach(list) { item in
                Button {
                    open(item)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        PosterImage(urlString: item.posterURL)
                            .aspectRatio(2/3, contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.glass))
                        Text(item.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        if !item.releaseDate.isEmpty || !item.rating.isEmpty {
                            Text([String(item.releaseDate.prefix(4)),
                                  item.rating.isEmpty ? "" : "★\(item.rating)"]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(Theme.textDim)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Tap routing: items carrying a link / videoUrl / episode
    /// list open the module detail page (which resolves playback);
    /// bare catalogue items (the TMDB-type lists most modules
    /// return) go to cross-line search by title, exactly like a
    /// Discover poster tap.
    private func open(_ item: FWDItem) {
        Haptics.tap()
        if !item.link.isEmpty || !item.videoUrl.isEmpty || !item.episodeItems.isEmpty {
            detailItem = item
        } else {
            searchSeed = item.title
            showSearch = true
        }
    }

    private func buildParams(for module: FWDModuleEntry, page: Int) -> [String: Any] {
        var params: [String: Any] = [:]
        for p in meta.globalParams where !p.value.isEmpty {
            params[p.name] = p.value
        }
        for p in module.params {
            if p.type == "page" || p.name == "page" {
                params[p.name] = page
            } else if p.type == "count" || p.type == "offset" {
                params[p.name] = Int(selections[p.name] ?? p.value) ?? p.value
            } else if p.type == "enumeration" {
                // No explicit default in the metadata (Rex's
                // official modules ship enumerations without a
                // value): Forward hosts fall back to the FIRST
                // option — sending "" produced paths like
                // "trending/all/" and dead columns.
                let fallback = p.value.isEmpty
                    ? (p.enumOptions.first?.value ?? "") : p.value
                params[p.name] = selections[p.name] ?? fallback
            } else if p.type == "input" {
                // Input params must always reach the handler —
                // rex-tmdb's 片单 does params.url.includes(...) and
                // dies on undefined. Fall back to the first
                // placeholder suggestion when nothing was typed,
                // so the column opens with content (v1.75).
                params[p.name] = selections[p.name] ?? (p.value.isEmpty
                    ? (p.placeholders.first?.value ?? "") : p.value)
            } else if !p.value.isEmpty {
                params[p.name] = selections[p.name] ?? p.value
            }
        }
        return params
    }

    /// Page-1 list loads consult FWDColumnCache first (v2.06):
    /// re-entering a column replays the last result while the
    /// TTL holds (module `cacheDuration` or 30 min), so the
    /// column opens instantly and skips the JS + network round
    /// trip. Manual retries bypass the cache; searches and
    /// pages > 1 never read or write it. Returns false on
    /// failure so loadMore can roll the page back.
    @discardableResult
    private func load(reset: Bool, bypassCache: Bool = false) async -> Bool {
        guard let module = currentModule,
              let source = FWDStore.source(for: record) else {
            loading = false
            return false
        }
        if reset { loading = true; errorText = nil; lastSearchKeyword = nil }
        let params = buildParams(for: module, page: page)
        let ttl = meta.cacheDuration > 0
            ? TimeInterval(meta.cacheDuration) : FWDColumnCache.defaultTTL
        let cacheKey = FWDColumnCache.key(moduleID: record.id,
                                          columnID: module.id, params: params)
        if reset, page == 1, !bypassCache,
           let cached = FWDColumnCache.get(key: cacheKey, ttl: ttl) {
            items = cached.map(FWDItem.init)
            loading = false
            return true
        }
        do {
            let result = try await FWDRuntime(widgetID: record.id)
                .call(function: module.functionName,
                      params: params,
                      source: source)
            let rows = (result as? [[String: Any]] ?? [])
            items = reset ? rows.map(FWDItem.init) : items + rows.map(FWDItem.init)
            if reset, page == 1, !rows.isEmpty {
                FWDColumnCache.set(key: cacheKey, rows: rows)
            }
            errorText = nil
        } catch {
            if reset { errorText = "加载失败：\(error.localizedDescription)" }
            else { errorText = "加载更多失败：\(error.localizedDescription)" }
            loading = false
            return false
        }
        loading = false
        return true
    }

    private func loadMore() async {
        loadingMore = true
        page += 1
        if await load(reset: false) == false {
            page = max(1, page - 1)
        }
        loadingMore = false
    }

    /// Retry whatever the page was last doing: a failed search
    /// re-runs the search with the same keyword, anything else
    /// reloads the column bypassing the cache (v2.19).
    private func retryCurrent() async {
        if let keyword = lastSearchKeyword {
            await runSearch(keyword: keyword)
        } else {
            await load(reset: true, bypassCache: true)
        }
    }

    private func runSearch(keyword: String? = nil) async {
        guard let fn = meta.searchFunction,
              let source = FWDStore.source(for: record) else { return }
        let keyword = (keyword ?? searchText).trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }
        lastSearchKeyword = keyword
        loading = true
        errorText = nil
        var params: [String: Any] = ["keyword": keyword, "query": keyword,
                                     "searchKeyword": keyword, "page": 1]
        for p in meta.globalParams where !p.value.isEmpty { params[p.name] = p.value }
        for p in meta.searchParams where !p.value.isEmpty { params[p.name] = p.value }
        do {
            let result = try await FWDRuntime(widgetID: record.id)
                .call(function: fn, params: params, source: source)
            items = (result as? [[String: Any]] ?? []).map(FWDItem.init)
            errorText = nil
        } catch {
            errorText = "搜索失败：\(error.localizedDescription)"
        }
        loading = false
    }
}

// MARK: - Widget detail + playback

struct FWDDetailView: View {
    let record: FWDRecord
    let item: FWDItem
    @State private var full: FWDItem
    @State private var loadingDetail = false
    /// v2.19: enrich() used to swallow a loadDetail failure into
    /// the diagnostics log only — the page showed the thin list
    /// item with no episodes and no hint why. Surface it.
    @State private var detailError: String?
    @State private var playSelection: FWDPlaySelection?
    @State private var resolvingNote: String?

    private struct FWDPlaySelection: Identifiable {
        var episodes: [PlayerView.EpisodeRef]
        var index: Int
        var initial: (url: String, header: [String: String])?
        var resolver: PlayerView.Resolver?
        /// v1.61: module danmaku for this title (same package's
        /// danmu entries), fed to the player's danmaku layer per
        /// episode; forced on when the package has danmu modules.
        var danmakuLoader: ((Int) async -> Data?)?
        var danmakuForced: Bool = false
        var id: String { episodes[index].url + "#\(index)" }
    }

    init(record: FWDRecord, item: FWDItem) {
        self.record = record
        self.item = item
        _full = State(initialValue: item)
    }

    private var meta: FWDMeta { record.meta }
    private var episodes: [FWDItem] {
        if !full.episodeItems.isEmpty { return full.episodeItems }
        if !full.childItems.isEmpty { return full.childItems }
        return []
    }

    /// Media-info rows (v2.12): same spec as DetailView's card —
    /// only fields the module actually sent; empty ones dropped.
    private var fwdMediaInfoRows: [(label: String, value: String)] {
        [
            ("来源模块", meta.title),
            ("类型", full.mediaType.isEmpty ? full.type : full.mediaType),
            ("年份", String(full.releaseDate.prefix(4))),
            ("评分", full.rating),
            ("时长", full.durationText),
            ("分类", full.genreTitle),
        ].filter { !$0.value.isEmpty }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                PosterImage(urlString: full.backdropURL, pixelSize: 900)
                    .aspectRatio(16/9, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Text(full.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.text)
                if !metaLine.isEmpty {
                    Text(metaLine).font(.caption).foregroundStyle(Theme.textDim)
                }
                if let score = Double(full.rating), score > 0 {
                    HStack(spacing: 8) {
                        StarBarView(value: score)
                        Text(full.rating)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                        // v2.20: plain "评分" — the number comes
                        // from the module's own rating field, and
                        // only rex-tmdb's happens to be TMDB
                        // vote_average; labelling every module's
                        // number "TMDB 评分" asserted a source the
                        // module never promised.
                        Text("评分")
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                    }
                }
                if !full.overview.isEmpty {
                    Text(full.overview)
                        .font(.subheadline)
                        .foregroundStyle(Theme.text.opacity(0.8))
                        .lineSpacing(4)
                }
                MediaInfoCard(rows: fwdMediaInfoRows)
                CastRowView(people: full.peoples)
                if loadingDetail {
                    HStack(spacing: 8) {
                        ProgressView().tint(Theme.text)
                        Text("正在加载详情…").font(.caption).foregroundStyle(Theme.textDim)
                    }
                }
                if let detailError, !loadingDetail {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Theme.accent)
                        Text(detailError)
                            .font(.caption).foregroundStyle(Theme.textDim)
                            .lineLimit(2)
                        Spacer()
                        Button("重试") {
                            Haptics.tap()
                            Task { await enrich() }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(10)
                    .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10))
                }
                if let resolvingNote {
                    Text(resolvingNote).font(.footnote).foregroundStyle(.orange)
                }
                if episodes.isEmpty {
                    if !full.videoUrl.isEmpty || meta.resourceFunction != nil || !full.link.isEmpty {
                        Button {
                            Task { await playSingle() }
                        } label: {
                            Label("播放", systemImage: "play.fill")
                                .font(.headline)
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("选集").font(.headline).foregroundStyle(Theme.text)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                        GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(Array(episodes.enumerated()), id: \.element.id) { pair in
                            Button {
                                Task { await playEpisode(at: pair.offset) }
                            } label: {
                                Text(guageEpisodeDisplayName(pair.element.title,
                                                             index: pair.element.episode.map { $0 - 1 } ?? pair.offset))
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                                    .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !full.relatedItems.isEmpty {
                    Text("相关推荐").font(.headline).foregroundStyle(Theme.text)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(full.relatedItems) { rel in
                                NavigationLink {
                                    FWDDetailView(record: record, item: rel)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        PosterImage(urlString: rel.posterURL)
                                            .aspectRatio(2/3, contentMode: .fill)
                                            .frame(width: 92, height: 138)
                                            .clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.glass))
                                        Text(rel.title)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(Theme.text)
                                            .lineLimit(1)
                                            .frame(width: 92, alignment: .leading)
                                        if !rel.shortMetaLine.isEmpty {
                                            Text(rel.shortMetaLine)
                                                .font(.caption2)
                                                .foregroundStyle(Theme.textDim)
                                                .lineLimit(1)
                                                .frame(width: 92, alignment: .leading)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 110)
        }
        .background(AmbientBackground(imageURL: full.backdropURL.isEmpty ? nil : full.backdropURL))
        .navigationTitle(full.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playSelection) { sel in
            PlayerView(episodes: sel.episodes, startIndex: sel.index,
                       header: [:], title: full.title,
                       initialResolved: sel.initial,
                       resolver: sel.resolver,
                       danmakuLoader: sel.danmakuLoader,
                       danmakuForced: sel.danmakuForced)
        }
        .task { await enrich() }
    }

    private var metaLine: String {
        [String(full.releaseDate.prefix(4)), full.genreTitle,
         full.rating.isEmpty ? "" : "★\(full.rating)", full.durationText]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Items with a link ask the widget's loadDetail for the full
    /// record (episodes, playback URL, related titles).
    private func enrich() async {
        guard !item.link.isEmpty, meta.hasDetail,
              let source = FWDStore.source(for: record) else { return }
        loadingDetail = true
        defer { loadingDetail = false }
        do {
            let result = try await FWDRuntime(widgetID: record.id)
                .callString(function: "loadDetail", argument: item.link, source: source)
            if let dict = result as? [String: Any] {
                full = FWDItem(dict)
                detailError = nil
            } else if let list = result as? [[String: Any]], let first = list.first {
                full = FWDItem(first)
                detailError = nil
            } else {
                detailError = "详情没有返回内容，集数与播放地址为空"
            }
        } catch {
            detailError = "详情加载失败：\(error.localizedDescription)"
            Diagnostics.log("模块", "loadDetail 失败：\(error.localizedDescription)")
        }
    }

    private func resolve(_ ep: FWDItem) async -> PlayerView.ResolveResult {
        if !ep.videoUrl.isEmpty {
            return .ok(url: ep.videoUrl, header: [:])
        }
        guard let source = FWDStore.source(for: record) else {
            return .failed("模块文件丢失")
        }
        let runtime = FWDRuntime(widgetID: record.id)
        if let fn = meta.resourceFunction {
            var params: [String: Any] = ["id": ep.id, "link": ep.link,
                                         "videoUrl": ep.videoUrl, "type": ep.type,
                                         "mediaType": ep.mediaType, "title": ep.title]
            if let n = ep.episode { params["episode"] = n }
            if let result = try? await runtime.call(function: fn, params: params, source: source),
               let resources = result as? [[String: Any]],
               let first = resources.first,
               let url = first["url"] as? String, !url.isEmpty {
                var header: [String: String] = [:]
                for key in ["customHeaders", "headers"] {
                    if let dict = first[key] as? [String: Any] {
                        for (k, v) in dict { header[k] = String(describing: v) }
                    }
                }
                header.removeValue(forKey: "X-Forward-Skip-Redirect-Probe")
                return .ok(url: url, header: header)
            }
        }
        if !ep.link.isEmpty, meta.hasDetail {
            if let result = try? await runtime.callString(function: "loadDetail",
                                                          argument: ep.link, source: source),
               let dict = result as? [String: Any] {
                let detail = FWDItem(dict)
                if !detail.videoUrl.isEmpty {
                    return .ok(url: detail.videoUrl, header: [:])
                }
            }
        }
        return .failed("该条目没有可播放地址")
    }

    private func playSingle() async {
        resolvingNote = nil
        let outcome = await resolve(full)
        switch outcome {
        case .ok(let url, let header):
            playSelection = FWDPlaySelection(
                episodes: [PlayerView.EpisodeRef(name: full.title, url: url)],
                index: 0, initial: (url, header), resolver: nil,
                danmakuLoader: { _ in
                    await FWDDanmu.fetch(record: record, item: full, episodeIndex: 0)
                },
                danmakuForced: FWDDanmu.hasDanmu(meta))
        case .failed(let reason):
            resolvingNote = reason
        }
    }

    private func playEpisode(at idx: Int) async {
        resolvingNote = nil
        let list = episodes
        guard list.indices.contains(idx) else { return }
        let refs = list.enumerated().map { i, ep in
            PlayerView.EpisodeRef(
                name: guageEpisodeDisplayName(ep.title, index: ep.episode.map { $0 - 1 } ?? i),
                url: !ep.link.isEmpty ? ep.link : (ep.videoUrl.isEmpty ? "ep#\(i)" : ep.videoUrl))
        }
        let first = await resolve(list[idx])
        switch first {
        case .ok(let url, let header):
            playSelection = FWDPlaySelection(
                episodes: refs, index: idx, initial: (url, header),
                resolver: { _, i in
                    guard list.indices.contains(i) else { return .failed("集数越界") }
                    return await resolve(list[i])
                },
                danmakuLoader: { i in
                    guard list.indices.contains(i) else { return nil }
                    return await FWDDanmu.fetch(record: record, item: list[i], episodeIndex: i)
                },
                danmakuForced: FWDDanmu.hasDanmu(meta))
        case .failed(let reason):
            resolvingNote = reason
        }
    }
}
