import Foundation

/// Parsed subset of a TVBox interface config (the JSON a user pastes/imports).
struct TVBoxConfig: Decodable {
    var spider: String?
    var sites: [Site]
    var lives: [Live]?
    var parses: [Parse]?

    struct Site: Decodable, Identifiable {
        var key: String
        var name: String
        var type: Int            // 0=XML, 1=JSON, 3=Spider(py/js), 4=drpy
        var api: String          // for type 3 this is the .py/.js file name or URL
        var searchable: Int?
        var quickSearch: Int?
        var filterable: Int?
        var ext: JSONValue?      // string or object depending on the source
        var jar: String?
        var id: String { key }
    }

    struct Live: Decodable {
        var name: String
        var url: String
        var type: Int?
    }

    struct Parse: Decodable {
        var name: String
        var url: String
        var type: Int?
    }
}

/// Loose JSON value for fields whose shape varies between sources.
enum JSONValue: Decodable {
    case string(String)
    case object([String: JSONValue])
    case array([JSONValue])
    case other

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        self = .other
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

enum ConfigLoader {
    /// TVBox configs in the wild often contain // comments and trailing commas.
    static func cleaned(_ raw: Data) -> Data {
        guard var s = String(data: raw, encoding: .utf8) else { return raw }
        s = s.replacingOccurrences(of: #"(?m)^\s*//.*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #",(\s*[}\]])"#, with: "$1", options: .regularExpression)
        return Data(s.utf8)
    }

    static func load(from data: Data) throws -> TVBoxConfig {
        try JSONDecoder().decode(TVBoxConfig.self, from: cleaned(data))
    }

    static func load(url: URL) async throws -> TVBoxConfig {
        let (data, _) = try await URLSession.shared.data(from: url)
        return try load(from: data)
    }
}
