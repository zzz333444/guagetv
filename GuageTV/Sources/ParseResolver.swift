import Foundation

/// TVBox 解析接口 (the config's "parses"): when a play result comes
/// back parse=1, the episode's page URL goes to a parse endpoint and
/// the endpoint answers with the real stream URL. This implements the
/// JSON-API flavours (type 0/1, treated alike); aggregate (type 2)
/// and web-sniff interfaces are skipped — there is no sniffer in the
/// shell. A parse whose ext.flag list is non-empty only serves those
/// flags; the first candidate yielding a plausible media URL wins.
enum ParseResolver {

    static func resolve(flag: String, url: String,
                        parses: [TVBoxConfig.Parse]) async -> (url: String, header: [String: String])? {
        let candidates = parses.filter { parse in
            let type = parse.type ?? 1
            guard type == 0 || type == 1 else { return false }
            let flags = flagList(of: parse)
            return flags.isEmpty || flags.contains(flag)
        }
        for parse in candidates {
            if let hit = await attempt(parse, target: url) { return hit }
        }
        return nil
    }

    private static func attempt(_ parse: TVBoxConfig.Parse,
                                target: String) async -> (url: String, header: [String: String])? {
        guard let endpoint = URL(string: parse.url + target) else { return nil }
        guard let data = try? await NetFetch.data(from: endpoint, extraHeader: requestHeader(of: parse))
        else { return nil }
        return extract(from: data)
    }

    // MARK: ext payload ({"flag": [...], "header": {...}})

    private static func flagList(of parse: TVBoxConfig.Parse) -> [String] {
        guard case .object(let dict)? = parse.ext,
              case .array(let values)? = dict["flag"] else { return [] }
        return values.compactMap { value in
            if case .string(let text) = value { return text }
            return nil
        }
    }

    private static func requestHeader(of parse: TVBoxConfig.Parse) -> [String: String] {
        guard case .object(let dict)? = parse.ext,
              case .object(let header)? = dict["header"] else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in header {
            if case .string(let text) = value { out[key] = text }
        }
        return out
    }

    // MARK: response reading

    /// Pull the stream URL (and any playback header) out of a parse
    /// response: JSON with a "url" field (possibly nested under
    /// "data"), or plain text / HTML containing a media URL.
    static func extract(from data: Data) -> (url: String, header: [String: String])? {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let hit = findURL(in: object) {
            return hit
        }
        let text = String(decoding: data, as: UTF8.self)
        if let match = firstMediaURL(in: text) { return (match, [:]) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http"), !trimmed.contains(" ") { return (trimmed, [:]) }
        return nil
    }

    private static func findURL(in object: Any) -> (url: String, header: [String: String])? {
        if let dict = object as? [String: Any] {
            var header: [String: String] = [:]
            if let raw = dict["header"] as? [String: Any] {
                for (key, value) in raw { header[key] = String(describing: value) }
            }
            if let url = dict["url"] as? String, !url.isEmpty {
                // Prefer the url field outright when it looks like
                // media; otherwise keep digging for a media one.
                if isMediaURL(url) { return (url, header) }
                if let nested = findMediaURL(in: dict) { return (nested, header) }
                return (url, header)
            }
            if let urlObject = dict["url"] {
                if let hit = findURL(in: urlObject) { return (hit.url, header.merging(hit.header) { $1 }) }
            }
            if let data = dict["data"] {
                if let hit = findURL(in: data) { return (hit.url, header.merging(hit.header) { $1 }) }
            }
            if let media = findMediaURL(in: dict) { return (media, header) }
            return nil
        }
        if let array = object as? [Any] {
            for element in array {
                if let hit = findURL(in: element) { return hit }
            }
        }
        return nil
    }

    private static func findMediaURL(in object: Any) -> String? {
        if let text = object as? String {
            return isMediaURL(text) ? text : firstMediaURL(in: text)
        }
        if let dict = object as? [String: Any] {
            for value in dict.values {
                if let found = findMediaURL(in: value) { return found }
            }
        }
        if let array = object as? [Any] {
            for element in array {
                if let found = findMediaURL(in: element) { return found }
            }
        }
        return nil
    }

    private static func firstMediaURL(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"https?://[^\s"'<>\\]+?\.(?:m3u8|mp4|flv|mpd|m4v)(?:\?[^\s"'<>\\]*)?"#,
            options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    static func isMediaURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains(".m3u8") || lower.contains(".mp4")
            || lower.contains(".flv") || lower.contains(".mpd")
            || lower.contains(".m4v")
    }
}
