import CryptoKit
import Foundation

/// TVBox interface config — full field coverage for the mainstream format.
/// Unknown/variable fields are tolerated on purpose: real-world configs are
/// messy (comments, trailing commas, mixed ext types) and must never fail
/// to load just because one site uses an extra key.
struct TVBoxConfig: Decodable {
    var spider: String?
    var wallpaper: String?
    var logo: String?
    var home: String?            // WebHome page URL, if the config ships one
    var sites: [Site]
    var lives: [Live]?
    var parses: [Parse]?
    var flags: [String]?
    var ads: [String]?           // ad-host blocklist rules from the config
    var doh: [Doh]?

    struct Site: Decodable, Identifiable {
        var key: String
        var name: String
        var type: Int            // 0=XML CMS, 1=JSON CMS, 3=Spider(py/js/jar), 4=drpy(JS)
        var api: String
        var searchable: Int?
        var quickSearch: Int?
        var filterable: Int?
        var changeable: Int?
        var playerType: Int?     // -1 default, 0 system, 1 ijk, 2 exo, 10 mx, 11 reex
        var ext: JSONValue?      // string or object, source-defined
        var jar: String?
        var categories: [String]?
        var click: String?
        var playUrl: String?
        var style: Style?
        var timeout: Int?
        var header: [String: String]?
        var id: String { key }

        /// The site's ext field in the string form Spider.init expects.
        var extJSONString: String { ext?.serializedString ?? "" }

        struct Style: Decodable {
            var type: String?    // "rect" / "list" / "oval"
            var ratio: Double?
        }

        enum Kind { case cmsXML, cmsJSON, spiderPY, spiderJS, spiderJAR, drpyJS, unknown }

        /// Which runtime this site needs. Jar spiders run through
        /// the user's JarProxy (see JarSiteBrowseView).
        var kind: Kind {
            // Real-world configs decorate script URLs — subscription
            // endpoints append "?token=…" and TVBox appends
            // ";md5;…" trailers — so a bare hasSuffix(".js") misses
            // them and whole configs land in "unknown". Strip both
            // decorations first, then judge the extension anywhere
            // in the path, not only at the very end.
            var a = api.lowercased()
            if let cut = a.firstIndex(of: ";") { a = String(a[..<cut]) }
            if let cut = a.firstIndex(of: "?") { a = String(a[..<cut]) }
            switch type {
            case 0: return .cmsXML
            case 1: return .cmsJSON
            case 4: return .drpyJS
            case 3:
                if a.hasSuffix(".py") { return .spiderPY }
                if a.hasSuffix(".js") || a.hasPrefix("csp_js") { return .spiderJS }
                if a.hasSuffix(".jar") || a.hasPrefix("csp_") { return .spiderJAR }
                if a.contains(".py") { return .spiderPY }
                if a.contains(".js") { return .spiderJS }
                return .unknown
            default: return .unknown
            }
        }
    }

    struct Live: Decodable {
        var name: String
        var url: String
        var type: Int?           // 0=m3u/txt list, 1=JSON, 2=EPG-aware
        var epg: String?
        var logo: String?
        var ua: String?
        var groups: String?
        var channels: [Channel]?

        struct Channel: Decodable {
            var name: String
            var urls: [String]
        }
    }

    struct Parse: Decodable {
        var name: String
        var url: String
        var type: Int?           // 0=web sniff, 1=JSON API, 2=aggregate
        var ext: JSONValue?
    }

    struct Doh: Decodable {
        var name: String
        var url: String
        var ips: [String]?
    }
}

/// Loose JSON value for fields whose shape varies between sources.
extension JSONValue {
    /// The ext payload as spiders expect it: the string itself for
    /// string exts, JSON text for object/array exts.
    var serializedString: String {
        switch self {
        case .string(let value): return value
        case .number(let value):
            return value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        case .other: return ""
        case .object, .array:
            guard let data = try? JSONSerialization.data(withJSONObject: plainObject)
            else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    var plainObject: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .other: return NSNull()
        case .array(let values): return values.map(\.plainObject)
        case .object(let dict): return dict.mapValues(\.plainObject)
        }
    }
}

