import Foundation

/// Optional TMDB enrichment (设置 → TMDB 增强）: the user's own API
/// key and base address, results cached on device. It gives the
/// home hero what the feeds themselves lack — a real backdrop, a
/// synopsis, and a TMDB score next to the feed's own score.
enum TMDBClient {
    struct Info: Codable {
        var backdrop: String = ""
        var overview: String = ""
        var score: String = ""
    }

    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: "tmdb.enabled")
            && !(UserDefaults.standard.string(forKey: "tmdb.key") ?? "").isEmpty
    }

    private static var base: String {
        let raw = (UserDefaults.standard.string(forKey: "tmdb.base") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return raw.isEmpty ? "https://api.themoviedb.org" : raw
    }

    private static var apiKey: String {
        (UserDefaults.standard.string(forKey: "tmdb.key") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let cacheKey = "tmdb.cache.v1"

    private static func cached(name: String, year: String) -> Info? {
        guard let map = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String],
              let raw = map[name + "|" + year],
              let data = raw.data(using: .utf8),
              let info = try? JSONDecoder().decode(Info.self, from: data) else { return nil }
        return info
    }

    static func lookup(name: String, year: String) async -> Info? {
        if let hit = cached(name: name, year: year) { return hit }
        guard isOn else { return nil }
        var comps = URLComponents(string: base + "/3/search/multi")
        comps?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: "zh-CN"),
            URLQueryItem(name: "query", value: name),
        ]
        guard let url = comps?.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return nil }
        let candidates = results.filter {
            ["movie", "tv"].contains($0["media_type"] as? String ?? "")
        }
        guard !candidates.isEmpty else { return nil }
        func dateOf(_ r: [String: Any]) -> String {
            (r["release_date"] as? String) ?? (r["first_air_date"] as? String) ?? ""
        }
        let picked = (!year.isEmpty ? candidates.first { dateOf($0).hasPrefix(year) } : nil)
            ?? candidates[0]
        let backdropPath = picked["backdrop_path"] as? String ?? ""
        let vote = picked["vote_average"] as? Double ?? 0
        let info = Info(
            backdrop: backdropPath.isEmpty ? "" : "https://image.tmdb.org/t/p/w780" + backdropPath,
            overview: picked["overview"] as? String ?? "",
            score: vote > 0 ? String(format: "%.1f", vote) : "")
        // Cache even a partial hit so a title is only searched once.
        var map = (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String]) ?? [:]
        if let encoded = try? JSONEncoder().encode(info),
           let raw = String(data: encoded, encoding: .utf8) {
            map[name + "|" + year] = raw
            UserDefaults.standard.set(map, forKey: cacheKey)
        }
        return info
    }

    /// Settings-page probe: the configuration endpoint answers 200
    /// only with a valid key.
    static func testConnection() async -> String {
        guard !apiKey.isEmpty else { return "先填 API 密钥" }
        var comps = URLComponents(string: base + "/3/configuration")
        comps?.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        guard let url = comps?.url else { return "API 地址不对" }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return code == 200 ? "连接成功，密钥可用" : "连接失败（HTTP \(code)）"
        } catch {
            return "连不上：\(error.localizedDescription)"
        }
    }
}
