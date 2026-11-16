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