enum JSONValue: Decodable {
    case string(String)
    case object([String: JSONValue])
    case array([JSONValue])
    case number(Double)
    case bool(Bool)
    case other

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        self = .other
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

enum ConfigLoader {
    /// Real configs often contain // comments and trailing commas.
    static func cleaned(_ raw: Data) -> Data {
        guard var s = String(data: raw, encoding: .utf8) else { return raw }
        s = s.replacingOccurrences(of: #"(?m)^\s*//.*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #",(\s*[}\]])"#, with: "$1", options: .regularExpression)
        return Data(s.utf8)
    }

    static func load(from data: Data) throws -> TVBoxConfig {
        if let cfg = try? JSONDecoder().decode(TVBoxConfig.self, from: cleaned(data)) {
            return cfg
        }
        return try lenientLoad(from: data)
    }

    /// Tolerant second pass for real-world configs: strict Codable fails
    /// the WHOLE file when a single site uses a string where an Int is
    /// declared, a non-string header value, etc. Here each site/section is
    /// coerced or dropped individually so one rotten entry can't kill the
    /// other 150.
    private static func lenientLoad(from data: Data) throws -> TVBoxConfig {
        let cleanedData = cleaned(data)
        guard let obj = try JSONSerialization.jsonObject(with: cleanedData) as? [String: Any] else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "top level is not a JSON object"))
        }
        var out = obj

        if let rawSites = obj["sites"] as? [[String: Any]] {
            out["sites"] = rawSites.compactMap { raw -> [String: Any]? in
                guard let key = raw["key"] as? String,
                      let name = raw["name"] as? String else { return nil }
                var s = raw
                if let t = s["type"] as? String { s["type"] = Int(t) ?? 3 }
                if s["type"] == nil { s["type"] = 3 }
                if s["api"] == nil { s["api"] = "" }
                for f in ["searchable", "quickSearch", "filterable", "changeable", "playerType", "timeout"] {
                    if let v = s[f] as? String {
                        if let n = Int(v) { s[f] = n } else { s[f] = nil }
                    }
                }
                if let h = s["header"] as? [String: Any],
                   h.values.contains(where: { !($0 is String) }) {
                    s["header"] = h.compactMapValues { $0 as? String }
                }
                if var style = s["style"] as? [String: Any],
                   let r = style["ratio"] as? String {
                    if let d = Double(r) { style["ratio"] = d } else { style["ratio"] = nil }
                    s["style"] = style
                }
                return s
            }
        }
        for section in ["flags", "ads"] {
            if let arr = obj[section] as? [Any] {
                out[section] = arr.compactMap { $0 as? String }
            }
        }
        for section in ["lives", "parses", "doh"] {
            if let arr = obj[section] as? [Any] {
                out[section] = arr.filter { element in
                    guard let d = try? JSONSerialization.data(withJSONObject: element) else { return false }
                    switch section {
                    case "lives": return (try? JSONDecoder().decode(TVBoxConfig.Live.self, from: d)) != nil
                    case "parses": return (try? JSONDecoder().decode(TVBoxConfig.Parse.self, from: d)) != nil
                    default: return (try? JSONDecoder().decode(TVBoxConfig.Doh.self, from: d)) != nil
                    }
                }
            }
        }
        let rebuilt = try JSONSerialization.data(withJSONObject: out)
        return try JSONDecoder().decode(TVBoxConfig.self, from: rebuilt)
    }

    static func load(url: URL) async throws -> TVBoxConfig {
        let data = try await NetFetch.data(from: url)
        return try load(from: data)
    }
}

/// Persists the active config so it survives the app being swiped away
/// (v7): the raw bytes live in Application Support, the source URL in
/// UserDefaults; ContentView restores on launch.
enum ConfigStore {
    private static let urlKey = "configSourceURL"

    private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("active-config.json")
    }

    static func save(data: Data, sourceURL: String) {
        guard let file = fileURL else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        UserDefaults.standard.set(sourceURL, forKey: urlKey)
    }

    static func savedSourceURL() -> String? {
        UserDefaults.standard.string(forKey: urlKey)
    }

    static func loadConfig() -> TVBoxConfig? {
        ConfigLibrary.loadActive()
    }
}

// MARK: - Multi-config library

/// Every imported TVBox/猫源 config is kept as its own line （线路）:
/// raw bytes per config under Application Support/configs/, an index
/// in UserDefaults, one active line at a time. Discover/Search/Library
/// all read the active line; switching lines is instant (no download).
enum ConfigLibrary {
    struct Entry: Codable, Identifiable {
        var id: String          // sha256 of the source URL
        var name: String
        var sourceURL: String
        var siteCount: Int
        var addedAt: TimeInterval
    }

    private static let indexKey = "configLibraryIndex.v1"
    private static let activeKey = "activeConfigID.v1"
    private static let legacyURLKey = "configSourceURL"

