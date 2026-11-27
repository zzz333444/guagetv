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
        var tvgId: String = ""
        /// v2.43: M3U 频道级回看属性（#EXTINF 行的 catchup /
        /// catchup-source / catchup-days）。有值时优先于线路级
        /// catchup；全空时回落到线路级。
        /// v2.62: catchupDays 未声明时取 #EXTM3U 头部的列表级
        /// 默认值（仍无则 nil = 不限期）；catchupType 存小写
        /// 归一值，shift 无源时由 LiveView 合成 utc/lutc 模板。
        var catchupSource: String = ""
        var catchupType: String = ""
        var catchupDays: Int? = nil
        var id: String { name + "|" + url }
    }

    /// Groups in first-seen order (a dictionary would scramble the
    /// list's own grouping, which reads as channel categories).
    static func parse(_ text: String) -> [(name: String, channels: [Channel])] {
        text.contains("#EXTINF") ? parseM3U(text) : parseTXT(text)
    }

    private static func ordered(_ groups: [String: [Channel]],
                                _ order: [String]) -> [(name: String, channels: [Channel])] {
        order.compactMap { name in groups[name].map { (name: name, channels: $0) } }
    }

    private static func parseM3U(_ text: String) -> [(name: String, channels: [Channel])] {
        var groups: [String: [Channel]] = [:]
        var order: [String] = []
        // v2.62: 播放列表级回看默认值（#EXTM3U 头部属性，与
        // 频道级同名属性是同一约定：频道级优先、列表级兜底）。
        // 本轮只接 catchup-days；catchup / catchup-source 的
        // 列表级默认值未接（见更新日志 v2.62）。
        var playlistCatchupDays: Int? = nil
        var pending: (name: String, group: String, logo: String, tvgId: String,
                      catchupSource: String, catchupType: String, catchupDays: Int?)?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTM3U") {
                playlistCatchupDays = capture("catchup-days=\"?(\\d+)\"?", in: line)
                    .flatMap(Int.init)
            } else if line.hasPrefix("#EXTINF") {
                let name = line.components(separatedBy: ",").last?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                let group = capture("group-title=\"([^\"]+)\"", in: line) ?? "未分组"
                let logo = capture("tvg-logo=\"([^\"]+)\"", in: line) ?? ""
                let tvgId = capture("tvg-id=\"([^\"]+)\"", in: line) ?? ""
                // v2.43: 频道级回看属性。catchup-source 模板里
                // 常带 ${...} 占位符、引号内外都可能出现，带引
                // 号的先取双引号再取单引号，最后兜底无引号形态。
                let catchupSource = capture("catchup-source=\"([^\"]+)\"", in: line)
                    ?? capture("catchup-source='([^']+)'", in: line)
                    ?? capture("catchup-source=([^\\s,]+)", in: line) ?? ""
                // v2.62: catchup-type 是 catchup 的同义别名
                // （UniPlayer/Kodi 口径）；值归一成小写再存，
                // 调用方直接按 "shift"/"append"/"default" 比对。
                let catchupType = (capture("catchup=\"([^\"]+)\"", in: line)
                    ?? capture("catchup='([^']+)'", in: line)
                    ?? capture("catchup-type=\"([^\"]+)\"", in: line)
                    ?? capture("catchup-type='([^']+)'", in: line) ?? "")
                    .trimmingCharacters(in: .whitespaces).lowercased()
                let catchupDays = capture("catchup-days=\"?(\\d+)\"?", in: line)
                    .flatMap(Int.init)
                pending = (name, group, logo, tvgId, catchupSource, catchupType, catchupDays)
            } else if line.hasPrefix("http"), let p = pending {
                if groups[p.group] == nil { order.append(p.group) }
                groups[p.group, default: []].append(
                    Channel(name: p.name, url: line, group: p.group, logo: p.logo, tvgId: p.tvgId,
                            catchupSource: p.catchupSource, catchupType: p.catchupType,
                            // v2.62: 天数优先级：频道级 > 列表级
                            // #EXTM3U 默认值 > 不声明（nil = 不限期）。
                            catchupDays: p.catchupDays ?? playlistCatchupDays))
                pending = nil
            }
        }
        return ordered(groups, order)
    }

    private static func parseTXT(_ text: String) -> [(name: String, channels: [Channel])] {
        var groups: [String: [Channel]] = [:]
        var order: [String] = []
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
            if groups[currentGroup] == nil { order.append(currentGroup) }
            groups[currentGroup, default: []].append(
                Channel(name: parts[0], url: url, group: currentGroup))
        }
        return ordered(groups, order)
    }

    private static func capture(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
