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

        struct Style: Decodable {
            var type: String?    // "rect" / "list" / "oval"
            var ratio: Double?
        }

        enum Kind { case cmsXML, cmsJSON, spiderPY, spiderJS, spiderJAR, drpyJS, unknown }

        /// Which runtime this site needs. iOS has no JVM, so .jar spiders are
        /// the one mainstream kind this shell can never execute (Apple forbids
        /// it platform-wide); they are listed but marked unsupported in the UI.
        var kind: Kind {
            let a = api.lowercased()
            switch type {
            case 0: return .cmsXML
            case 1: return .cmsJSON
            case 4: return .drpyJS
            case 3:
                if a.hasSuffix(".py") || a.contains("py/") { return .spiderPY }
                if a.hasSuffix(".js") || a.contains("js/") || a.hasPrefix("csp_js") { return .spiderJS }
                if a.hasSuffix(".jar") || a.hasPrefix("csp_") { return .spiderJAR }
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