    private static var dir: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("configs")
    }

    private static func file(for id: String) -> URL? {
        dir?.appendingPathComponent(id + ".json")
    }

    static func entries() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: indexKey),
              let list = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return list
    }

    private static func saveEntries(_ list: [Entry]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: indexKey)
        }
    }

    static func activeID() -> String? {
        UserDefaults.standard.string(forKey: activeKey)
    }

    static func displayName(for sourceURL: String) -> String {
        if let url = URL(string: sourceURL) {
            let last = url.lastPathComponent
            if !last.isEmpty, last != "/" { return last }
            if let host = url.host, !host.isEmpty { return host }
        }
        return "配置"
    }

    /// Add (or refresh, when the URL repeats) a config; it becomes
    /// the active line.
    @discardableResult
    static func add(data: Data, sourceURL: String, siteCount: Int) -> Entry {
        let id = SHA256.hash(data: Data(sourceURL.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let entry = Entry(id: id, name: displayName(for: sourceURL),
                          sourceURL: sourceURL, siteCount: siteCount,
                          addedAt: Date().timeIntervalSince1970)
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if let file = file(for: id) {
            try? data.write(to: file, options: .atomic)
        }
        var list = entries()
        if let i = list.firstIndex(where: { $0.id == id }) {
            list[i] = entry
        } else {
            list.append(entry)
        }
        saveEntries(list)
        setActive(id: id)
        return entry
    }

    static func setActive(id: String) {
        UserDefaults.standard.set(id, forKey: activeKey)
        if let entry = entries().first(where: { $0.id == id }) {
            // PySiteBrowseView resolves relative spider paths against
            // this key; it must always name the ACTIVE line's source.
            UserDefaults.standard.set(entry.sourceURL, forKey: legacyURLKey)
        }
    }

    static func activate(id: String) -> TVBoxConfig? {
        setActive(id: id)
        return loadEntry(id: id)
    }

    /// Remove a line; returns the config that should be on screen now
    /// (the new active line, or nil when the library is empty).
    static func remove(id: String) -> TVBoxConfig? {
        if let file = file(for: id) { try? FileManager.default.removeItem(at: file) }
        let list = entries().filter { $0.id != id }
        saveEntries(list)
        setAlias(nil, for: id)
        if activeID() == id {
            UserDefaults.standard.removeObject(forKey: activeKey)
            if let first = list.first { return activate(id: first.id) }
            UserDefaults.standard.removeObject(forKey: legacyURLKey)
            return nil
        }
        return loadActive()
    }

    /// Parse any line's stored config without activating it (the
    /// Discover home-line and history may point at non-active lines).
    static func load(id: String) -> TVBoxConfig? { loadEntry(id: id) }

    // MARK: line aliases （备注名）

    private static let aliasKey = "configLineAliases.v1"

    static func alias(for id: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: aliasKey) as? [String: String])?[id]
    }

    static func setAlias(_ alias: String?, for id: String) {
        var map = (UserDefaults.standard.dictionary(forKey: aliasKey) as? [String: String]) ?? [:]
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { map.removeValue(forKey: id) } else { map[id] = trimmed }
        UserDefaults.standard.set(map, forKey: aliasKey)
    }

    /// What the UI shows for a line: the user's remark name when
    /// one is set, else the imported name.
    static func shownName(_ entry: Entry) -> String {
        alias(for: entry.id) ?? entry.name
    }

    // MARK: groups （资源库分组）

    /// User-named groups for the Library. Membership lives in a
    /// separate entryID → groupID map so the line index format never
    /// changes. Single-file py imports form an automatic group.
    struct Group: Codable, Identifiable {
        var id: String
        var name: String
    }

    static let pyAutoGroupID = "auto.pyfiles"
    static let noGroupID = "none"
    private static let groupsKey = "configGroups.v1"
    private static let assignKey = "configEntryGroups.v1"

    static func groups() -> [Group] {
        guard let data = UserDefaults.standard.data(forKey: groupsKey),
              let list = try? JSONDecoder().decode([Group].self, from: data)
        else { return [] }
        return list
    }

    private static func saveGroups(_ list: [Group]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: groupsKey)
        }
    }

    @discardableResult
    static func addGroup(name: String) -> Group {
        let group = Group(id: UUID().uuidString, name: name)
        saveGroups(groups() + [group])
        return group
    }

    static func renameGroup(id: String, name: String) {
        var list = groups()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].name = name
        saveGroups(list)
    }

    static func removeGroup(id: String) {
        saveGroups(groups().filter { $0.id != id })
        var map = groupAssignments()
        for key in map.keys where map[key] == id { map[key] = nil }
        saveAssignments(map)
    }

    static func groupAssignments() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: assignKey) as? [String: String] ?? [:]
    }

    private static func saveAssignments(_ map: [String: String]) {
        UserDefaults.standard.set(map, forKey: assignKey)
    }

    /// groupID: a custom group id, pyAutoGroupID, or noGroupID.
    static func setGroup(entryID: String, groupID: String) {
        var map = groupAssignments()
        map[entryID] = groupID
        saveAssignments(map)
    }

    static func isPyFileEntry(_ entry: Entry) -> Bool {
        entry.sourceURL.hasPrefix("py-import://")
    }

    /// Where a line is displayed: its manual assignment wins; an
    /// unassigned py-file line falls into the automatic py group;
    /// anything else unassigned returns nil （未分组）.
    static func effectiveGroupID(for entry: Entry) -> String? {
        if let assigned = groupAssignments()[entry.id] {
            return assigned == noGroupID ? nil : assigned
        }
        return isPyFileEntry(entry) ? pyAutoGroupID : nil
    }

    static func sourceURL(id: String) -> String? {
        entries().first { $0.id == id }?.sourceURL
    }

    // MARK: home line (which line feeds the Discover page)

    private static let homeLineKey = "homeConfigID.v1"

    static func homeLineID() -> String {
        if let id = UserDefaults.standard.string(forKey: homeLineKey),
           entries().contains(where: { $0.id == id }) { return id }
        return activeID() ?? entries().first?.id ?? ""
    }

    static func setHomeLineID(_ id: String) {
        UserDefaults.standard.set(id, forKey: homeLineKey)
    }

    static func loadActive() -> TVBoxConfig? {
        migrateLegacyIfNeeded()
        if let id = activeID(), let cfg = loadEntry(id: id) { return cfg }
        if let first = entries().first { return activate(id: first.id) }
        return nil
    }

    private static func loadEntry(id: String) -> TVBoxConfig? {
        guard let file = file(for: id), let data = try? Data(contentsOf: file) else { return nil }
        if MaoYuanAdapter.looksLikeMaoYuan(data) {
            return try? MaoYuanAdapter.convert(from: data)
        }
        return try? ConfigLoader.load(from: data)
    }

    // MARK: auto-refresh （订阅配置自动更新）

    private static let refreshStampKey = "configRefreshStamps.v1"

    /// Subscription lines (http/https sourceURL) re-fetch themselves
    /// at most once per 12h when the app comes to the front: fetched
    /// bytes replace the stored copy only when they parse AND
    /// differ, so a dead or hijacked endpoint can never clobber a
    /// working line. Aliases, groups and the active choice are
    /// untouched. Settings → TVBox 配置 →「配置自动更新」gates it.
    static func refreshStaleEntries() {
        guard UserDefaults.standard.object(forKey: "configAutoRefresh") as? Bool ?? true else { return }
        let now = Date().timeIntervalSince1970
        var stamps = (UserDefaults.standard.dictionary(forKey: refreshStampKey)
            as? [String: TimeInterval]) ?? [:]
        var stamped = false
        for entry in entries() {
            guard entry.sourceURL.hasPrefix("http://") || entry.sourceURL.hasPrefix("https://"),
                  let url = URL(string: entry.sourceURL) else { continue }
            if now - (stamps[entry.id] ?? 0) < 12 * 3600 { continue }
            stamps[entry.id] = now
            stamped = true
            let id = entry.id
            Task.detached(priority: .background) {
                guard let data = try? await NetFetch.dataForConfig(from: url) else { return }
                storeRefreshed(data: data, id: id)
            }
        }
        if stamped { UserDefaults.standard.set(stamps, forKey: refreshStampKey) }
    }

    private static func storeRefreshed(data: Data, id: String) {
        guard let file = file(for: id) else { return }
        let old = try? Data(contentsOf: file)
        if old == data { return }
        let parsed: TVBoxConfig?
        if MaoYuanAdapter.looksLikeMaoYuan(data) {
            parsed = try? MaoYuanAdapter.convert(from: data)
        } else {
            parsed = try? ConfigLoader.load(from: data)
        }
        guard let parsed else { return }
        try? data.write(to: file, options: .atomic)
        var list = entries()
        if let i = list.firstIndex(where: { $0.id == id }) {
            list[i].siteCount = parsed.sites.count
            saveEntries(list)
        }
    }

    /// v7's single active-config.json becomes the library's first line,
    /// so an upgrade never loses the config the user already imported.
    private static func migrateLegacyIfNeeded() {
        guard entries().isEmpty else { return }
        let legacy = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("active-config.json")
        guard let legacy, let data = try? Data(contentsOf: legacy) else { return }
        let parsed: TVBoxConfig?
        if MaoYuanAdapter.looksLikeMaoYuan(data) {
            parsed = try? MaoYuanAdapter.convert(from: data)
        } else {
            parsed = try? ConfigLoader.load(from: data)
        }
        let url = UserDefaults.standard.string(forKey: legacyURLKey) ?? "本地导入"
        add(data: data, sourceURL: url, siteCount: parsed?.sites.count ?? 0)
    }
}
