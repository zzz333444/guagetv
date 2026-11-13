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

    static func exportText() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm:ss"
        var out = "呱壳诊断日志（共 \(entries().count) 条）\n"
        for e in entries() {
            out += "[\(fmt.string(from: Date(timeIntervalSince1970: e.t)))] [\(e.c)] \(e.m)\n"
        }
        return out
    }
}
