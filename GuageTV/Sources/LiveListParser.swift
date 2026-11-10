import Foundation

/// Parser for 直播 (live) source lists referenced by a config's `lives`.
/// Handles the two shapes in the wild:
///  - M3U:   #EXTINF:-1 group-title="央视",CCTV-1 \n http://…
///  - TXT:   group lines "央视,#genre#" then "CCTV-1,http://…"
/// Output is grouped channels ready for the Live tab.
enum LiveListParser {

    struct Channel: Identifiable {
        var name: String
        var url: String
        var group: String
        var logo: String = ""
        var id: String { name + "|" + url }
    }

    static func parse(_ text: String) -> [String: [Channel]] {
        text.contains("#EXTINF") ? parseM3U(text) : parseTXT(text)
    }

    private static func parseM3U(_ text: String) -> [String: [Channel]] {
        var groups: [String: [Channel]] = [:]
        var pending: (name: String, group: String, logo: String)?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF") {
                let name = line.components(separatedBy: ",").last?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                let group = capture("group-title=\"([^\"]+)\"", in: line) ?? "未分组"
                let logo = capture("tvg-logo=\"([^\"]+)\"", in: line) ?? ""
                pending = (name, group, logo)
            } else if line.hasPrefix("http"), let p = pending {
                groups[p.group, default: []].append(
                    Channel(name: p.name, url: line, group: p.group, logo: p.logo))
                pending = nil
            }
        }
        return groups
    }

    private static func parseTXT(_ text: String) -> [String: [Channel]] {
        var groups: [String: [Channel]] = [:]
        var currentGroup = "未分组"
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasSuffix(",#genre#") {
                currentGroup = line.replacingOccurrences(of: ",#genre#", with: "")
                continue
            }
            let parts = line.components(separatedBy: ",")
            guard parts.count >= 2 else { continue }
            let url = parts[1...].joined(separator: ",")
            guard url.hasPrefix("http") else { continue }
            groups[currentGroup, default: []].append(
                Channel(name: parts[0], url: url, group: currentGroup))
        }
        return groups
    }

    private static func capture(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
