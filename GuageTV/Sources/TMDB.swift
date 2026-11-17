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
        /// TMDB identity of the matched title (v1.41), powering
        /// the cast row and similar titles on the detail page.
        /// Old cached entries lack these keys, fail to decode,
        /// and simply refetch once — self-healing.
        var tmdbID: Int = 0
        var mediaType: String = ""
    }

    struct CastMember: Identifiable {
        var id: Int
        var name: String
        var character: String
        var profile: String   // w185 URL, "" when none
    }

    static func credits(for info: Info) async -> [CastMember] {
        guard isOn, info.tmdbID > 0, !info.mediaType.isEmpty else { return [] }
        var comps = URLComponents(string: base + "/3/\(info.mediaType)/\(info.tmdbID)/credits")
        comps?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: "zh-CN"),
        ]
        guard let url = comps?.url,
              let root = await getJSON(url),
              let cast = root["cast"] as? [[String: Any]] else { return [] }
        return cast.prefix(15).compactMap { person in
            guard let pid = (person["id"] as? NSNumber)?.intValue,
                  let name = person["name"] as? String, !name.isEmpty else { return nil }
            let path = person["profile_path"] as? String ?? ""
            return CastMember(
                id: pid, name: name,
                character: (person["character"] as? String) ?? "",
                profile: imageURL(path, size: "w185"))
        }
    }

    static func similar(for info: Info) async -> [TMDBTitle] {
        guard info.tmdbID > 0, !info.mediaType.isEmpty else { return [] }
        return await fetchTitles("/3/\(info.mediaType)/\(info.tmdbID)/similar",
                                 forcedType: info.mediaType)
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

    /// Image host matching the configured API base (v1.75):
    /// an official base keeps image.tmdb.org; a custom base
    /// ending in /tmdb (the user's JarProxy forward) maps to its
    /// sibling /tmdbimg forward, so posters work on the same
    /// no-ladder route as the data.
    static var imageBase: String {
        let b = base
        if b.hasSuffix("/tmdb") {
            return String(b.dropLast(5)) + "/tmdbimg/t/p"
        }
        return "https://image.tmdb.org/t/p"
    }

    static func imageURL(_ path: String, size: String) -> String {
        path.isEmpty ? "" : "\(imageBase)/\(size)" + path
    }

    /// The user's own JarProxy TMDB forward — the no-ladder
    /// route behind the settings preset, also used as an
    /// automatic fallback when the configured route does not
    /// answer (v1.76).
    static let forwardBase = "https://jarproxy.onrender.com/tmdb"

    /// GET a JSON object through the configured base; when that
    /// route does not answer and is not already the forward,
    /// retry once through the forward.
    static func getJSON(_ url: URL) async -> [String: Any]? {
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return root
        }
        let text = url.absoluteString
        if !text.hasPrefix(forwardBase), text.hasPrefix(base),
           let altURL = URL(string: forwardBase + text.dropFirst(base.count)),
           let (data, _) = try? await URLSession.shared.data(from: altURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return root
        }
        return nil
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
              let root = await getJSON(url),
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
            backdrop: imageURL(backdropPath, size: "w780"),
            overview: picked["overview"] as? String ?? "",
            score: vote > 0 ? String(format: "%.1f", vote) : "",
            tmdbID: (picked["id"] as? NSNumber)?.intValue ?? 0,
            mediaType: (picked["media_type"] as? String) ?? "")
        // Cache even a partial hit so a title is only searched once.
        var map = (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String]) ?? [:]
        if let encoded = try? JSONEncoder().encode(info),
           let raw = String(data: encoded, encoding: .utf8) {
            map[name + "|" + year] = raw
            UserDefaults.standard.set(map, forKey: cacheKey)
        }
        return info
    }

    // MARK: Discover catalogue lists

    /// One TMDB catalogue title, for the Discover page's hero and
    /// poster rows. Tapping one never plays from TMDB (it has no
    /// streams) — it hands the title to the cross-line search.
    struct TMDBTitle: Identifiable {
        var id: Int
        var mediaType: String   // "movie" | "tv"
        var title: String
        var poster: String      // w500 URL, "" when TMDB has none
        var backdrop: String    // w780 URL, "" when TMDB has none
        var score: String
        var year: String
        var overview: String
        var genres: [String] = []
    }

    /// TMDB genre id → zh-CN name (the API's own wording), covering
    /// the movie and TV tables. Static because the ids are stable
    /// and a /genre/list round-trip per row would be pure latency.
    private static let genreNames: [Int: String] = [
        28: "动作", 12: "冒险", 16: "动画", 35: "喜剧", 80: "犯罪",
        99: "纪录片", 18: "剧情", 10751: "家庭", 14: "奇幻", 36: "历史",
        27: "恐怖", 10402: "音乐", 9648: "悬疑", 10749: "爱情",
        878: "科幻", 10770: "电视电影", 53: "惊悚", 10752: "战争",
        37: "西部", 10759: "动作冒险", 10762: "儿童", 10763: "新闻",
        10764: "真人秀", 10765: "科幻与奇幻", 10766: "肥皂剧",
        10767: "脱口秀", 10768: "战争与政治",
    ]

    private static func fetchTitles(_ path: String, forcedType: String?) async -> [TMDBTitle] {
        guard isOn else { return [] }
        var comps = URLComponents(string: base + path)
        comps?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: "zh-CN"),
        ]
        guard let url = comps?.url,
              let root = await getJSON(url),
              let results = root["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            let type = forcedType ?? (r["media_type"] as? String ?? "")
            guard type == "movie" || type == "tv" else { return nil }
            let title = (r["title"] as? String) ?? (r["name"] as? String) ?? ""
            guard !title.isEmpty, let tmdbID = (r["id"] as? NSNumber)?.intValue else { return nil }
            let date = (r["release_date"] as? String) ?? (r["first_air_date"] as? String) ?? ""
            let posterPath = r["poster_path"] as? String ?? ""
            let backdropPath = r["backdrop_path"] as? String ?? ""
            let vote = (r["vote_average"] as? NSNumber)?.doubleValue ?? 0
            let genreIDs = (r["genre_ids"] as? [Any] ?? [])
                .compactMap { ($0 as? NSNumber)?.intValue }
            return TMDBTitle(
                id: tmdbID, mediaType: type, title: title,
                poster: imageURL(posterPath, size: "w500"),
                backdrop: imageURL(backdropPath, size: "w780"),
                score: vote > 0 ? String(format: "%.1f", vote) : "",
                year: String(date.prefix(4)),
                overview: r["overview"] as? String ?? "",
                genres: genreIDs.prefix(3).compactMap { genreNames[$0] })
        }
    }

    static func trending() async -> [TMDBTitle] {
        await fetchTitles("/3/trending/all/day", forcedType: nil)
    }

    static func trendingWeek() async -> [TMDBTitle] {
        await fetchTitles("/3/trending/all/week", forcedType: nil)
    }

    static func nowPlaying() async -> [TMDBTitle] {
        await fetchTitles("/3/movie/now_playing", forcedType: "movie")
    }

    // MARK: Title artwork (hero logos)

    private static var logoCache: [String: String] = [:]
    private static let logoLock = NSLock()

    /// The title's official logo artwork (transparent PNG) for the
    /// Discover hero — Rex shows artwork, not typeset text, when a
    /// title has one. Prefers a zh logo, then en, then any language.
    /// Returns "" when the title has no logo at all.
    static func logo(for item: TMDBTitle) async -> String {
        let cacheKey = "\(item.mediaType)/\(item.id)"
        logoLock.lock()
        let hit = logoCache[cacheKey]
        logoLock.unlock()
        if let hit { return hit }
        guard isOn else { return "" }
        var comps = URLComponents(string: base + "/3/\(item.mediaType)/\(item.id)/images")
        comps?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "include_image_language", value: "zh,en,null"),
        ]
        var found = ""
        if let url = comps?.url,
           let root = await getJSON(url),
           let logos = root["logos"] as? [[String: Any]], !logos.isEmpty {
            let picked = logos.first { ($0["iso_639_1"] as? String) == "zh" }
                ?? logos.first { ($0["iso_639_1"] as? String) == "en" }
                ?? logos[0]
            if let path = picked["file_path"] as? String, !path.isEmpty {
                found = imageURL(path, size: "w500")
            }
        }
        logoLock.lock()
        logoCache[cacheKey] = found
        logoLock.unlock()
        return found
    }

    static func popularMovies() async -> [TMDBTitle] {
        await fetchTitles("/3/movie/popular", forcedType: "movie")
    }

    static func popularTV() async -> [TMDBTitle] {
        await fetchTitles("/3/tv/popular", forcedType: "tv")
    }

    static func topRated() async -> [TMDBTitle] {
        let movies = await fetchTitles("/3/movie/top_rated", forcedType: "movie")
        let shows = await fetchTitles("/3/tv/top_rated", forcedType: "tv")
        // Interleave so the row mixes both kinds evenly.
        var merged: [TMDBTitle] = []
        for i in 0..<max(movies.count, shows.count) {
            if i < movies.count { merged.append(movies[i]) }
            if i < shows.count { merged.append(shows[i]) }
        }
        return merged
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
