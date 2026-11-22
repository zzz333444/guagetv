import SwiftUI
import CryptoKit
import JavaScriptCore

/// Forward-format JS modules (v1.58) — the module system the user
/// asked to enable. A module is ONE JavaScript file following the
/// public ForwardWidget spec (InchStudio/ForwardWidgets): a global
/// `WidgetMetadata` (id / title / version / modules[] / search),
/// async handler functions named by each module entry's
/// `functionName`, returning VideoItem dictionaries. Handlers talk
/// to the host through `Widget.http` (synchronous native transport,
/// awaited as a plain value), `Widget.html.load` (the SAME bundled
/// cheerio build the drpy engine uses), `Widget.dom`,
/// `Widget.storage` and `Widget.sharedCache`.
///
/// Rex note: Rex exposes no public module format of its own; the
/// JS modules circulating for this class of app follow the Forward
/// spec, which is what runs here. Encrypted modules (FWENC1) are a
/// proprietary envelope and are refused at import with a clear note.
///
/// Playback: an item's own videoUrl plays directly; a module with
/// a `loadResource` (type "stream") entry resolves the URL at play
/// time; otherwise loadDetail(link) is asked for the videoUrl.

// MARK: - Metadata model

/// One `belongTo` condition (Rex guide 0.0.7, v2.26): the param
/// only shows — and only gets a default — when the named param
/// currently holds one of `values`. May also be written as an
/// array of conditions; all must hold for the param to show.
struct FWDBelongTo: Codable {
    var paramName: String
    var values: [String]
}

struct FWDParam {
    var name: String
    var title: String = ""
    var type: String = "input"
    var value: String = ""
    var enumOptions: [FWDOption] = []
    var desc: String = ""
    /// Suggested values for input params (Forward spec
    /// `placeholders: [{title, value}]`) — e.g. rex-tmdb's 片单
    /// column carries a preset TMDB list URL here. v1.75.
    var placeholders: [FWDOption] = []
    /// v2.26 (Rex guide): `belongTo` grouping + `startPage`
    /// for page params (0-based paging when startPage is 0).
    var belongTo: [FWDBelongTo] = []
    var startPage: Int? = nil

    /// Guide rule 3: hidden params get no default, but an
    /// explicitly saved/caller value still passes through
    /// (the combine step handles that half; this only decides
    /// whether the param shows and takes a default).
    func isVisible(given values: [String: String]) -> Bool {
        guard !belongTo.isEmpty else { return true }
        return belongTo.allSatisfy { cond in
            guard let v = values[cond.paramName] else { return false }
            return cond.values.contains(v)
        }
    }
}

/// Custom Decodable (same pattern as FWDMeta): fields added after
/// an index file was written must not drop every stored module.
extension FWDParam: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, title, type, value, enumOptions, desc, placeholders
        case belongTo, startPage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "input"
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        enumOptions = try c.decodeIfPresent([FWDOption].self, forKey: .enumOptions) ?? []
        desc = try c.decodeIfPresent(String.self, forKey: .desc) ?? ""
        placeholders = try c.decodeIfPresent([FWDOption].self, forKey: .placeholders) ?? []
        belongTo = try c.decodeIfPresent([FWDBelongTo].self, forKey: .belongTo) ?? []
        startPage = try c.decodeIfPresent(Int.self, forKey: .startPage)
    }
}

struct FWDOption: Codable {
    var title: String
    var value: String
}

struct FWDModuleEntry {
    var id: String = ""
    var title: String = ""
    var functionName: String = ""
    var type: String = ""
    var params: [FWDParam] = []
    /// v2.26 (Rex guide): entry display fields + per-entry
    /// result cache TTL in seconds. 0 = not declared; the app
    /// default (30 min) applies. Guide default is 86400 — the
    /// app deliberately keeps the fresher 30 min default.
    var subtitle: String = ""
    var iconurl: String = ""
    var cacheDuration: Int = 0
}

/// Hand-rolled Decodable like FWDMeta/FWDParam: fields added
/// after an index file was written must not drop every stored
/// module (synthesized Codable would throw on the missing key).
extension FWDModuleEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, functionName, type, params
        case subtitle, iconurl, cacheDuration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        functionName = try c.decodeIfPresent(String.self, forKey: .functionName) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        params = try c.decodeIfPresent([FWDParam].self, forKey: .params) ?? []
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        iconurl = try c.decodeIfPresent(String.self, forKey: .iconurl) ?? ""
        cacheDuration = try c.decodeIfPresent(Int.self, forKey: .cacheDuration) ?? 0
    }
}

struct FWDMeta {
    var id: String = ""
    var title: String = ""
    var version: String = ""
    var author: String = ""
    var description: String = ""
    var site: String = ""
    var icon: String = ""
    var modules: [FWDModuleEntry] = []
    var searchFunction: String?
    var searchParams: [FWDParam] = []
    var globalParams: [FWDParam] = []
    var hasDetail: Bool = false
    /// Column-result cache TTL in seconds, from the module's
    /// declared `cacheDuration` (Forward spec). 0 = not
    /// declared; the app default (30 min) applies. v2.06.
    /// v2.26: this top-level field is legacy — the Rex guide
    /// puts cacheDuration on each ENTRY, and detailCacheDuration
    /// on top. Kept only as a TTL fallback for index files
    /// written before v2.26.
    var cacheDuration: Int = 0
    /// v2.26 (Rex guide metadata chapter): minimum script
    /// engine version the module needs, whole-module content
    /// type, detail cache TTL (guide default 60 s), default
    /// continuous-play preference, and the i18n dictionary
    /// (consumed by R4; decoded now so imports validate it).
    var requiredVersion: String = ""
    var contentType: String = ""
    var detailCacheDuration: Int = 60
    var continuousPlay: Bool = false
    var i18n: [String: [String: String]] = [:]

    /// v2.29 (Rex guide i18n 章): the module's own display
    /// text in the user's language — module title, entry
    /// titles, param titles, option titles, placeholder hints.
    /// Lookup order per guide: exact locale code → script
    /// system (zh-TW/zh-HK/zh-MO → zh-Hant; zh-CN/zh-SG →
    /// zh-Hans) → base language → original text. Returned
    /// DATA (item titles, descriptions) is never translated.
    func localized(_ text: String) -> String {
        fwdLocalized(text, i18n: i18n)
    }

    /// v2.29: the module's effective content type. A valid
    /// declared contentType wins over any user choice (guide);
    /// when the module declares nothing (or an unknown value),
    /// the user's per-module choice applies, else "".
    var effectiveContentType: String {
        let known = ["video", "music", "audiobook", "shortDrama"]
        if known.contains(contentType) { return contentType }
        let chosen = FWDStore.contentTypeOverride(for: id)
        return known.contains(chosen) ? chosen : ""
    }
    /// True when the effective type comes from the user's own
    /// choice rather than the module's declaration.
    var contentTypeIsUserChosen: Bool {
        let known = ["video", "music", "audiobook", "shortDrama"]
        return !known.contains(contentType) && !effectiveContentType.isEmpty
    }
    var contentTypeLabel: String {
        switch effectiveContentType {
        case "video": return "视频"
        case "music": return "音乐"
        case "audiobook": return "听书"
        case "shortDrama": return "短剧"
        default: return ""
        }
    }

    /// Entries the browse UI can render as lists: everything that
    /// is not a stream resolver, a subtitle feed or a danmu feed.
    var listModules: [FWDModuleEntry] {
        modules.filter { $0.type != "stream" && $0.type != "danmu" && $0.type != "subtitle"
            && $0.id != "loadResource" && $0.id != "loadSubtitle" && !$0.functionName.isEmpty }
    }
    /// Guide 资源与字幕章 (v2.28): a resource entry is ONLY
    /// called when it is exactly id "loadResource" +
    /// functionName "loadResource" + type "stream". A bare
    /// type "stream" entry with another id/functionName is
    /// NOT called. v2.27 and earlier took the first
    /// type-"stream" entry regardless of id — that loose
    /// match is removed here.
    var resourceFunction: String? {
        modules.first { $0.id == "loadResource" && $0.functionName == "loadResource"
            && $0.type == "stream" }?.functionName
    }
    /// Guide 资源与字幕章 (v2.28): the standalone subtitle
    /// entry is exactly id "loadSubtitle" + functionName
    /// "loadSubtitle" + type "subtitle".
    var subtitleFunction: String? {
        modules.first { $0.id == "loadSubtitle" && $0.functionName == "loadSubtitle"
            && $0.type == "subtitle" }?.functionName
    }
}

/// Hand-rolled Decodable so index files written before a field
/// existed (e.g. `icon`, added in v1.59) still load instead of
/// dropping every imported module.
extension FWDMeta: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, version, author, description, site, icon
        case modules, searchFunction, searchParams, globalParams, hasDetail
        case cacheDuration
        case requiredVersion, contentType, detailCacheDuration, continuousPlay, i18n
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        site = try c.decodeIfPresent(String.self, forKey: .site) ?? ""
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? ""
        modules = try c.decodeIfPresent([FWDModuleEntry].self, forKey: .modules) ?? []
        searchFunction = try c.decodeIfPresent(String.self, forKey: .searchFunction)
        searchParams = try c.decodeIfPresent([FWDParam].self, forKey: .searchParams) ?? []
        globalParams = try c.decodeIfPresent([FWDParam].self, forKey: .globalParams) ?? []
        hasDetail = try c.decodeIfPresent(Bool.self, forKey: .hasDetail) ?? false
        cacheDuration = try c.decodeIfPresent(Int.self, forKey: .cacheDuration) ?? 0
        requiredVersion = try c.decodeIfPresent(String.self, forKey: .requiredVersion) ?? ""
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType) ?? ""
        detailCacheDuration = try c.decodeIfPresent(Int.self, forKey: .detailCacheDuration) ?? 60
        continuousPlay = try c.decodeIfPresent(Bool.self, forKey: .continuousPlay) ?? false
        i18n = try c.decodeIfPresent([String: [String: String]].self, forKey: .i18n) ?? [:]
    }
}

struct FWDRecord: Codable, Identifiable {
    var id: String
    var fileName: String
    var source: String
    var meta: FWDMeta
}

// MARK: - VideoItem

/// One subtitle track from a module (`externalSubtitles`
/// on an item, or a `loadSubtitle` entry — guide's 资源与字幕
/// chapter). Decoded in v2.27; playback consumption lands
/// in R3 alongside loadResource.
struct FWDSubtitle {
    var url: String = ""
    var title: String = ""
    var language: String = ""
    var isDefault: Bool = false
    var customHeaders: [String: String] = [:]

    init(_ d: [String: Any]) {
        func str(_ key: String) -> String {
            if let s = d[key] as? String { return s }
            if let n = d[key] as? NSNumber { return n.stringValue }
            return ""
        }
        url = str("url")
        // Guide: subtitle entries spell the track name `title`;
        // some modules write `name` (the resource-entry word)
        // — accept it as a fallback, never silently untitled.
        title = str("title").isEmpty ? str("name") : str("title")
        // The subtitle entry spells it `lang`; the item field
        // spells it `language` — accept both.
        language = str("language").isEmpty ? str("lang") : str("language")
        if let b = d["isDefault"] as? Bool { isDefault = b }
        else if let n = d["isDefault"] as? NSNumber { isDefault = n.boolValue }
        else if let s = d["isDefault"] as? String { isDefault = s == "true" || s == "1" }
        if let dict = d["customHeaders"] as? [String: Any] ?? d["headers"] as? [String: Any] {
            for (k, v) in dict { customHeaders[k] = String(describing: v) }
        }
    }

    /// Menu label: title first, else the language tag, else a
    /// bare "字幕" so a track never renders as an empty row.
    var displayName: String {
        if !title.isEmpty { return title }
        if !language.isEmpty { return language }
        return "字幕"
    }
}

/// One playback line from a `loadResource` entry (guide 资源与
/// 字幕章, v2.28): [{name, url, description, customHeaders,
/// playerType}]. `name` and `url` are both required by the
/// guide; a nameless line gets "线路 N" so the resource
/// picker never shows a blank row.
struct FWDResource {
    var name: String = ""
    var url: String = ""
    var description: String = ""
    var playerType: String = ""
    var customHeaders: [String: String] = [:]

    init(_ d: [String: Any], index: Int) {
        func str(_ key: String) -> String {
            if let s = d[key] as? String { return s }
            if let n = d[key] as? NSNumber { return n.stringValue }
            return ""
        }
        name = str("name").isEmpty ? "线路 \(index + 1)" : str("name")
        url = str("url")
        description = str("description")
        playerType = str("playerType")
        if let dict = d["customHeaders"] as? [String: Any] ?? d["headers"] as? [String: Any] {
            for (k, v) in dict { customHeaders[k] = String(describing: v) }
        }
    }
}

/// Playback context for loadResource / loadSubtitle / danmu
/// entries (guide 资源与字幕章 + 弹幕章, v2.28). Every value
/// is a string; a field the item does not carry is simply not
/// passed. `title` (the search title) is only sent to the
/// subtitle and danmu entries — never to loadResource.
enum FWDPlaybackContext {
    static func build(item: FWDItem, seriesTitle: String?, episodeName: String?,
                      includeTitle: Bool, episodeFallback: Int? = nil) -> [String: Any] {
        var p: [String: Any] = ["id": item.id]
        let kind: String
        if item.mediaType == "movie" || item.mediaType == "tv" { kind = item.mediaType }
        else if !item.episodeItems.isEmpty || !item.tracks.isEmpty || !item.childItems.isEmpty { kind = "tv" }
        else { kind = "movie" }
        p["type"] = kind
        p["seriesName"] = seriesTitle ?? item.title
        if let episodeName, !episodeName.isEmpty { p["episodeName"] = episodeName }
        if item.type == "tmdb" { p["tmdbId"] = item.id }
        if let s = item.season { p["season"] = String(s) }
        if let e = item.episode { p["episode"] = String(e) }
        else if let f = episodeFallback { p["episode"] = String(f) }
        if !item.link.isEmpty { p["link"] = item.link }
        if !item.releaseDate.isEmpty { p["airDate"] = item.releaseDate }
        if let d = item.duration { p["runtime"] = String(d) }
        if includeTitle { p["title"] = seriesTitle ?? item.title }
        return p
    }

    /// Module-level globalParams (e.g. danmu.js's `server`)
    /// ride along with playback calls, same as list calls.
    static func withGlobals(_ p: [String: Any], meta: FWDMeta) -> [String: Any] {
        var out = p
        for g in meta.globalParams where !g.value.isEmpty { out[g.name] = g.value }
        return out
    }
}

struct FWDItem: Identifiable {
    var id: String = ""
    var type: String = ""
    var title: String = ""
    /// Card subtitle (guide: NOT a subtitle track — the
    /// subtitle track field is `externalSubtitles`). v2.27:
    /// previously never decoded, so cards had no subtitle.
    var subtitle: String = ""
    var poster: String = ""
    var backdrop: String = ""
    /// Detail-page stills (guide: 剧照用 backdropPaths).
    /// v2.27: previously never decoded — the official
    /// tmdb.js loadDetail returns exactly this field.
    var backdropPaths: [String] = []
    /// Detail-page poster (guide 图片章). v2.27.
    var detailPoster: String = ""
    var cover: String = ""
    var coverRatio: Double = 0
    var releaseDate: String = ""
    var rating: String = ""
    var overview: String = ""
    var mediaType: String = ""
    var link: String = ""
    var videoUrl: String = ""
    /// Playback duration in seconds (guide: `duration` is
    /// a number). v2.27: previously only durationText existed.
    var duration: Int?
    var durationText: String = ""
    var genreTitle: String = ""
    /// Genre list (guide: [{id, title}]). v2.27: the
    /// official tmdb.js loadDetail returns genreItems, and
    /// the old code only ever read the flat genreTitle.
    var genreItems: [(id: String, title: String)] = []
    var language: String = ""
    var season: Int?
    var episode: Int?
    /// Preview / trailer (guide 播放章). Decoded v2.27;
    /// a trailer player entry is out of this round's scope.
    var previewUrl: String = ""
    var trailers: [(coverUrl: String, videoUrl: String)] = []
    /// Engine preference from the module (`system` / `app` /
    /// empty = auto). Decoded v2.27; honoured by R3.
    var playerType: String = ""
    /// Per-item request headers (guide: `customHeaders`,
    /// alias `headers`) — playback and image loads carry
    /// them. v2.27: previously only loadResource results
    /// read headers; a direct videoUrl played headerless.
    var customHeaders: [String: String] = [:]
    var externalSubtitles: [FWDSubtitle] = []
    var episodeItems: [FWDItem] = []
    /// Music / audiobook tracks (guide 0.0.7: clients prefer
    /// valid `tracks`, falling back to `episodeItems`).
    /// Decoded v2.27; the detail page's episode list reads
    /// tracks first. Music UI stays R4's job.
    /// Dynamic cover video for album detail (guide 0.0.7
    /// 音乐章: `albumMotionArtwork`, an HTTP(S) video URL).
    /// Decoded v2.29; the detail page notes its presence in
    /// the media-info card (no inline video hero — the App
    /// has no motion-cover surface yet).
    var albumMotionArtwork: String = ""
    var tracks: [FWDItem] = []
    var relatedItems: [FWDItem] = []
    var childItems: [FWDItem] = []
    /// Guide: [{id, title, avatar, role}]. v2.27: id and
    /// avatar were dropped; the cast row now shows avatars.
    var peoples: [(id: String, name: String, role: String, avatar: String)] = []

    var posterURL: String {
        [poster, detailPoster, backdrop, cover].first { !$0.isEmpty } ?? ""
    }
    var backdropURL: String {
        [backdropPaths.first ?? "", backdrop, cover, poster].first { !$0.isEmpty } ?? ""
    }

    /// One-line "year · ★rating" caption for recommendation cards.
    var shortMetaLine: String {
        [String(releaseDate.prefix(4)), rating.isEmpty ? "" : "★\(rating)"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    init(_ d: [String: Any]) {
        func str(_ key: String) -> String {
            if let s = d[key] as? String { return s }
            if let n = d[key] as? NSNumber { return n.stringValue }
            return ""
        }
        id = str("id")
        type = str("type")
        title = str("title")
        subtitle = str("subtitle")
        poster = str("posterPath").isEmpty ? (str("posterUrl").isEmpty ? str("poster_url") : str("posterUrl")) : str("posterPath")
        backdrop = str("backdropPath")
        backdropPaths = (d["backdropPaths"] as? [Any] ?? []).compactMap {
            if let s = $0 as? String { return s }
            if let n = $0 as? NSNumber { return n.stringValue }
            return nil
        }
        detailPoster = str("detailPoster")
        cover = str("coverUrl")
        if let n = d["coverRatio"] as? NSNumber { coverRatio = n.doubleValue }
        // TMDB items carry raw image paths; expand them here so
        // every display slot downstream sees absolute URLs.
        if type == "tmdb" {
            if poster.hasPrefix("/") { poster = TMDBClient.imageURL(poster, size: "w500") }
            if backdrop.hasPrefix("/") { backdrop = TMDBClient.imageURL(backdrop, size: "w780") }
            if cover.hasPrefix("/") { cover = TMDBClient.imageURL(cover, size: "w500") }
            if detailPoster.hasPrefix("/") { detailPoster = TMDBClient.imageURL(detailPoster, size: "w500") }
            backdropPaths = backdropPaths.map {
                $0.hasPrefix("/") ? TMDBClient.imageURL($0, size: "original") : $0
            }
        }
        releaseDate = str("releaseDate")
        rating = str("rating")
        overview = str("description")
        mediaType = str("mediaType")
        link = str("link")
        videoUrl = str("videoUrl")
        if let n = d["duration"] as? NSNumber { duration = n.intValue }
        else if let s = d["duration"] as? String, let v = Int(s) { duration = v }
        durationText = str("durationText")
        genreTitle = str("genreTitle")
        genreItems = (d["genreItems"] as? [[String: Any]] ?? []).map {
            (id: ($0["id"] as? String) ?? (($0["id"] as? NSNumber)?.stringValue ?? ""),
             title: ($0["title"] as? String) ?? "")
        }.filter { !$0.id.isEmpty || !$0.title.isEmpty }
        if genreTitle.isEmpty, !genreItems.isEmpty {
            genreTitle = genreItems.map(\.title).filter { !$0.isEmpty }.joined(separator: " / ")
        }
        language = str("language")
        if let n = d["season"] as? NSNumber { season = n.intValue }
        if let n = d["episode"] as? NSNumber { episode = n.intValue }
        previewUrl = str("previewUrl")
        trailers = (d["trailers"] as? [[String: Any]] ?? []).map {
            (coverUrl: ($0["coverUrl"] as? String) ?? "",
             videoUrl: ($0["videoUrl"] as? String) ?? "")
        }.filter { !$0.videoUrl.isEmpty }
        playerType = str("playerType")
        if let dict = d["customHeaders"] as? [String: Any] ?? d["headers"] as? [String: Any] {
            for (k, v) in dict { customHeaders[k] = String(describing: v) }
        }
        externalSubtitles = (d["externalSubtitles"] as? [[String: Any]] ?? []).map(FWDSubtitle.init)
        episodeItems = (d["episodeItems"] as? [[String: Any]] ?? []).map(FWDItem.init)
        tracks = (d["tracks"] as? [[String: Any]] ?? []).map(FWDItem.init)
        albumMotionArtwork = str("albumMotionArtwork")
        relatedItems = (d["relatedItems"] as? [[String: Any]] ?? []).map(FWDItem.init)
        childItems = (d["childItems"] as? [[String: Any]] ?? []).map(FWDItem.init)
        peoples = (d["peoples"] as? [[String: Any]] ?? []).map {
            (id: ($0["id"] as? String) ?? (($0["id"] as? NSNumber)?.stringValue ?? ""),
             name: ($0["title"] as? String) ?? (($0["name"] as? String) ?? ""),
             role: ($0["role"] as? String) ?? "",
             avatar: ($0["avatar"] as? String) ?? "")
        }.filter { !$0.name.isEmpty }
        if id.isEmpty { id = link.isEmpty ? title : link }
    }

    /// Merge a loadDetail result into the thin list item
    /// (guide 详情章: a TMDB item carrying a `link` gets its
    /// loadDetail result MERGED into the built-in detail page).
    /// v2.27: the old code replaced the whole item, so a
    /// detail dict without poster/rating silently dropped the
    /// list item's TMDB fields. Merge rule: the detail fills
    /// what the list item lacks; non-empty detail arrays win;
    /// id/type stay the list item's (the TMDB id must survive).
    /// An id the list item only derived from its link is
    /// replaced by the detail's stable id.
    func mergedDetail(_ d: FWDItem) -> FWDItem {
        var out = self
        func fill(_ keyPath: WritableKeyPath<FWDItem, String>, with value: String) {
            if out[keyPath: keyPath].isEmpty { out[keyPath: keyPath] = value }
        }
        fill(\.subtitle, with: d.subtitle)
        fill(\.poster, with: d.poster)
        fill(\.backdrop, with: d.backdrop)
        fill(\.detailPoster, with: d.detailPoster)
        fill(\.releaseDate, with: d.releaseDate)
        fill(\.rating, with: d.rating)
        fill(\.overview, with: d.overview)
        fill(\.mediaType, with: d.mediaType)
        fill(\.link, with: d.link)
        fill(\.videoUrl, with: d.videoUrl)
        fill(\.durationText, with: d.durationText)
        fill(\.genreTitle, with: d.genreTitle)
        fill(\.language, with: d.language)
        fill(\.previewUrl, with: d.previewUrl)
        fill(\.playerType, with: d.playerType)
        fill(\.albumMotionArtwork, with: d.albumMotionArtwork)
        if out.backdropPaths.isEmpty { out.backdropPaths = d.backdropPaths }
        if out.coverRatio == 0 { out.coverRatio = d.coverRatio }
        if out.duration == nil { out.duration = d.duration }
        if out.genreItems.isEmpty { out.genreItems = d.genreItems }
        if out.season == nil { out.season = d.season }
        if out.episode == nil { out.episode = d.episode }
        if out.trailers.isEmpty { out.trailers = d.trailers }
        if out.episodeItems.isEmpty { out.episodeItems = d.episodeItems }
        if out.tracks.isEmpty { out.tracks = d.tracks }
        if out.relatedItems.isEmpty { out.relatedItems = d.relatedItems }
        if out.childItems.isEmpty { out.childItems = d.childItems }
        if out.peoples.isEmpty { out.peoples = d.peoples }
        if out.externalSubtitles.isEmpty { out.externalSubtitles = d.externalSubtitles }
        for (k, v) in d.customHeaders where out.customHeaders[k] == nil { out.customHeaders[k] = v }
        if !d.id.isEmpty, (out.id.isEmpty || out.id == out.link) { out.id = d.id }
        return out
    }
}

extension FWDItem: Hashable {
    static func == (lhs: FWDItem, rhs: FWDItem) -> Bool {
        lhs.id == rhs.id && lhs.link == rhs.link && lhs.title == rhs.title
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(link)
        hasher.combine(title)
    }
}

// MARK: - Store

enum FWDStore {
    struct StoreFailure: Error, CustomStringConvertible, LocalizedError {
        let message: String
        var description: String { message }
        var errorDescription: String? { message }
    }

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("widgets", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func records() -> [FWDRecord] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
              let list = try? JSONDecoder().decode([FWDRecord].self, from: data) else { return [] }
        return list
    }

    private static func save(_ records: [FWDRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: dir.appendingPathComponent("index.json"), options: .atomic)
    }

    static func source(for record: FWDRecord) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(record.fileName), encoding: .utf8)
    }

    @discardableResult
    static func importModule(source: String, origin: String) throws -> FWDRecord {
        if source.hasPrefix("FWENC1") {
            throw StoreFailure(message: "这是加密模块（FWENC1），内容已加密无法读取，暂不支持导入；请向模块作者索取未加密版本")
        }
        guard source.contains("WidgetMetadata") else {
            throw StoreFailure(message: "不是 Forward 模块（找不到 WidgetMetadata）")
        }
        let meta = try FWDRuntime.parseMetadata(source: source)
        // v2.26: import-time metadata validation (Rex guide).
        // Errors block the import with a Chinese three-part
        // list; warnings let it through and stay on the card.
        let validation = FWDRuntime.validateMetadata(source: source)
        if !validation.errors.isEmpty {
            throw StoreFailure(message: "模块元数据校验不通过：\n" + validation.errors.joined(separator: "\n"))
        }
        guard !meta.id.isEmpty else {
            throw StoreFailure(message: "模块缺少 id")
        }
        saveValidationNotes(validation.warnings, for: meta.id)
        let fileName = meta.id.replacingOccurrences(of: "/", with: "_") + ".js"
        try source.write(to: dir.appendingPathComponent(fileName),
                         atomically: true, encoding: .utf8)
        let record = FWDRecord(id: meta.id, fileName: fileName, source: origin, meta: meta)
        var all = records()
        all.removeAll { $0.id == meta.id }
        all.append(record)
        save(all)
        return record
    }

    /// v2.26: non-blocking metadata warnings from the import
    /// check, kept per module and shown on its card. Empty
    /// (or a fresh clean import) clears the stored notes.
    static func validationNotes(for recordID: String) -> [String]? {
        guard let data = UserDefaults.standard.data(forKey: "fwd.validationNotes.\(recordID)"),
              let notes = try? JSONDecoder().decode([String].self, from: data),
              !notes.isEmpty else { return nil }
        return notes
    }

    static func saveValidationNotes(_ notes: [String], for recordID: String) {
        let key = "fwd.validationNotes.\(recordID)"
        if notes.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(notes) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// v2.26: user-saved global params (Rex guide rule 1 —
    /// they override caller values, including empty strings).
    /// The combine layer reads this store; no settings UI
    /// writes it yet, so it is empty until a later round adds
    /// the per-module global-params editor.
    static func savedGlobalParams(for recordID: String) -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: "fwd.savedGlobals.\(recordID)"),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    static func saveGlobalParams(_ params: [String: String], for recordID: String) {
        if params.isEmpty {
            UserDefaults.standard.removeObject(forKey: "fwd.savedGlobals.\(recordID)")
        } else if let data = try? JSONEncoder().encode(params) {
            UserDefaults.standard.set(data, forKey: "fwd.savedGlobals.\(recordID)")
        }
    }

    /// v2.29 (Rex guide 内容类型章): the user's per-module
    /// content-type choice. Only consulted when the module
    /// itself declares no valid contentType — a valid
    /// declaration always wins over this value.
    static func contentTypeOverride(for recordID: String) -> String {
        UserDefaults.standard.string(forKey: "fwd.contentTypeOverride.\(recordID)") ?? ""
    }

    static func saveContentTypeOverride(_ value: String, for recordID: String) {
        let key = "fwd.contentTypeOverride.\(recordID)"
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    /// v2.29: one subscription batch import, reported per
    /// link. Policy (guide-aligned, now explicit): a link
    /// whose module id already exists OVERWRITES the old
    /// record (file rewritten, same id); a failed link never
    /// blocks the rest; duplicates in one subscription are
    /// fetched once.
    struct ImportOutcome {
        var imported: Int = 0
        var overwritten: Int = 0
        var failures: [String] = []

        /// Back-compat for the old count-returning importers:
        /// a batch that landed nothing still throws, with the
        /// per-link causes attached instead of one bare line.
        func importedOrThrow() throws -> Int {
            guard imported > 0 else {
                throw StoreFailure(message: failures.isEmpty
                    ? "订阅里的模块都没导入成功"
                    : "订阅里的模块都没导入成功：" + failures.joined(separator: "；"))
            }
            return imported
        }
    }

    /// Shared link extraction for .fwd subscriptions (JSON
    /// under widgets / modules / urls / list, entries as
    /// strings or {url|link|src} objects; else plain-text
    /// http lines). Deduplicated, order preserved.
    static func subscriptionLinks(from text: String) -> [String] {
        var links: [String] = []
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["widgets", "modules", "urls", "list"] {
                if let arr = json[key] as? [Any] {
                    for entry in arr {
                        if let s = entry as? String { links.append(s) }
                        if let o = entry as? [String: Any] {
                            for k in ["url", "link", "src"] {
                                if let s = o[k] as? String { links.append(s); break }
                            }
                        }
                    }
                }
            }
        }
        if links.isEmpty {
            links = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("http") }
        }
        var seen = Set<String>()
        return links.filter { seen.insert($0).inserted }
    }

    static func importLinks(_ links: [String]) async -> ImportOutcome {
        var outcome = ImportOutcome()
        for link in links {
            let before = Set(records().map(\.id))
            guard let u = URL(string: link),
                  let (d, _) = try? await URLSession.shared.data(from: u),
                  let js = String(data: d, encoding: .utf8) else {
                outcome.failures.append("\(URL(string: link)?.lastPathComponent ?? link)：下载失败")
                continue
            }
            do {
                let record = try importModule(source: js, origin: link)
                outcome.imported += 1
                if before.contains(record.id) { outcome.overwritten += 1 }
            } catch {
                outcome.failures.append("\(URL(string: link)?.lastPathComponent ?? link)：\(error.localizedDescription)")
            }
        }
        return outcome
    }

    /// One-line Chinese summary for a batch outcome, for the
    /// Modules page note line (imported / overwritten /
    /// per-link failures, never a bare count that hides a
    /// partial failure).
    static func importOutcomeText(_ outcome: ImportOutcome) -> String {
        var parts: [String] = []
        if outcome.imported > 0 {
            parts.append("已导入 \(outcome.imported) 个模块"
                         + (outcome.overwritten > 0 ? "（其中 \(outcome.overwritten) 个覆盖同名旧版）" : ""))
        }
        if !outcome.failures.isEmpty {
            parts.append("失败 \(outcome.failures.count) 个：" + outcome.failures.joined(separator: "；"))
        }
        return parts.joined(separator: " · ")
    }

    static func delete(_ record: FWDRecord) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(record.fileName))
        save(records().filter { $0.id != record.id })
        clearCheckResult(for: record.id)
        // v2.26: validation notes and saved globals go with it.
        UserDefaults.standard.removeObject(forKey: "fwd.validationNotes.\(record.id)")
        UserDefaults.standard.removeObject(forKey: "fwd.savedGlobals.\(record.id)")
        // v2.07: a deleted module's per-module storage and cached
        // columns go with it — otherwise a later re-import of the
        // same id resurrects stale credentials and stale lists.
        // Widget.sharedCache is intentionally shared across
        // modules (Forward spec) and is left alone.
        UserDefaults.standard.removeObject(forKey: "fwd.storage.\(record.id)")
        FWDColumnCache.clear(moduleID: record.id)
    }

    /// v1.94: per-module self-check result, kept on the card
    /// (last check time + conclusion). Stored in UserDefaults
    /// so it survives restarts; cleared when the module is deleted.
    struct CheckResult: Codable {
        var time: Date
        var ok: Bool
        var summary: String
        /// v2.18: per-column detail (title, pass/fail, item
        /// count or error, duration in ms). Optional so
        /// results saved by older builds still decode.
        var columns: [ColumnCheck]? = nil
    }

    /// One list column's self-check outcome (v2.18).
    struct ColumnCheck: Codable {
        var title: String
        var ok: Bool
        var count: Int
        var error: String
        var ms: Int
    }

    private static let checkResultsKey = "fwd.checkResults.v1"

    static func checkResult(for recordID: String) -> CheckResult? {
        guard let data = UserDefaults.standard.data(forKey: checkResultsKey),
              let all = try? JSONDecoder().decode([String: CheckResult].self, from: data) else { return nil }
        return all[recordID]
    }

    static func saveCheckResult(_ result: CheckResult, for recordID: String) {
        var all: [String: CheckResult] = [:]
        if let data = UserDefaults.standard.data(forKey: checkResultsKey),
           let decoded = try? JSONDecoder().decode([String: CheckResult].self, from: data) {
            all = decoded
        }
        all[recordID] = result
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: checkResultsKey)
        }
    }

    static func clearCheckResult(for recordID: String) {
        guard let data = UserDefaults.standard.data(forKey: checkResultsKey),
              var all = try? JSONDecoder().decode([String: CheckResult].self, from: data) else { return }
        all.removeValue(forKey: recordID)
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: checkResultsKey)
        }
    }

    /// Import from a URL: a bare .js module, or a .fwd subscription
    /// (JSON listing module URLs under widgets / modules / urls,
    /// entries as strings or {url} objects; plain-text line lists
    /// also accepted). Returns how many modules landed.
    static func importRemote(_ urlString: String) async throws -> Int {
        try await importRemoteDetailed(urlString).importedOrThrow()
    }

    /// v2.29: the batch outcome (imported / overwritten /
    /// per-link failures) instead of a bare count.
    static func importRemoteDetailed(_ urlString: String) async throws -> ImportOutcome {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw StoreFailure(message: "链接无效")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw StoreFailure(message: "下载内容无法读取")
        }
        if text.contains("WidgetMetadata") || text.hasPrefix("FWENC1") {
            let before = Set(records().map(\.id))
            let record = try importModule(source: text, origin: trimmed)
            var outcome = ImportOutcome(imported: 1)
            if before.contains(record.id) { outcome.overwritten = 1 }
            return outcome
        }
        let links = subscriptionLinks(from: text)
        guard !links.isEmpty else {
            throw StoreFailure(message: "订阅里没找到模块链接")
        }
        return await importLinks(links)
    }

    /// Local-file counterpart of importRemote: the picked file is
    /// either a module .js (imported directly) or a .fwd / text
    /// subscription (its links are fetched and imported).
    static func importFileText(_ text: String, origin: String) async throws -> Int {
        try await importFileTextDetailed(text, origin: origin).importedOrThrow()
    }

    /// v2.29: batch outcome for a picked file (see
    /// importRemoteDetailed).
    static func importFileTextDetailed(_ text: String, origin: String) async throws -> ImportOutcome {
        if text.contains("WidgetMetadata") || text.hasPrefix("FWENC1") {
            let before = Set(records().map(\.id))
            let record = try importModule(source: text, origin: origin)
            var outcome = ImportOutcome(imported: 1)
            if before.contains(record.id) { outcome.overwritten = 1 }
            return outcome
        }
        let links = subscriptionLinks(from: text)
        guard !links.isEmpty else {
            throw StoreFailure(message: "文件里没找到模块或订阅链接")
        }
        return await importLinks(links)
    }
}

/// Column-result cache (v2.06; file-backed since v2.30):
/// re-entering a module column replays the last page-1 result
/// instead of re-running the JS handler and the network. TTL
/// honours the module's declared `cacheDuration` (seconds) when
/// present, otherwise 30 min. Only page-1 list results are
/// cached, never searches, never empty results (a transient 0
/// must not poison the next visit).
///
/// v2.30 storage change — why the move matters: the old store
/// was ONE UserDefaults blob ([String: Data], up to 30 entries
/// × 30 rows). Every column visit re-encoded and rewrote the
/// WHOLE blob on the main actor, and UserDefaults loads its
/// entire plist at app launch, so the cache taxed cold start
/// even on days the module page never opened. Entries now live
/// as one small JSON file each under Caches/fwd-columns/, with
/// an in-memory copy of entries touched this session; writes
/// are single-file, detached, and bounded (30 files / 5 MB,
/// oldest-first eviction, >24 h files pruned — 24 h is the
/// guide's default cacheDuration of 86400 s). The legacy blob
/// is migrated once, on first access, then deleted.
enum FWDColumnCache {
    private static let legacyKey = "fwd.columnCache.v1"
    private static let maxEntries = 30
    private static let maxBytes: Int64 = 5 * 1024 * 1024
    private static let maxAge: TimeInterval = 86400
    static let defaultTTL: TimeInterval = 1800

    /// Entries touched this session (key → savedAt + rows), so
    /// a re-entered column never touches disk at all. All
    /// callers run on the main actor (module column loads,
    /// module delete), so no locking is needed here; file IO
    /// below always runs detached.
    private static var memory: [String: (savedAt: TimeInterval, rows: [[String: Any]])] = [:]
    private static var migrationStarted = false

    private static var dir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fwd-columns", isDirectory: true)
    }

    private static func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(hex + ".json")
    }

    static func key(moduleID: String, columnID: String, params: [String: Any]) -> String {
        let paramsJSON = (try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return moduleID + "|" + columnID + "|" + paramsJSON
    }

    static func get(key: String, ttl: TimeInterval) -> [[String: Any]]? {
        kickMigration()
        if let hit = memory[key],
           Date().timeIntervalSince1970 - hit.savedAt < ttl {
            return hit.rows
        }
        if let data = try? Data(contentsOf: fileURL(for: key)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let savedAt = obj["savedAt"] as? TimeInterval,
           Date().timeIntervalSince1970 - savedAt < ttl,
           let rows = obj["rows"] as? [[String: Any]] {
            memory[key] = (savedAt, rows)
            return rows
        }
        // Transitional fallback: a pre-v2.30 blob not yet
        // migrated. Read-only here; the migration task below
        // moves it to files and deletes the key.
        if let data = (UserDefaults.standard.dictionary(forKey: legacyKey) as? [String: Data])?[key],
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let savedAt = obj["savedAt"] as? TimeInterval,
           Date().timeIntervalSince1970 - savedAt < ttl,
           let rows = obj["rows"] as? [[String: Any]] {
            memory[key] = (savedAt, rows)
            return rows
        }
        return nil
    }

    static func set(key: String, rows: [[String: Any]]) {
        kickMigration()
        let savedAt = Date().timeIntervalSince1970
        memory[key] = (savedAt, rows)
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "key": key, "savedAt": savedAt, "rows": rows]) else { return }
        let file = fileURL(for: key)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            prune()
        }
    }

    /// Drop every cached column of one module (module delete,
    /// v2.07): keys are "moduleID|columnID|params…".
    static func clear(moduleID: String) {
        memory = memory.filter { !$0.key.hasPrefix(moduleID + "|") }
        let prefix = moduleID + "|"
        Task.detached(priority: .utility) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return }
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let storedKey = obj["key"] as? String,
                      storedKey.hasPrefix(prefix) else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Drop the whole column cache (cache-management page).
    static func clearAll() {
        memory.removeAll()
        Task.detached(priority: .utility) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return }
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// On-disk size of the column cache, for the cache page.
    static func size() async -> Int64 {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
            var total: Int64 = 0
            for file in files {
                total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return total
        }.value
    }

    /// One-time migration of the pre-v2.30 UserDefaults blob to
    /// files, then the legacy key is deleted so the blob stops
    /// loading at every app launch.
    private static func kickMigration() {
        guard !migrationStarted else { return }
        migrationStarted = true
        Task.detached(priority: .utility) {
            guard let dict = UserDefaults.standard.dictionary(forKey: legacyKey) as? [String: Data],
                  !dict.isEmpty else { return }
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            for (key, data) in dict {
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let savedAt = obj["savedAt"] as? TimeInterval,
                      let rows = obj["rows"] as? [[String: Any]],
                      let out = try? JSONSerialization.data(withJSONObject: [
                        "key": key, "savedAt": savedAt, "rows": rows]) else { continue }
                try? out.write(to: fileURL(for: key), options: .atomic)
            }
            UserDefaults.standard.removeObject(forKey: legacyKey)
            prune()
        }
    }

    /// Oldest-first eviction down to the entry/byte caps; files
    /// older than maxAge go first regardless of size.
    private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        var entries: [(url: URL, size: Int, date: Date)] = []
        var total: Int64 = 0
        for file in files where file.pathExtension == "json" {
            let values = try? file.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            total += Int64(size)
            entries.append((file, size, values?.contentModificationDate ?? .distantPast))
        }
        let now = Date()
        let sorted = entries.sorted(by: { $0.date < $1.date })
        var remaining = sorted.count
        for entry in sorted {
            let tooOld = now.timeIntervalSince(entry.date) > maxAge
            if !tooOld, remaining <= maxEntries, total <= maxBytes { break }
            try? fm.removeItem(at: entry.url)
            total -= Int64(entry.size)
            remaining -= 1
        }
    }
}

// MARK: - Runtime

final class FWDRuntime {
    struct FWDfailure: Error, CustomStringConvertible, LocalizedError {
        /// Chinese error class (v2.01): network failure, script
        /// exception and timeout are reported separately instead
        /// of one undifferentiated message, so the module page
        /// and diagnostics name the actual cause. `other` covers
        /// host-side engine/resource failures, which are neither
        /// a network nor a module-script problem.
        enum Kind: String {
            case network = "网络失败"
            case script = "脚本异常"
            case timeout = "超时"
            case other = "模块错误"
        }
        let message: String
        let kind: Kind
        init(message: String, kind: Kind = .other) {
            self.message = message
            self.kind = kind
        }
        var description: String { "[\(kind.rawValue)] \(message)" }
        // Without LocalizedError, localizedDescription degrades
        // to "(GuageTV.FWDRuntime.FWDfailure error 1.)" and the
        // real cause never reaches the screen (device report,
        // v1.76): the message IS the diagnosis, surface it.
        var errorDescription: String? { "[\(kind.rawValue)] \(message)" }

        /// Classify a module rejection message: a sub-request
        /// timeout ("子请求超时") or the 60 s call budget reads
        /// as timeout, transport failures as network, everything
        /// else as a script error. The strings it matches are
        /// the ones this file and JSRuntime.syncFetch produce,
        /// so the classification is deterministic, not a guess
        /// over arbitrary module text.
        static func classifyModuleError(_ text: String) -> Kind {
            if text.contains("超时") { return .timeout }
            if text.contains("网络") || text.contains("无网络")
                || text.contains("无法连接") || text.contains("找不到服务器")
                || text.contains("连接中断") || text.contains("证书") {
                return .network
            }
            return .script
        }
    }

    private let queue = DispatchQueue(label: "guage.fwd")
    private let widgetID: String
    private var lastException: String?

    init(widgetID: String) {
        self.widgetID = widgetID
    }

    static func parseMetadata(source: String) throws -> FWDMeta {
        try FWDRuntime(widgetID: "meta").parseMetadataLocked(source: source)
    }

    /// v2.26 — import-time metadata validation against the Rex
    /// guide (the App-side counterpart of the official
    /// validate.mjs, which needs literal metadata and cannot
    /// parse rex-tmdb.js). Every issue is Chinese and
    /// three-part: 哪个字段/参数、什么问题、怎么改.
    /// Errors block the import; warnings let it through and
    /// are stored for the module card.
    static func validateMetadata(source: String) -> (errors: [String], warnings: [String]) {
        var errors: [String] = []
        var warnings: [String] = []
        let runtime = FWDRuntime(widgetID: "validate")
        let raw: [String: Any]
        do {
            (raw, _) = try runtime.metadataRawAndDetail(source: source)
        } catch {
            return (["模块元数据读不到：脚本里没有可用的 WidgetMetadata。改法：顶层用 var WidgetMetadata = {…} 声明。"], [])
        }
        func isStr(_ v: Any?) -> Bool { v is String }
        func isNum(_ v: Any?) -> Bool { v is NSNumber }
        // Top-level required strings (guide: id/title/version/
        // requiredVersion/modules are all required).
        for key in ["id", "title", "version", "requiredVersion"] {
            if raw[key] == nil {
                errors.append("元数据 \(key)：缺失（必填）。改法：在 WidgetMetadata 里补 \(key): \"…\"。")
            } else if !isStr(raw[key]) {
                errors.append("元数据 \(key)：写成了 \(typeName(raw[key]))，应为字符串。改法：改成 \(key): \"\(stringValue(raw[key]))\"。")
            }
        }
        if let v = raw["requiredVersion"] as? String,
           v.compare("0.0.7", options: .numeric) == .orderedDescending {
            warnings.append("元数据 requiredVersion：要求脚本引擎 \(v)，高于本 App 支持的 0.0.7。改法：用到新特性的入口可能跑不了，可先导入试用，或等 App 跟进。")
        }
        if let ct = raw["contentType"] as? String,
           !["video", "music", "audiobook", "shortDrama"].contains(ct) {
            warnings.append("元数据 contentType：\"\(ct)\" 不是已知的 video/music/audiobook/shortDrama。改法：改成其中之一，或删掉该字段按未指定处理。")
        } else if raw["contentType"] != nil, !isStr(raw["contentType"]) {
            warnings.append("元数据 contentType：应为字符串。改法：改成 contentType: \"video\" 这类写法。")
        }
        if let d = raw["detailCacheDuration"], !isNum(d), !(d is String) {
            warnings.append("元数据 detailCacheDuration：应为秒数。改法：改成 detailCacheDuration: 60。")
        }
        if let i18n = raw["i18n"], !(i18n is [String: Any]) {
            warnings.append("元数据 i18n：应为 {语言: {原文: 译文}} 的词典。改法：按 guide 的 i18n 一节重写，无效词典会被忽略。")
        }
        let modules = raw["modules"] as? [[String: Any]] ?? []
        if modules.isEmpty {
            errors.append("模块入口 modules：为空或缺失，模块没有可打开的栏目。改法：在 WidgetMetadata 里加 modules: [{id, title, functionName}]。")
        }
        var seenIDs = Set<String>()
        func checkParams(_ list: Any?, where whereText: String) {
            guard let arr = list as? [[String: Any]] else { return }
            for p in arr {
                let name = p["name"] as? String ?? ""
                let label = name.isEmpty ? "（未命名参数）" : "参数 \(name)"
                if name.isEmpty {
                    errors.append("\(whereText)\(label)：缺少 name。改法：每个参数都要写 name: \"…\"。")
                }
                if (p["title"] as? String ?? "").isEmpty {
                    errors.append("\(whereText)\(label)：缺少 title。改法：补 title: \"…\"（参数标题，必填）。")
                }
                let type = p["type"] as? String ?? ""
                if type.isEmpty {
                    errors.append("\(whereText)\(label)：缺少 type。改法：补 type: \"input\" / \"enumeration\" / \"page\" 等。")
                }
                if let v = p["value"], !isStr(v) {
                    errors.append("\(whereText)\(label) 的 value：写成了 \(typeName(v))，应为字符串（数字也要加引号）。改法：改成 value: \"\(stringValue(v))\"。")
                }
                for key in ["enumOptions", "placeholders"] {
                    if let opts = p[key] as? [[String: Any]] {
                        for o in opts {
                            if let v = o["value"], !isStr(v) {
                                errors.append("\(whereText)\(label) 的 \(key)：有 value 写成了 \(typeName(v))，应为字符串。改法：改成 value: \"\(stringValue(v))\"。")
                            }
                        }
                    }
                }
                if type == "enumeration",
                   (p["enumOptions"] as? [[String: Any]] ?? []).isEmpty {
                    errors.append("\(whereText)\(label)：type 是 enumeration 但没有 enumOptions。改法：补 enumOptions: [{title, value}]，至少一项。")
                }
                if type == "constant", (p["value"] as? String ?? "").isEmpty {
                    errors.append("\(whereText)\(label)：type 是 constant 但没有写 value。改法：补 value: \"…\"（固定值必须显式写）。")
                }
                if type == "page", let sp = p["startPage"], !isNum(sp), !(sp is String) {
                    warnings.append("\(whereText)\(label) 的 startPage：应为整数。改法：改成 startPage: 0 或 1。")
                }
                if let b = p["belongTo"] {
                    let conds = (b as? [String: Any]).map { [$0] } ?? (b as? [[String: Any]] ?? [])
                    for c in conds {
                        let ref = c["paramName"] as? String ?? ""
                        let allNames = (modules.flatMap { ($0["params"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } })
                            + ((raw["globalParams"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
                        if !ref.isEmpty, !allNames.contains(ref) {
                            warnings.append("\(whereText)\(label) 的 belongTo：引用的参数 \"\(ref)\" 不存在。改法：改成已声明的参数名，否则该参数永远不显示。")
                        }
                    }
                }
            }
        }
        for m in modules {
            let mid = m["id"] as? String ?? ""
            let label = "入口「\(m["title"] as? String ?? mid)」"
            if (m["title"] as? String ?? "").isEmpty {
                errors.append("\(label)：缺少 title。改法：补 title: \"…\"（入口名称，必填）。")
            }
            if (m["functionName"] as? String ?? "").isEmpty {
                errors.append("\(label)：缺少 functionName。改法：补 functionName: \"…\"，指向文件里的顶层函数。")
            }
            if !mid.isEmpty {
                if seenIDs.contains(mid) {
                    errors.append("\(label)：id \"\(mid)\" 与另一个入口重复。改法：每个入口用稳定的唯一 id。")
                }
                seenIDs.insert(mid)
            }
            if let cd = m["cacheDuration"], !isNum(cd), !(cd is String) {
                warnings.append("\(label) 的 cacheDuration：应为秒数。改法：改成 cacheDuration: 86400 这类数字。")
            }
            checkParams(m["params"], where: "\(label)")
        }
        if let search = raw["search"] as? [String: Any] {
            if (search["functionName"] as? String ?? "").isEmpty {
                errors.append("搜索入口：缺少 functionName。改法：补 functionName: \"…\"，指向文件里的顶层搜索函数。")
            }
            checkParams(search["params"], where: "搜索入口")
        }
        checkParams(raw["globalParams"], where: "全局参数")
        return (errors, warnings)
    }

    private static func typeName(_ v: Any?) -> String {
        if let n = v as? NSNumber {
            // JSON booleans arrive as NSNumber too; tell them
            // apart by objCType ("c" = bool).
            return String(cString: n.objCType) == "c" ? "布尔值" : "数字"
        }
        if v is [Any] { return "数组" }
        if v is [String: Any] { return "对象" }
        return "其他类型"
    }

    private static func stringValue(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    func call(function: String, params: [String: Any], source: String) async throws -> Any? {
        let paramsJSON = (try? JSONSerialization.data(withJSONObject: params))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return try await callRaw(function: function, argumentJSON: paramsJSON, source: source)
    }

    /// loadDetail is the one handler that takes a bare string
    /// (the item's link), not a params object.
    func callString(function: String, argument: String, source: String) async throws -> Any? {
        let argumentJSON = (try? JSONSerialization.data(withJSONObject: [argument]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let inner = String(argumentJSON.dropFirst().dropLast())
        return try await callRaw(function: function, argumentJSON: inner, source: source)
    }

    private func callRaw(function: String, argumentJSON: String, source: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.callLocked(function: function, argumentJSON: argumentJSON, source: source)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: context

    private func makeContext(source: String) throws -> JSContext {
        guard let ctx = JSContext() else {
            throw FWDfailure(message: "JS 引擎创建失败")
        }
        lastException = nil
        ctx.exceptionHandler = { [weak self] _, exception in
            self?.lastException = exception?.toString() ?? "unknown JS error"
        }
        installNatives(ctx)
        for file in ["prelude.js", "cheerio.js"] {
            guard let url = Bundle.main.url(forResource: file, withExtension: nil,
                                            subdirectory: "JSBundle"),
                  let src = try? String(contentsOf: url, encoding: .utf8) else {
                throw FWDfailure(message: "JS 资源缺失：\(file)")
            }
            lastException = nil
            ctx.evaluateScript("(function(){\n" + src + "\n})();")
            if let lastException {
                throw FWDfailure(message: "引擎资源加载失败（\(file)）：\(lastException)", kind: .script)
            }
        }
        lastException = nil
        installShim(ctx)
        if let lastException {
            throw FWDfailure(message: "宿主接口安装失败：\(lastException)", kind: .script)
        }
        // v2.29 (guide i18n 章): the module's translation table
        // and the host's locale fallback list, read by the
        // shim's Widget.i18n at call time. Set AFTER the module
        // source runs (the table lives on WidgetMetadata) but
        // BEFORE any entry function is invoked, so entry code
        // always sees the real table.
        if let localesData = try? JSONSerialization.data(withJSONObject: fwdLocaleCandidates()),
           let localesText = String(data: localesData, encoding: .utf8) {
            ctx.evaluateScript("globalThis.__fwdLocales = \(localesText);")
        }
        lastException = nil
        ctx.evaluateScript(source)
        if let lastException {
            throw FWDfailure(message: "模块加载失败：\(lastException)", kind: .script)
        }
        ctx.evaluateScript("globalThis.__fwdI18nTable = (globalThis.WidgetMetadata && globalThis.WidgetMetadata.i18n) || {};")
        return ctx
    }

    private func metadataRawAndDetail(source: String) throws -> ([String: Any], Bool) {
        let ctx = try makeContext(source: source)
        guard let json = ctx.evaluateScript("JSON.stringify(globalThis.WidgetMetadata || null)")?.toString(),
              json != "null", json != "undefined",
              let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FWDfailure(message: "模块元数据读取失败", kind: .script)
        }
        let hasDetail = ctx.evaluateScript("typeof loadDetail === 'function'")?.toBool() ?? false
        return (raw, hasDetail)
    }

    private func parseMetadataLocked(source: String) throws -> FWDMeta {
        let (raw, hasDetail) = try metadataRawAndDetail(source: source)
        func str(_ d: [String: Any], _ key: String) -> String {
            if let s = d[key] as? String { return s }
            if let n = d[key] as? NSNumber { return n.stringValue }
            return ""
        }
        func params(_ list: [Any]?) -> [FWDParam] {
            (list as? [[String: Any]] ?? []).map { p in
                var desc = str(p, "description")
                if desc.isEmpty { desc = str(p, "placeholder") }
                // belongTo: one {paramName, value:[...]} object
                // or an array of them (all must hold, guide).
                var belongTo: [FWDBelongTo] = []
                func oneBelong(_ b: [String: Any]) {
                    let name = str(b, "paramName")
                    var values: [String] = []
                    if let arr = b["value"] as? [Any] {
                        values = arr.map { ($0 as? String) ?? (($0 as? NSNumber)?.stringValue ?? "") }
                            .filter { !$0.isEmpty }
                    } else if let s = b["value"] as? String, !s.isEmpty {
                        values = [s]
                    }
                    if !name.isEmpty, !values.isEmpty {
                        belongTo.append(FWDBelongTo(paramName: name, values: values))
                    }
                }
                if let b = p["belongTo"] as? [String: Any] { oneBelong(b) }
                else if let arr = p["belongTo"] as? [[String: Any]] { arr.forEach(oneBelong) }
                var startPage: Int? = nil
                if let n = p["startPage"] as? NSNumber { startPage = n.intValue }
                else if let s = p["startPage"] as? String, let n = Int(s) { startPage = n }
                return FWDParam(name: str(p, "name"), title: str(p, "title"),
                                type: str(p, "type").isEmpty ? "input" : str(p, "type"),
                                value: str(p, "value"),
                                enumOptions: (p["enumOptions"] as? [[String: Any]] ?? []).map {
                                    FWDOption(title: str($0, "title"), value: str($0, "value"))
                                },
                                desc: desc,
                                placeholders: (p["placeholders"] as? [[String: Any]] ?? []).map {
                                    FWDOption(title: str($0, "title"), value: str($0, "value"))
                                },
                                belongTo: belongTo, startPage: startPage)
            }
        }
        var meta = FWDMeta()
        meta.id = str(raw, "id")
        meta.title = str(raw, "title")
        meta.version = str(raw, "version")
        meta.author = str(raw, "author")
        meta.description = str(raw, "description")
        meta.site = str(raw, "site")
        meta.icon = str(raw, "iconurl").isEmpty
            ? (str(raw, "icon").isEmpty ? str(raw, "iconUrl") : str(raw, "icon"))
            : str(raw, "iconurl")
        meta.hasDetail = hasDetail
        // v2.26 (Rex guide): top-level metadata fields. Note
        // cacheDuration belongs on each ENTRY per the guide,
        // not on top — the old top-level read is gone; the
        // legacy meta.cacheDuration stays 0 for new imports.
        meta.requiredVersion = str(raw, "requiredVersion")
        meta.contentType = str(raw, "contentType")
        if let n = raw["detailCacheDuration"] as? NSNumber {
            meta.detailCacheDuration = max(0, n.intValue)
        } else if let s = raw["detailCacheDuration"] as? String,
                  let n = Int(s) {
            meta.detailCacheDuration = max(0, n)
        }
        if let b = raw["continuousPlay"] as? Bool { meta.continuousPlay = b }
        if let dict = raw["i18n"] as? [String: [String: Any]] {
            var out: [String: [String: String]] = [:]
            for (lang, table) in dict {
                var row: [String: String] = [:]
                for (k, v) in table {
                    if let s = v as? String { row[k] = s }
                    else if let n = v as? NSNumber { row[k] = n.stringValue }
                }
                out[lang] = row
            }
            meta.i18n = out
        }
        meta.globalParams = params(raw["globalParams"] as? [Any])
        meta.modules = (raw["modules"] as? [[String: Any]] ?? []).map { m in
            var entry = FWDModuleEntry(id: str(m, "id"), title: str(m, "title"),
                                       functionName: str(m, "functionName"),
                                       type: str(m, "type"), params: params(m["params"] as? [Any]))
            entry.subtitle = str(m, "subtitle")
            entry.iconurl = str(m, "iconurl").isEmpty
                ? (str(m, "iconUrl").isEmpty ? str(m, "iconURL") : str(m, "iconUrl"))
                : str(m, "iconurl")
            if let n = m["cacheDuration"] as? NSNumber {
                entry.cacheDuration = max(0, n.intValue)
            } else if let s = m["cacheDuration"] as? String, let n = Int(s) {
                entry.cacheDuration = max(0, n)
            }
            return entry
        }
        if let search = raw["search"] as? [String: Any] {
            meta.searchFunction = str(search, "functionName")
            meta.searchParams = params(search["params"] as? [Any])
        }
        return meta
    }

    private func callLocked(function: String, argumentJSON: String, source: String) throws -> Any? {
        let ctx = try makeContext(source: source)
        var settled = false
        var errorText: String?
        var jsonText: String?
        let settle: @convention(block) (String?, String?) -> Void = { err, json in
            errorText = err
            jsonText = json
            settled = true
        }
        ctx.setObject(settle, forKeyedSubscript: "__fwdSettle" as NSString)
        func jsString(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let text = String(data: data, encoding: .utf8) else { return "\"\"" }
            return String(text.dropFirst().dropLast())
        }
        lastException = nil
        ctx.evaluateScript("""
        (function() {
          var fn = globalThis[\(jsString(function))];
          if (typeof fn !== 'function') { __fwdSettle('模块缺少函数 ' + \(jsString(function)), null); return; }
          Promise.resolve().then(function() { return fn(\(argumentJSON)); }).then(
            function(r) {
              try { __fwdSettle(null, JSON.stringify(r === undefined ? null : r)); }
              catch (e) { __fwdSettle('模块结果序列化失败：' + String((e && e.message) || e), null); }
            },
            function(e) { __fwdSettle(String((e && e.message) || e), null); });
        })();
        """)
        // A synchronous throw in the wrapper (bad argument JSON,
        // a poisoned context) reaches the exception handler, not
        // the promise — fail fast with it instead of pumping the
        // full 30 s into a misleading timeout.
        if !settled, let lastException {
            throw FWDfailure(message: lastException, kind: .script)
        }
        // Handlers await Widget.http, which is a synchronous native
        // value here, so every continuation is a promise job. Drain
        // BOTH ways JavaScriptCore schedules those jobs: script
        // evaluations (microtask checkpoint at unwind) and run-loop
        // turns (the VM's job queue is also serviced there), plus
        // the prelude's timer drain for modules using setTimeout.
        // 60 s since v1.77: drive-aggregation modules fan out to
        // many sources with sequential fetches and legitimately
        // need more room than catalogue modules do.
        // v2.01 pump hardening: the prelude's timer drain swallows
        // a throwing timer callback (it only logs it), so without
        // a probe the call would pump the full 60 s and report a
        // misleading timeout. The prelude now records the first
        // timer error in __timerError and the queue depth in
        // __timersPending: fail fast once an error is recorded
        // and no timers are left that could still settle the
        // promise; otherwise keep pumping, and surface the
        // recorded error inside the timeout message. A JS
        // exception landing mid-pump fails fast the same way.
        // (One hard limit stays: a timer callback stuck in an
        // infinite loop never returns from evaluateScript, so no
        // deadline can fire — synchronous JS by design.)
        let deadline = Date().addingTimeInterval(60)
        var pumpTick = 0
        while !settled && Date() < deadline {
            ctx.evaluateScript("0")
            ctx.evaluateScript("if (typeof __drainTimers === 'function') { __drainTimers(); }")
            if !settled, let lastException {
                throw FWDfailure(message: lastException, kind: .script)
            }
            pumpTick += 1
            if !settled, pumpTick % 20 == 0,
               let timerError = FWDRuntime.timerErrorText(ctx), !timerError.isEmpty,
               FWDRuntime.timersPending(ctx) == 0 {
                throw FWDfailure(message: "定时器回调异常：\(timerError)", kind: .script)
            }
            if !RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005)) {
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        if let errorText {
            throw FWDfailure(message: errorText, kind: FWDfailure.classifyModuleError(errorText))
        }
        guard settled, let jsonText, let data = jsonText.data(using: .utf8) else {
            // Self-diagnosing timeout: report what the context
            // actually holds, so a dead runtime names its cause.
            let probe = ctx.evaluateScript("""
            JSON.stringify({
              fn: typeof globalThis[\(jsString(function))],
              widget: typeof globalThis.Widget,
              meta: typeof globalThis.WidgetMetadata
            })
            """)?.toString() ?? "?"
            let extra = lastException.map { "；最近异常：\($0)" } ?? ""
            let timerExtra = FWDRuntime.timerErrorText(ctx)
                .map { "；定时器异常：\($0)" } ?? ""
            throw FWDfailure(message: "模块调用超时（60 秒）[\(probe)]\(extra)\(timerExtra)",
                             kind: .timeout)
        }
        if jsonText == "null" { return nil }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// First timer-callback error recorded by the prelude's
    /// __drainTimers (v2.01), if any. Nil when no timer has
    /// thrown in this context.
    private static func timerErrorText(_ ctx: JSContext) -> String? {
        guard let text = ctx.evaluateScript(
            "typeof globalThis.__timerError === 'string' ? globalThis.__timerError : ''"
        )?.toString(), !text.isEmpty else { return nil }
        return text
    }

    /// Timers still queued in the prelude shim (v2.01). -1 when
    /// the prelude never installed the shim (older bundle /
    /// unexpected context) — callers treat that as unknown.
    private static func timersPending(_ ctx: JSContext) -> Int {
        guard let value = ctx.evaluateScript(
            "typeof globalThis.__timersPending === 'number' ? globalThis.__timersPending : -1"
        ) else { return -1 }
        return Int(value.toInt32())
    }

    // MARK: natives

    private func installNatives(_ ctx: JSContext) {
        let logBlock: @convention(block) (String) -> Void = { message in
            Diagnostics.log("模块", message)
        }
        ctx.setObject(logBlock, forKeyedSubscript: "__fwdLog" as NSString)

        let httpBlock: @convention(block) (String, String, String, String) -> String = { method, url, body, optionsJSON in
            FWDRuntime.httpResponse(method: method, urlString: url, body: body, optionsJSON: optionsJSON)
        }
        ctx.setObject(httpBlock, forKeyedSubscript: "__fwdHttp" as NSString)

        let tmdbBlock: @convention(block) (String, String) -> String = { path, paramsJSON in
            FWDRuntime.tmdbResponse(path: path, paramsJSON: paramsJSON)
        }
        ctx.setObject(tmdbBlock, forKeyedSubscript: "__fwdTmdbGet" as NSString)

        let widgetID = self.widgetID
        let storageGet: @convention(block) (String) -> JSValue? = { key in
            guard let ctx = JSContext.current() else { return nil }
            if let value = FWDRuntime.kvGet(store: "fwd.storage.\(widgetID)", key: key) {
                return JSValue(object: value, in: ctx)
            }
            return JSValue(nullIn: ctx)
        }
        ctx.setObject(storageGet, forKeyedSubscript: "__fwdStorageGet" as NSString)
        let storageSet: @convention(block) (String, String) -> Void = { key, value in
            FWDRuntime.kvSet(store: "fwd.storage.\(widgetID)", key: key, value: value)
        }
        ctx.setObject(storageSet, forKeyedSubscript: "__fwdStorageSet" as NSString)
        let storageRemove: @convention(block) (String) -> Void = { key in
            FWDRuntime.kvSet(store: "fwd.storage.\(widgetID)", key: key, value: nil)
        }
        ctx.setObject(storageRemove, forKeyedSubscript: "__fwdStorageRemove" as NSString)

        let cacheGet: @convention(block) (String, String) -> JSValue? = { ns, key in
            guard let ctx = JSContext.current() else { return nil }
            if let value = FWDRuntime.kvGet(store: "fwd.sharedcache.v1", key: ns + "\u{1}" + key) {
                return JSValue(object: value, in: ctx)
            }
            return JSValue(nullIn: ctx)
        }
        ctx.setObject(cacheGet, forKeyedSubscript: "__fwdCacheGet" as NSString)
        let cacheSet: @convention(block) (String, String, String) -> Void = { ns, key, value in
            FWDRuntime.kvSet(store: "fwd.sharedcache.v1", key: ns + "\u{1}" + key, value: value)
        }
        ctx.setObject(cacheSet, forKeyedSubscript: "__fwdCacheSet" as NSString)
        let cacheRemove: @convention(block) (String, String) -> Void = { ns, key in
            FWDRuntime.kvSet(store: "fwd.sharedcache.v1", key: ns + "\u{1}" + key, value: nil)
        }
        ctx.setObject(cacheRemove, forKeyedSubscript: "__fwdCacheRemove" as NSString)
    }

    private func installShim(_ ctx: JSContext) {
        ctx.evaluateScript("""
        globalThis.console = (function() {
            function fmt(args) {
                var parts = [];
                for (var i = 0; i < args.length; i++) {
                    var a = args[i];
                    try { parts.push(typeof a === 'object' ? JSON.stringify(a) : String(a)); }
                    catch (e) { parts.push('[object]'); }
                }
                return parts.join(' ');
            }
            return {
                log: function() { __fwdLog(fmt(arguments)); },
                error: function() { __fwdLog(fmt(arguments)); },
                warn: function() { __fwdLog(fmt(arguments)); },
                info: function() { __fwdLog(fmt(arguments)); }
            };
        })();
        globalThis.Widget = (function() {
            function httpReq(method, url, body, options) {
                var raw = __fwdHttp(method, String(url), body == null ? '' : String(body),
                                    JSON.stringify(options || {}));
                return JSON.parse(raw);
            }
            var docs = {};
            var docSeq = 0;
            return {
                http: {
                    get: function(url, options) { return httpReq('GET', url, '', options); },
                    post: function(url, body, options) {
                        var b = '';
                        if (body !== undefined && body !== null) {
                            b = (typeof body === 'string') ? body : JSON.stringify(body);
                        }
                        return httpReq('POST', url, b, options);
                    }
                },
                tmdb: {
                    get: function(path, params) {
                        var r = JSON.parse(__fwdTmdbGet(String(path), JSON.stringify(params || {})));
                        // A TMDB-shaped error object (no key, bad
                        // key, no response) is NOT data: the
                        // module would read r.results (undefined)
                        // and die with a cryptic TypeError. Throw
                        // the Chinese status_message instead, so
                        // the column fails with a readable cause
                        // (v2.06). Real TMDB payloads carry no
                        // `success` field, so this never fires on
                        // good data.
                        if (r && r.success === false) {
                            throw new Error(r.status_message || 'TMDB 请求失败');
                        }
                        return r;
                    }
                },
                html: {
                    load: function(html) { return cheerio.load(String(html == null ? '' : html)); }
                },
                dom: {
                    parse: function(html) {
                        var id = ++docSeq;
                        docs[id] = cheerio.load(String(html == null ? '' : html));
                        return id;
                    },
                    select: function(docId, selector) {
                        var $ = docs[docId];
                        if (!$) return [];
                        var out = [];
                        $(selector).each(function(i, el) {
                            var $el = $(el);
                            out.push({ tagName: el.tagName || '', attribs: el.attribs || {},
                                       text: $el.text(), html: $el.html() || '' });
                        });
                        return out;
                    }
                },
                storage: {
                    get: function(k) { var s = __fwdStorageGet(String(k)); return s == null ? null : JSON.parse(s); },
                    set: function(k, v) { __fwdStorageSet(String(k), JSON.stringify(v === undefined ? null : v)); },
                    remove: function(k) { __fwdStorageRemove(String(k)); }
                },
                sharedCache: {
                    get: function(ns, k) { var s = __fwdCacheGet(String(ns), String(k)); return s == null ? null : JSON.parse(s); },
                    set: function(ns, k, v) { __fwdCacheSet(String(ns), String(k), JSON.stringify(v === undefined ? null : v)); },
                    remove: function(ns, k) { __fwdCacheRemove(String(ns), String(k)); }
                },
                // v2.29 (guide i18n 章): Widget.i18n("文案") looks
                // the string up in WidgetMetadata.i18n, same order
                // as the host's fwdLocalized — exact locale code,
                // then script system, then base language — and
                // returns the original text when nothing matches.
                // __fwdI18nTable / __fwdLocales are set by the
                // host right after the module source is evaluated.
                i18n: function(s) {
                    var text = String(s == null ? '' : s);
                    var table = globalThis.__fwdI18nTable || {};
                    var locales = globalThis.__fwdLocales || [];
                    function norm(k) { return String(k).toLowerCase().replace(/_/g, '-'); }
                    var byNorm = {};
                    Object.keys(table).forEach(function(k) { byNorm[norm(k)] = table[k]; });
                    for (var i = 0; i < locales.length; i++) {
                        var row = byNorm[norm(locales[i])];
                        if (row && row[text]) return row[text];
                    }
                    return text;
                }
            };
        })();
        """)
    }

    // MARK: storage + transport helpers

    private static func kvGet(store: String, key: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: store) as? [String: String])?[key]
    }

    private static func kvSet(store: String, key: String, value: String?) {
        var dict = (UserDefaults.standard.dictionary(forKey: store) as? [String: String]) ?? [:]
        if let value { dict[key] = value } else { dict.removeValue(forKey: key) }
        UserDefaults.standard.set(dict, forKey: store)
    }

    /// Widget.tmdb.get: TMDB API through the user's own key
    /// (Settings → TMDB). Returns the raw JSON body, or a
    /// TMDB-shaped error object when no key is configured.
    private static func tmdbResponse(path: String, paramsJSON: String) -> String {
        let key = (UserDefaults.standard.string(forKey: "tmdb.key") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return "{\"success\":false,\"status_code\":7,\"status_message\":\"未配置 TMDB 密钥（设置 → TMDB）\"}"
        }
        var params: [String: Any] = [:]
        if let data = paramsJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            params = parsed
        }
        // Forward's own convention (and what Rex's official TMDB
        // module passes) is Widget.tmdb.get(path, { params: {...} }):
        // unwrap the inner params dict, or every real query value
        // (page, with_genres, sort_by…) is lost and a junk
        // "params=<dict dump>" item goes out instead.
        if let inner = params["params"] as? [String: Any] {
            params = inner
        }
        // Honor the user's configured API base (Settings → TMDB)
        // so module TMDB calls take the same route as the app —
        // official host or the JarProxy forward (v1.75).
        let baseRaw = (UserDefaults.standard.string(forKey: "tmdb.base") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let apiBase = baseRaw.isEmpty ? "https://api.themoviedb.org" : baseRaw
        let fullPath = path.hasPrefix("/3/") ? path
            : ("/3" + (path.hasPrefix("/") ? path : "/" + path))
        guard var comps = URLComponents(string: apiBase + fullPath) else {
            return "{\"success\":false,\"status_message\":\"TMDB 地址无效\"}"
        }
        var query: [URLQueryItem] = [URLQueryItem(name: "api_key", value: key),
                                     URLQueryItem(name: "language", value: "zh-CN")]
        for (k, v) in params where k != "api_key" && k != "language" {
            query.append(URLQueryItem(name: k, value: String(describing: v)))
        }
        comps.queryItems = query
        guard let url = comps.url else {
            return "{\"success\":false,\"status_message\":\"TMDB 路径无效\"}"
        }
        func fetchJSON(_ u: URL) -> String? {
            let r = JSRuntime.syncFetch(urlString: u.absoluteString,
                                        obj: ["method": "GET", "timeout": 12000])
            let c = (r["content"] as? String) ?? ""
            guard let d = c.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: d)) != nil else { return nil }
            return c
        }
        if let content = fetchJSON(url) { return content }
        // The configured route did not answer (themoviedb.org is
        // unreachable on many networks): one retry through the
        // user's own JarProxy forward, so module TMDB columns
        // work with zero setup (v1.76).
        if apiBase != TMDBClient.forwardBase,
           var alt = URLComponents(string: TMDBClient.forwardBase + fullPath) {
            alt.queryItems = query
            if let u = alt.url, let content = fetchJSON(u) { return content }
        }
        return "{\"success\":false,\"status_message\":\"TMDB 无响应\"}"
    }

    /// One synchronous HTTP round trip shaped for Widget.http:
    /// returns a JSON string {data, status, statusCode, headers};
    /// data is the parsed JSON value when the body parses as JSON,
    /// otherwise the raw text. v2.00: status/statusCode are the
    /// REAL HTTP status from the transport (syncFetch), and
    /// headers are the real response headers — previously both
    /// were a hardcoded 200 / whatever the transport happened
    /// to return, so modules could not tell a 404/403/Cloudflare
    /// challenge from a success. status 0 + "error" means the
    /// request never got a response (network failure); data is
    /// still the body when the server answered with one (e.g. a
    /// 404 JSON error), so existing modules keep working.
    /// v2.01: the per-request timeout is capped at 20 s (the
    /// 60 s call budget is untouched) and a timed-out request
    /// additionally reports timedOut=true with a Chinese
    /// "子请求超时（20 秒）" error, distinct from other
    /// transport failures.
    /// v2.07 fetch-compat: the transport options syncFetch
    /// already understands — encoding (gbk…), buffer (2 =
    /// base64 body), redirect (0 = don't follow) and a form
    /// `data` dict — are now forwarded instead of silently
    /// dropped; `url` reports the final URL after redirects;
    /// query/form values are percent-encoded with & = + ? kept
    /// out, so one value can no longer split into several
    /// parameters.
    private static func httpResponse(method: String, urlString: String,
                                     body: String, optionsJSON: String) -> String {
        var options: [String: Any] = [:]
        if let data = optionsJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            options = parsed
        }
        // Query values must not carry & = + ? raw, or one value
        // splits into several parameters (v2.07).
        let valueAllowed = CharacterSet.urlQueryAllowed
            .subtracting(CharacterSet(charactersIn: "&=+?"))
        var url = urlString
        if let params = options["params"] as? [String: Any], !params.isEmpty {
            let query = params.map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? key
                let v = String(describing: value)
                    .addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? ""
                return "\(k)=\(v)"
            }.joined(separator: "&")
            url += (url.contains("?") ? "&" : "?") + query
        }
        var obj: [AnyHashable: Any] = ["method": method]
        // v2.01 sub-request timeout layering: one request may
        // take at most 20 s — the number is unchanged, but it is
        // now enforced as a cap (a module asking for more must
        // not eat the whole 60 s call budget) and its failure is
        // reported separately from other transport failures.
        let requestedMs = (options["timeout"] as? NSNumber)?.doubleValue ?? 20000
        obj["timeout"] = min(max(requestedMs, 1000), 20000)
        if let headers = options["headers"] as? [String: Any] {
            obj["headers"] = headers
        }
        // v2.07: forward the transport options the module asked
        // for — encoding, buffer and redirect used to be dropped
        // here, so gbk pages decoded as mojibake and redirect: 0
        // was silently ignored.
        if let encoding = options["encoding"] as? String { obj["encoding"] = encoding }
        if let buffer = options["buffer"] as? NSNumber { obj["buffer"] = buffer }
        if let redirect = options["redirect"] as? NSNumber { obj["redirect"] = redirect }
        if method == "POST" {
            if !body.isEmpty {
                obj["body"] = body
                let headers = (obj["headers"] as? [String: Any]) ?? [:]
                if headers.keys.first(where: { $0.lowercased() == "content-type" }) == nil {
                    var h = headers
                    h["Content-Type"] = "application/json"
                    obj["headers"] = h
                }
            } else if let data = options["data"] as? [String: Any], !data.isEmpty {
                // Form POST: {data: {k: v}} → url-encoded body.
                // syncFetch sets the form Content-Type when the
                // caller didn't set one (v2.07).
                obj["data"] = data
            } else if let data = options["data"] as? String, !data.isEmpty {
                // v2.19: form data passed as a pre-encoded string
                // ("a=1&b=2") used to be dropped here — only the
                // dict shape was forwarded. Send it through as-is;
                // syncFetch puts a String data straight into the
                // request body.
                obj["data"] = data
            }
        }
        let result = JSRuntime.syncFetch(urlString: url, obj: obj)
        let content = (result["content"] as? String) ?? ""
        let headers = (result["headers"] as? [String: String]) ?? [:]
        let status = (result["status"] as? NSNumber)?.intValue ?? 0
        var dataValue: Any = content
        if let data = content.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            dataValue = parsed
        }
        // v2.19: headers keep the server's casing ("Set-Cookie",
        // "Location"), so a module reading headers["set-cookie"]
        // or headers["location"] lowercase missed them. Ship a
        // lowercase copy of every header alongside the original,
        // so both casings read. The same gap hid multi-value
        // Set-Cookie (allHeaderFields comma-joins them, and the
        // commas inside Expires= dates corrupt the split), so
        // also expose the parsed cookies for the final URL:
        // URLSession already stored them in the shared jar and
        // sends them on later requests — `cookies` just makes
        // them visible to modules that forward cookies by hand.
        var headersOut: [String: String] = headers
        for (key, value) in headers {
            let lower = key.lowercased()
            if headersOut[lower] == nil { headersOut[lower] = value }
        }
        var response: [String: Any] = ["data": dataValue, "status": status,
                                       "statusCode": status, "headers": headersOut]
        if let finalURLString = result["url"] as? String,
           let finalURL = URL(string: finalURLString),
           let cookies = HTTPCookieStorage.shared.cookies(for: finalURL),
           !cookies.isEmpty {
            response["cookies"] = cookies.map { "\($0.name)=\($0.value)" }
        }
        // v2.07: the final URL after redirects, so a module can
        // tell where it actually landed (e.g. a login wall).
        if let finalURL = result["url"] as? String, !finalURL.isEmpty {
            response["url"] = finalURL
        }
        // v2.01: a timed-out sub-request is a distinct outcome —
        // timedOut + a Chinese message naming the 20 s cap — so
        // a module (and the FWDfailure classifier) can tell a
        // slow source from a dead network. Other transport
        // failures keep the Chinese error syncFetch mapped.
        if (result["timedOut"] as? NSNumber)?.boolValue == true {
            response["timedOut"] = true
            response["error"] = "子请求超时（20 秒）：\(URL(string: url)?.host ?? url)"
        } else if let error = result["error"] as? String, !error.isEmpty {
            response["error"] = error
        }
        guard let data = try? JSONSerialization.data(withJSONObject: response),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"data\":\"\",\"status\":\(status),\"statusCode\":\(status),\"headers\":{}}"
        }
        return text
    }
}

// MARK: - Danmu modules (v1.61)

/// Forward danmu modules, per the Rex guide 0.0.7 弹幕章
/// (v2.28 rewrite — the v1.61 flow skipped a step):
///   1. searchDanmu(params) → {animes:[{animeId…}]}; a
///      module may answer with danmu directly instead.
///   2. getDetail(params + animeId) → [{episodeId,
///      episodeTitle, episodeNumber}]; match by episode
///      number, else take the first episode. The episodeId
///      (a string or integer, never a list index) becomes
///      commentId — the old code passed the ANIME id as
///      commentId, so episode matching never happened.
///   3. getComments(params + animeId + commentId) →
///      {comments:[{p, m}]} (or a bare [{p,m}] array,
///      {danmuku:[[time, pos, color, "", text]]}, or XML).
///   4. getCommentsWithSegmentTime(params + commentId +
///      segmentTime) — segmented loading; probed at 0.
/// Params follow the guide's playback-context table (all
/// strings, missing fields not passed; `title` is sent
/// because this is a danmu entry). animeId prefers
/// bangumiId, then animeId. Legacy ids getCommentsById /
/// getDanmuWithSegmentTime are still accepted as fallbacks
/// for modules written against the older Forward spec.
enum FWDDanmu {
    static func entries(for meta: FWDMeta) -> [FWDModuleEntry] {
        meta.modules.filter {
            $0.type == "danmu"
            || $0.id == "searchDanmu" || $0.id == "getDetail" || $0.id == "getComments"
            || $0.id == "getCommentsWithSegmentTime"
            || $0.id == "getCommentsById" || $0.id == "getDanmuWithSegmentTime"
        }
    }

    static func hasDanmu(_ meta: FWDMeta) -> Bool { !entries(for: meta).isEmpty }

    /// Fetch one episode's danmaku from the SAME package's danmu
    /// modules, following the guide's three-step chain. Returns
    /// raw JSON data for DanmakuStore.load, or nil when the
    /// package has no danmu modules / nothing matched.
    /// `seriesTitle` is the show title when `item` is one
    /// episode; nil when `item` is itself the single title
    /// being played (movie / single video).
    static func fetch(record: FWDRecord, item: FWDItem, episodeIndex: Int,
                      seriesTitle: String? = nil) async -> Data? {
        guard let source = FWDStore.source(for: record) else { return nil }
        let meta = record.meta
        let entries = entries(for: meta)
        guard !entries.isEmpty else { return nil }
        let runtime = FWDRuntime(widgetID: record.id)
        let epNo = item.episode ?? (episodeIndex + 1)
        let episodeName = seriesTitle == nil ? nil : item.title
        var params = FWDPlaybackContext.build(item: item, seriesTitle: seriesTitle,
                                              episodeName: episodeName, includeTitle: true,
                                              episodeFallback: epNo)
        params["videoUrl"] = item.videoUrl
        params = FWDPlaybackContext.withGlobals(params, meta: meta)

        func entry(id: String, fn: String) -> FWDModuleEntry? {
            entries.first { $0.id == id } ?? entries.first { $0.functionName == fn }
        }
        // 1. searchDanmu: match the title to a danmu-side id.
        // Some modules answer with danmu directly — take it.
        var matchedID: String?
        if let search = entry(id: "searchDanmu", fn: "searchDanmu") {
            if let result = try? await runtime.call(function: search.functionName,
                                                    params: params, source: source) {
                if let data = danmuData(from: result) { return data }
                matchedID = matchID(from: result)
            }
        }
        guard let animeID = matchedID else { return nil }
        // 2. getDetail: episodes for the matched anime; match
        // by episode number (as a string), else first episode.
        // Without a getDetail entry, fall back to the anime id
        // as commentId (legacy modules without episode lists).
        var commentID = animeID
        if let detail = entry(id: "getDetail", fn: "getDetail") ?? entry(id: "getDetail", fn: "findEpisodes") {
            var p2 = params
            p2["animeId"] = animeID
            if let result = try? await runtime.call(function: detail.functionName,
                                                    params: p2, source: source),
               let episodes = result as? [[String: Any]], !episodes.isEmpty {
                let wanted = String(epNo)
                let pick = episodes.first {
                    let n = ($0["episodeNumber"] as? String) ?? (($0["episodeNumber"] as? NSNumber)?.stringValue ?? "")
                    return n == wanted
                } ?? episodes[0]
                if let s = pick["episodeId"] as? String, !s.isEmpty { commentID = s }
                else if let n = pick["episodeId"] as? NSNumber { commentID = n.stringValue }
            }
        }
        // 3. getComments: the episode's comments.
        if let comments = entry(id: "getComments", fn: "getComments")
            ?? entry(id: "getComments", fn: "getCommentsById") {
            var p3 = params
            p3["animeId"] = animeID
            p3["commentId"] = commentID
            if let result = try? await runtime.call(function: comments.functionName,
                                                    params: p3, source: source),
               let data = danmuData(from: result) { return data }
        }
        // 4. Segment fetch (optional): one probe at segment 0.
        if let segment = entry(id: "getCommentsWithSegmentTime", fn: "getCommentsWithSegmentTime")
            ?? entry(id: "getDanmuWithSegmentTime", fn: "getDanmuWithSegmentTime") {
            var p4 = params
            p4["animeId"] = animeID
            p4["commentId"] = commentID
            p4["segmentTime"] = "0"
            if let result = try? await runtime.call(function: segment.functionName,
                                                    params: p4, source: source),
               let data = danmuData(from: result) { return data }
        }
        return nil
    }

    /// Serialize a danmu-shaped module result to JSON data, or
    /// nil when it is a search match list / metadata instead.
    private static func danmuData(from result: Any?) -> Data? {
        if let text = result as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return Data(text.utf8)
        }
        if let array = result as? [[String: Any]], let first = array.first,
           isDanmuDict(first) {
            return try? JSONSerialization.data(withJSONObject: array)
        }
        if let array = result as? [[Any]], let first = array.first,
           first.count >= 5, first[0] is NSNumber || first[0] is String {
            return try? JSONSerialization.data(withJSONObject: array)
        }
        if let dict = result as? [String: Any] {
            for key in ["comments", "danmu", "data", "danmuku"] {
                if let nested = dict[key], let data = danmuData(from: nested) { return data }
            }
        }
        return nil
    }

    private static func isDanmuDict(_ obj: [String: Any]) -> Bool {
        if obj["p"] is String, obj["m"] is String { return true }
        let hasTime = obj["time"] != nil || obj["t"] != nil
        let hasText = obj["text"] is String || obj["content"] is String || obj["m"] is String
        return hasTime && hasText
    }

    /// Pull the danmu-side id out of a searchDanmu result:
    /// {animes:[{bangumiId…}]} / {data:[…]} / a bare array.
    private static func matchID(from result: Any?) -> String? {
        func id(of obj: [String: Any]) -> String? {
            for key in ["bangumiId", "animeId", "commentId", "id"] {
                if let s = obj[key] as? String, !s.isEmpty { return s }
                if let n = obj[key] as? NSNumber { return n.stringValue }
            }
            return nil
        }
        if let array = result as? [[String: Any]], let first = array.first {
            return id(of: first)
        }
        if let dict = result as? [String: Any] {
            for key in ["animes", "data", "results", "list", "items"] {
                if let array = dict[key] as? [[String: Any]], let first = array.first {
                    return id(of: first)
                }
            }
            return id(of: dict)
        }
        return nil
    }
}

// MARK: - Official module catalog (v2.02)

/// Built-in directory for the two official Rex modules, so the
/// module page shows something useful before anything is
/// downloaded (ReelFlow keeps the same idea: its RexWidgetCatalog
/// lists official modules with full metadata first, download
/// second). The metadata below is the live WidgetMetadata of the
/// files at the two URLs, verified 2026-11-20 against the
/// official downloads (bangumi 5 columns, rex-tmdb 12 columns).
/// The app downloads the .js from the URL at tap time, so a newer
/// upstream version still imports with its own metadata;
/// importModule replaces a same-id record, so re-downloads never
/// duplicate.
struct FWDCatalogEntry: Identifiable {
    var id: String
    var title: String
    var version: String
    var author: String
    var description: String
    var url: String
    var columnCount: Int
    var icon: String
    /// rex-tmdb calls Widget.tmdb.get, which needs the user's own
    /// TMDB key; without one its tmdb-backed columns fail (known
    /// since v1.74), so the card says so up front.
    var requiresTMDBKey: Bool
}

enum FWDCatalog {
    static let entries: [FWDCatalogEntry] = [
        FWDCatalogEntry(
            id: "rex.tmdb",
            title: "Rex TMDB",
            version: "1.2.4",
            author: "Rex",
            description: "Rex 官方影视数据模块，提供 TMDB 榜单、片单、分类及按语言更新的地区剧集与综艺",
            url: "https://assets.rexnow.tv/scripts/rex-tmdb.js",
            columnCount: 12,
            icon: "https://assets.rexnow.tv/scripts/rex-icon.png",
            requiresTMDBKey: true
        ),
        FWDCatalogEntry(
            id: "rex.bangumi",
            title: "动漫数据",
            version: "1.0.1",
            author: "Rex",
            description: "Rex 动漫数据模块，提供每日放送、近期热门、排行榜、年度新番与分类浏览",
            url: "https://assets.rexnow.tv/scripts/bangumi.js",
            columnCount: 5,
            icon: "https://assets.rexnow.tv/scripts/rex-icon.png",
            requiresTMDBKey: false
        ),
        // v2.29: the three official guide examples, so they can
        // be imported in one tap and then covered by the same
        // self-check as any other module (R4: five modules,
        // one regression table).
        FWDCatalogEntry(
            id: "rex.example.music",
            title: "音乐目录示例",
            version: "1.3.0",
            author: "Rex",
            description: "官方音乐模块示例：专辑（tracks/兼容双格式）、歌单、流派、电台、歌手；离线数据可直接跑",
            url: "https://modules.rexnow.app/examples/music-demo.js",
            columnCount: 8,
            icon: "https://assets.rexnow.tv/scripts/rex-icon.png",
            requiresTMDBKey: false
        ),
        FWDCatalogEntry(
            id: "rex.example.tmdb",
            title: "TMDB 发现示例",
            version: "1.0.0",
            author: "Rex",
            description: "官方 TMDB 示例：热门电影、独立详情与关键词搜索；自带 en 多语言词典",
            url: "https://modules.rexnow.app/examples/tmdb.js",
            columnCount: 1,
            icon: "https://assets.rexnow.tv/scripts/rex-icon.png",
            requiresTMDBKey: true
        ),
        FWDCatalogEntry(
            id: "rex.example.danmu",
            title: "弹幕三段链示例",
            version: "1.0.0",
            author: "Rex",
            description: "官方弹幕示例：搜索番剧 → 加载分集 → 加载弹幕；默认离线 fixtures",
            url: "https://modules.rexnow.app/examples/danmu.js",
            columnCount: 3,
            icon: "https://assets.rexnow.tv/scripts/rex-icon.png",
            requiresTMDBKey: false
        ),
    ]

    /// Entries not yet imported (matched by module id).
    static func pending(importedIDs: Set<String>) -> [FWDCatalogEntry] {
        entries.filter { !importedIDs.contains($0.id) }
    }
}

// MARK: - Modules home

struct ModulesView: View {
    @State private var records: [FWDRecord] = []
    @State private var showFileImporter = false
    @State private var showURLImporter = false
    @State private var importURL = ""
    @State private var note: String?
    @State private var importing = false
    @State private var checking = false
    @State private var checkLines: [String] = []
    @State private var checkVersion = 0
    @State private var downloadingCatalogID: String?

    /// Catalog entries not yet imported (matched by module id).
    private var pendingCatalog: [FWDCatalogEntry] {
        FWDCatalog.pending(importedIDs: Set(records.map(\.id)))
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Button {
                        Haptics.tap()
                        showFileImporter = true
                    } label: {
                        Label("导入文件", systemImage: "doc.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Theme.glass, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        Haptics.tap()
                        importURL = ""
                        showURLImporter = true
                    } label: {
                        Label("导入链接", systemImage: "link.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Theme.glass, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    if importing { ProgressView().tint(Theme.text) }
                }
                HStack(spacing: 10) {
                    Button {
                        Haptics.tap()
                        importing = true
                        Task {
                            defer { importing = false }
                            var count = 0
                            for url in ["https://assets.rexnow.tv/scripts/rex-tmdb.js",
                                        "https://assets.rexnow.tv/scripts/bangumi.js"] {
                                if (try? await FWDStore.importRemote(url)) != nil { count += 1 }
                            }
                            note = count > 0 ? "已导入 Rex 官方模块 \(count) 个"
                                             : "Rex 官方模块导入失败，检查网络后重试"
                            records = FWDStore.records()
                        }
                    } label: {
                        Label("导入 Rex 官方模块", systemImage: "star.square.on.square")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Theme.glass, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        Haptics.tap()
                        Task { await runSelfCheck() }
                    } label: {
                        Label(checking ? "自检中…" : "模块自检", systemImage: "stethoscope")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Theme.glass, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(checking)
                }
                // v2.09: 播出日历入口 —— bangumi 每日放送的周视图
                // （今天 + 周一…周日）；模块没导入时日历页只给
                // 导入指引，不编造数据。
                NavigationLink {
                    BroadcastCalendarView()
                } label: {
                    Label("播出日历", systemImage: "calendar")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Theme.glass, in: Capsule())
                }
                .buttonStyle(.plain)
                // v2.02: official-module directory. Entries not
                // yet imported show as cards with metadata first
                // and a one-tap download; imported ones disappear
                // from the directory (they are in the list below).
                if !pendingCatalog.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("官方模块目录")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                        ForEach(pendingCatalog) { entry in
                            catalogCard(entry)
                        }
                    }
                }
                if !checkLines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(checkLines, id: \.self) { line in
                            Text(line).font(.footnote).foregroundStyle(Theme.textDim)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12))
                }
                if let note {
                    Text(note).font(.footnote).foregroundStyle(Theme.textDim)
                }
                if records.isEmpty {
                    EmptyStateView(icon: "puzzlepiece.extension",
                                   title: "还没有模块",
                                   message: "导入 Forward 规范的 JS 模块文件，或粘贴模块 / .fwd 订阅链接。")
                }
                ForEach(records) { record in
                    NavigationLink {
                        FWDWidgetView(record: record)
                    } label: {
                        HStack(spacing: 12) {
                            if !record.meta.icon.isEmpty {
                                PosterImage(urlString: record.meta.icon, pixelSize: 240)
                                    .frame(width: 38, height: 38)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                            } else {
                                Image(systemName: "puzzlepiece.extension")
                                    .foregroundStyle(Theme.accent)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(record.meta.localized(record.meta.title.isEmpty ? record.id : record.meta.title))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.text).lineLimit(1)
                                    // v1.83: badge packages that carry a danmu module —
                                    // their titles play with live danmaku (FWDDanmu.fetch).
                                    if FWDDanmu.hasDanmu(record.meta) {
                                        Text("弹幕")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(Theme.accent)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Theme.glass, in: Capsule())
                                    }
                                    // v2.29 (guide 内容类型章): the effective
                                    // content type — declared by the module,
                                    // or the user's own choice when the
                                    // module declares none ("·自选").
                                    if !record.meta.contentTypeLabel.isEmpty {
                                        Text(record.meta.contentTypeLabel
                                             + (record.meta.contentTypeIsUserChosen ? "·自选" : ""))
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(Theme.accent)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Theme.glass, in: Capsule())
                                    }
                                }
                                Text(moduleSubtitle(record))
                                    .font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                                // v1.94: last self-check stays on the
                                // card (time + conclusion); the tick
                                // forces a refresh once runSelfCheck
                                // saves new results.
                                Text(checkLine(record, tick: checkVersion))
                                    .font(.caption2).foregroundStyle(Theme.textDim).lineLimit(1)
                                // v2.26: import-time metadata
                                // warnings (non-blocking issues
                                // from the guide check).
                                if let notes = FWDStore.validationNotes(for: record.id) {
                                    Text("元数据提示 \(notes.count) 项：\(notes[0])")
                                        .font(.caption2).foregroundStyle(Theme.textDim).lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(Theme.textDim)
                        }
                        .padding(14)
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        // v2.29 (guide 内容类型章): a module that
                        // declares no valid contentType leaves the
                        // choice to the user — pick it here. A valid
                        // declaration always wins, so no picker is
                        // offered for those modules.
                        if !["video", "music", "audiobook", "shortDrama"].contains(record.meta.contentType) {
                            Menu("内容类型（模块未声明，自选）") {
                                ForEach([("video", "视频"), ("music", "音乐"),
                                         ("audiobook", "听书"), ("shortDrama", "短剧")], id: \.0) { pair in
                                    Button {
                                        FWDStore.saveContentTypeOverride(pair.0, for: record.id)
                                        records = FWDStore.records()
                                    } label: {
                                        Label(pair.1 + (FWDStore.contentTypeOverride(for: record.id) == pair.0 ? " ✓" : ""),
                                              systemImage: "tag")
                                    }
                                }
                                Button {
                                    FWDStore.saveContentTypeOverride("", for: record.id)
                                    records = FWDStore.records()
                                } label: {
                                    Label("清除自选", systemImage: "xmark.circle")
                                }
                            }
                        }
                        Button(role: .destructive) {
                            FWDStore.delete(record)
                            records = FWDStore.records()
                        } label: {
                            Label("删除模块", systemImage: "trash")
                        }
                    }
                }
                Text("支持 Forward 规范的 JS 模块（WidgetMetadata）。加密模块（FWENC1）内容已加密、无法导入，请向模块作者索取未加密版本；同包的弹幕模块会在播放时自动匹配弹幕。订阅（.fwd）批量导入：重复 id 覆盖同名旧版，失败的链接不影响其余模块，导入结果会逐条列出。")
                    .font(.caption2).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 110)
        }
        .background(AmbientBackground(imageURL: nil))
        .navigationTitle("模块")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { records = FWDStore.records() }
        // The import Task's records assignment can be swallowed
        // when the picker sheet tears down (device report: the
        // module only appeared after an app restart). Reload from
        // the live view tree whenever the picker closes — this
        // hook always fires.
        .onChange(of: showFileImporter) { _, presented in
            if !presented { records = FWDStore.records() }
        }
        // v1.75: SwiftUI's fileImporter silently never presented
        // on device for this page (reported: tapping 导入文件 did
        // nothing). Use the app's proven DocumentPicker sheet —
        // the same one config / py / js imports use — with
        // multi-select, importing modules and .fwd files alike.
        .sheet(isPresented: $showFileImporter) {
            DocumentPicker(
                onPick: { urls in
                    importing = true
                    Task {
                        defer { importing = false }
                        var outcomes: [FWDStore.ImportOutcome] = []
                        var failures: [String] = []
                        for url in urls {
                            do {
                                let data = try Data(contentsOf: url)
                                guard let text = String(data: data, encoding: .utf8) else {
                                    throw FWDStore.StoreFailure(message: "文件无法读取")
                                }
                                outcomes.append(try await FWDStore.importFileTextDetailed(
                                    text, origin: url.lastPathComponent))
                            } catch {
                                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                            }
                        }
                        records = FWDStore.records()
                        // v2.29: a batch outcome per file (imported /
                        // overwritten / per-link failures), so a
                        // half-failed subscription is visible instead
                        // of hiding behind a bare count.
                        let total = FWDStore.ImportOutcome(
                            imported: outcomes.reduce(0) { $0 + $1.imported },
                            overwritten: outcomes.reduce(0) { $0 + $1.overwritten },
                            failures: outcomes.flatMap(\.failures))
                        var parts: [String] = []
                        let summary = FWDStore.importOutcomeText(total)
                        if !summary.isEmpty { parts.append(summary) }
                        if !failures.isEmpty { parts.append("失败：\n" + failures.joined(separator: "；")) }
                        note = parts.joined(separator: " · ")
                        if total.imported > 0 { Haptics.success() }
                        else if !failures.isEmpty || !total.failures.isEmpty { Haptics.error() }
                    }
                },
                onCancel: { })
                .ignoresSafeArea()
        }
        .alert("导入链接", isPresented: $showURLImporter) {
            TextField("模块 .js 或 .fwd 订阅链接", text: $importURL)
            Button("导入") {
                let target = importURL
                importing = true
                Task {
                    defer { importing = false }
                    do {
                        let outcome = try await FWDStore.importRemoteDetailed(target)
                        note = FWDStore.importOutcomeText(outcome)
                        records = FWDStore.records()
                    } catch {
                        note = "导入失败：\(error.localizedDescription)"
                    }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// In-app module self-check (v1.76, v2.18): TMDB key presence,
    /// both TMDB routes, and EVERY imported module's list columns
    /// with real calls — the same checks support would run, in
    /// the user's own network, reported in plain language. Each
    /// column is timed; the per-column outcomes (pass/fail, item
    /// count or error, duration) persist with the result so the
    /// module card keeps them after a restart.
    private func runSelfCheck() async {
        checking = true
        checkLines = []
        defer { checking = false }
        let key = (UserDefaults.standard.string(forKey: "tmdb.key") ?? "")
        checkLines.append(key.isEmpty ? "✗ TMDB 密钥未填（去设置 → TMDB 填入）"
                                      : "✓ TMDB 密钥已填")
        let baseRaw = (UserDefaults.standard.string(forKey: "tmdb.base") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let configured = baseRaw.isEmpty ? "https://api.themoviedb.org" : baseRaw
        checkLines.append(await tmdbPing(configured)
            ? "✓ TMDB 线路（当前设置）可达"
            : "✗ TMDB 线路（当前设置）不通")
        if configured != TMDBClient.forwardBase {
            checkLines.append(await tmdbPing(TMDBClient.forwardBase)
                ? "✓ TMDB 转发线路可达（直连不通时自动走它）"
                : "✗ TMDB 转发线路不通")
        }
        if records.isEmpty {
            checkLines.append("（还没有导入任何模块）")
        }
        for record in records {
            guard let source = FWDStore.source(for: record) else { continue }
            let title = record.meta.title.isEmpty ? record.id : record.meta.title
            // v2.18: check EVERY list column, not just the first
            // one, and time each — a dead 2nd column used to hide
            // behind a healthy 1st. Columns run sequentially on
            // the app's serial JS queue; a full official module
            // takes ~10 s in the Node harness.
            var cols: [FWDStore.ColumnCheck] = []
            var totalItems = 0
            var totalMs = 0
            for module in record.meta.listModules {
                let start = Date()
                do {
                    let result = try await FWDRuntime(widgetID: record.id)
                        .call(function: module.functionName,
                              params: fwdDefaultParams(meta: record.meta, module: module),
                              source: source)
                    let n = Self.fwdResultCount(result)
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    totalItems += n
                    totalMs += ms
                    cols.append(FWDStore.ColumnCheck(title: module.title, ok: n > 0,
                                                     count: n, error: "", ms: ms))
                    checkLines.append(n > 0
                        ? "✓ \(title)「\(module.title)」：\(n) 条 · \(Self.checkDurationText(ms))"
                        : "△ \(title)「\(module.title)」：返回 0 条 · \(Self.checkDurationText(ms))")
                } catch {
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    totalMs += ms
                    cols.append(FWDStore.ColumnCheck(title: module.title, ok: false,
                                                     count: 0,
                                                     error: error.localizedDescription, ms: ms))
                    checkLines.append("✗ \(title)「\(module.title)」：\(error.localizedDescription) · \(Self.checkDurationText(ms))")
                }
            }
            if cols.isEmpty {
                checkLines.append("△ \(title)：没有可自检的栏目")
                continue
            }
            let passed = cols.filter { $0.ok }.count
            // ok = no column threw AND at least one returned
            // items — a module whose only blemish is a 0-item
            // column (e.g. TMDB's Cloudflare-blocked list) still
            // shows its per-column detail on the card line.
            let ok = cols.allSatisfy { $0.error.isEmpty } && totalItems > 0
            // v2.29 (R4): the self-check also names what the
            // content-type / i18n alignment landed on for this
            // module — declared or user-chosen type, continuous
            // play preference, how many languages its i18n
            // dictionary covers. Official examples imported from
            // the directory go through this same loop.
            let ctLabel = record.meta.contentTypeLabel
            checkLines.append("• \(title)：内容类型"
                              + (ctLabel.isEmpty ? "未声明（长按卡片可自选）" : ctLabel)
                              + (record.meta.contentTypeIsUserChosen ? "（自选）" : "")
                              + (record.meta.continuousPlay ? " · 连播偏好开" : "")
                              + " · 多语言 \(record.meta.i18n.count) 种")
            let summary = "\(passed)/\(cols.count) 栏 · 共 \(totalItems) 条 · \(Self.checkDurationText(totalMs))"
            // v1.94: leave the conclusion on the card.
            FWDStore.saveCheckResult(
                FWDStore.CheckResult(time: Date(), ok: ok, summary: summary, columns: cols),
                for: record.id)
        }
        checkVersion += 1
    }

    /// Item count of a module column result: a bare array, or a
    /// dict wrapping one under items/list/data/results.
    private static func fwdResultCount(_ result: Any?) -> Int {
        if let array = result as? [Any] { return array.count }
        if let dict = result as? [String: Any] {
            for key in ["items", "list", "data", "results"] {
                if let array = dict[key] as? [Any] { return array.count }
            }
        }
        return 0
    }

    /// "650ms" under a second, "1.2s" above — used by the
    /// self-check lines and the per-module card line.
    private static func checkDurationText(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }

    /// Any JSON back — even a TMDB 401 error body — proves the
    /// route itself answers.
    private func tmdbPing(_ base: String) async -> Bool {
        let key = (UserDefaults.standard.string(forKey: "tmdb.key") ?? "")
        guard let url = URL(string: base + "/3/configuration?api_key=\(key)") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private func checkLine(_ record: FWDRecord, tick: Int) -> String {
        let _ = tick
        guard let result = FWDStore.checkResult(for: record.id) else {
            return "尚未自检"
        }
        let stamp = Self.checkDateFormatter.string(from: result.time)
        return "\(result.ok ? "✓" : "✗") 自检 \(stamp) · \(result.summary)"
    }

    private static let checkDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private func moduleSubtitle(_ record: FWDRecord) -> String {
        var parts: [String] = []
        if !record.meta.author.isEmpty { parts.append(record.meta.author) }
        if !record.meta.version.isEmpty { parts.append("v\(record.meta.version)") }
        parts.append("\(record.meta.listModules.count) 个栏目")
        if let host = URL(string: record.source)?.host { parts.append(host) }
        return parts.joined(separator: " · ")
    }

    /// One directory card (v2.02): metadata first, one tap to
    /// download and enable. importRemote writes the module file
    /// and replaces any same-id record, so a card can never
    /// produce a duplicate.
    private func catalogCard(_ entry: FWDCatalogEntry) -> some View {
        HStack(spacing: 12) {
            if !entry.icon.isEmpty {
                PosterImage(urlString: entry.icon, pixelSize: 240)
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text).lineLimit(1)
                    Text("v\(entry.version)")
                        .font(.caption2).foregroundStyle(Theme.textDim)
                }
                Text("\(entry.author) · \(entry.columnCount) 个栏目")
                    .font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                Text(entry.description)
                    .font(.caption).foregroundStyle(Theme.textDim).lineLimit(2)
                if entry.requiresTMDBKey {
                    Text("需先在设置 → TMDB 填入自己的密钥")
                        .font(.caption2).foregroundStyle(Theme.textDim).lineLimit(1)
                }
            }
            Spacer()
            Button {
                Haptics.tap()
                downloadingCatalogID = entry.id
                Task {
                    defer { downloadingCatalogID = nil }
                    do {
                        _ = try await FWDStore.importRemote(entry.url)
                        records = FWDStore.records()
                        note = "已导入 \(entry.title)"
                        Haptics.success()
                    } catch {
                        note = "\(entry.title) 下载失败：\(error.localizedDescription)"
                        Haptics.error()
                    }
                }
            } label: {
                if downloadingCatalogID == entry.id {
                    ProgressView().tint(Theme.text)
                } else {
                    Text("下载")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.glass, in: Capsule())
                }
            }
            .buttonStyle(.plain)
            .disabled(downloadingCatalogID != nil)
        }
        .padding(14)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// v2.29 — guide i18n 章的查找顺序：完整语言代码 →
/// 文字体系（zh-TW/zh-HK/zh-MO → zh-Hant；zh-CN/zh-SG →
/// zh-Hans）→ 基础语言 → 原文。大小写与 `_`/`-` 不敏感。
/// The JS shim's Widget.i18n runs the same order (its
/// candidate list is injected by makeContext), so the two
/// sides can never disagree about which translation wins.
func fwdLocaleCandidates() -> [String] {
    var out: [String] = []
    func add(_ s: String) {
        let n = s.lowercased().replacingOccurrences(of: "_", with: "-")
        if !n.isEmpty, !out.contains(n) { out.append(n) }
    }
    for lang in Locale.preferredLanguages {
        add(lang)
        let lower = lang.lowercased().replacingOccurrences(of: "_", with: "-")
        if lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") || lower.hasPrefix("zh-mo") {
            add("zh-Hant")
        } else if lower.hasPrefix("zh-cn") || lower.hasPrefix("zh-sg") {
            add("zh-Hans")
        }
        if let base = lower.split(separator: "-").first { add(String(base)) }
    }
    return out
}

/// v2.29: seconds → "m:ss" for music track rows (the guide's
/// `duration` is a second count; durationText stays the
/// module's own string when present).
func fwdDurationText(_ item: FWDItem) -> String {
    guard let s = item.duration, s > 0 else { return "" }
    return "\(s / 60):\(String(format: "%02d", s % 60))"
}

func fwdLocalized(_ text: String, i18n: [String: [String: String]]) -> String {
    guard !text.isEmpty, !i18n.isEmpty else { return text }
    var byNorm: [String: [String: String]] = [:]
    for (k, v) in i18n {
        byNorm[k.lowercased().replacingOccurrences(of: "_", with: "-")] = v
    }
    for cand in fwdLocaleCandidates() {
        if let row = byNorm[cand], let hit = row[text], !hit.isEmpty { return hit }
    }
    return text
}

/// v2.26 — the ONE place module params are combined, following
/// the Rex guide's 参数 rules verbatim:
///  1. Start from caller values; user-saved global params
///     override same-name values (INCLUDING empty strings).
///  2. Fill defaults in order: globalParams, then the entry's
///     own params.
///  3. A param hidden by belongTo gets NO default — but an
///     explicitly saved/caller value still passes through.
///  4. language/timezone/userId/configId are injected ONLY
///     when a param of that type is declared (language =
///     device language, timezone = device zone; the app has
///     no app-wide userId/configId, so those stay unset).
///  5. page/offset with no explicit value come from the App's
///     pagination position (page honours startPage; offset
///     strides by the entry's count param when one exists).
///  ALL values are strings — handlers do Number(...) first.
/// `page` is the UI's 1-based page index (1 = first page).
func fwdCombineParams(meta: FWDMeta, entry: FWDModuleEntry,
                      caller: [String: String], page: Int,
                      savedGlobals: [String: String]) -> [String: String] {
    var result: [String: String] = caller
    for (k, v) in savedGlobals { result[k] = v }
    let ordered = meta.globalParams + entry.params
    // Defaults first, so belongTo visibility can be judged
    // against the values a referenced param would actually
    // carry (its default included).
    func defaultValue(_ p: FWDParam) -> String? {
        switch p.type {
        case "page":
            let start = p.startPage ?? 1
            return String(start + max(0, page - 1))
        case "offset":
            if let countParam = entry.params.first(where: { $0.type == "count" }),
               let count = Int(result[countParam.name]
                               ?? defaultValue(countParam) ?? "0"), count > 0 {
                return String((page - 1) * count)
            }
            return "0"
        case "count":
            return p.value.isEmpty ? "0" : p.value
        case "enumeration":
            return p.value.isEmpty ? (p.enumOptions.first?.value ?? "") : p.value
        case "input":
            return p.value.isEmpty ? (p.placeholders.first?.value ?? "") : p.value
        case "constant":
            return p.value.isEmpty ? nil : p.value
        case "folder":
            return p.value.isEmpty ? "-1" : p.value
        case "language":
            if !p.value.isEmpty { return p.value }
            return Locale.preferredLanguages.first ?? "zh-CN"
        case "timezone":
            if !p.value.isEmpty { return p.value }
            return TimeZone.current.identifier
        case "userId", "configId":
            // No app-wide identity exists; only an explicit
            // value is ever sent (rule 4: declared-only).
            return p.value.isEmpty ? nil : p.value
        default:
            return p.value.isEmpty ? nil : p.value
        }
    }
    var known: [String: String] = result
    for p in ordered {
        if known[p.name] == nil, let d = defaultValue(p) { known[p.name] = d }
    }
    for p in ordered {
        if result[p.name] != nil { continue }
        guard p.isVisible(given: known) else { continue }
        if let d = defaultValue(p) { result[p.name] = d }
    }
    return result
}

/// Default params for a module's first run (self-check): the
/// same fallback rules as FWDWidgetView.buildParams with no
/// user selections — enumerations take their first option,
/// inputs take their first placeholder suggestion.
func fwdDefaultParams(meta: FWDMeta, module: FWDModuleEntry) -> [String: Any] {
    fwdCombineParams(meta: meta, entry: module, caller: [:], page: 1, savedGlobals: [:])
}

// MARK: - Widget browse

struct FWDWidgetView: View {
    let record: FWDRecord
    @State private var items: [FWDItem] = []
    @State private var loading = true
    @State private var loadingMore = false
    @State private var errorText: String?
    @State private var moduleIndex = 0
    @State private var page = 1
    @State private var selections: [String: String] = [:]
    @State private var searchText = ""
    @State private var detailItem: FWDItem?
    @State private var showSearch = false
    @State private var searchSeed = ""
    /// v2.19: the keyword of the last search, so the error
    /// banner's retry re-runs the SEARCH instead of reloading
    /// the column (the old retry called load(reset:) and the
    /// search failure just came back as an empty column).
    @State private var lastSearchKeyword: String?
    /// v2.27: the page the current module search is on.
    /// Search used to share the column's `page`, and the
    /// "加载更多" button then ran the COLUMN's loadMore —
    /// appending column rows to search results. Search
    /// paging now walks its own page (guide: search params
    /// take keyword + page, same rules as columns).
    @State private var searchPage = 1

    private var meta: FWDMeta { record.meta }
    private var listModules: [FWDModuleEntry] { meta.listModules }
    private var currentModule: FWDModuleEntry? {
        listModules.indices.contains(moduleIndex) ? listModules[moduleIndex] : nil
    }
    private var hasPageParam: Bool {
        currentModule?.params.contains { $0.type == "page" || $0.name == "page" } ?? false
    }

    /// v2.27: while a search is showing, "加载更多" pages
    /// the SEARCH (it declares its own page param); otherwise
    /// it pages the current column.
    private var canLoadMore: Bool {
        if lastSearchKeyword != nil {
            return meta.searchParams.contains { $0.type == "page" || $0.name == "page" }
        }
        return hasPageParam
    }

    var body: some View {
        Group {
            if loading {
                ScrollView(showsIndicators: false) {
                    // v2.21: cross-fades when the column lands.
                    SkeletonPosterGrid()
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 110)
                        .transition(.opacity)
                }
            } else if let errorText, items.isEmpty {
                EmptyStateView(icon: "wifi.exclamationmark",
                               title: "模块没拉到数据",
                               message: errorText,
                               actionTitle: "重新加载",
                               action: { Task { await retryCurrent() } })
                    .padding(.horizontal, 18)
            } else {
                content
            }
        }
        .animation(.easeOut(duration: 0.25), value: loading)
        .background(AmbientBackground(imageURL: nil))
        .navigationTitle(meta.localized(meta.title.isEmpty ? record.id : meta.title))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $detailItem) { item in
            FWDDetailView(record: record, item: item)
        }
        .sheet(isPresented: $showSearch) {
            SearchView(config: ConfigLibrary.activeID().flatMap { ConfigLibrary.load(id: $0) },
                       initialKeyword: searchSeed)
        }
        .task { await load(reset: true) }
    }

    private var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                if meta.searchFunction != nil {
                    HStack {
                        TextField("搜索…", text: $searchText)
                            .font(.subheadline)
                            .padding(10)
                            .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10))
                        Button("搜索") { Task { await runSearch() } }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                if listModules.count > 1 {
                    chipRow(listModules.map { meta.localized($0.title) },
                            selected: moduleIndex) { idx in
                        moduleIndex = idx
                        page = 1
                        Task { await load(reset: true) }
                    }
                }
                if (UserDefaults.standard.string(forKey: "tmdb.key") ?? "").isEmpty,
                   record.meta.id.lowercased().contains("tmdb") {
                    Text("提示：TMDB 密钥还没填，这个模块的栏目不出数据。去「设置 → TMDB」填入 v3 密钥即可；线路不通时会自动走 JarProxy 转发，不用梯子。")
                        .font(.caption).foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let module = currentModule {
                    ForEach(visibleParams(module.params).filter { $0.type == "enumeration" && !$0.enumOptions.isEmpty },
                            id: \.name) { param in
                        chipRow(param.enumOptions.map { meta.localized($0.title) },
                                selected: param.enumOptions.firstIndex {
                                    $0.value == (selections[param.name] ?? param.value)
                                } ?? 0) { idx in
                            selections[param.name] = param.enumOptions[idx].value
                            page = 1
                            Task { await load(reset: true) }
                        }
                    }
                    ForEach(visibleParams(module.params).filter { $0.type == "input" },
                            id: \.name) { param in
                        inputRow(param)
                    }
                }
                // v2.06: a failed load-more / search no longer
                // dies silently once items exist — the cause
                // stays visible with a retry that refetches.
                if let errorText, !items.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Theme.accent)
                        Text(errorText)
                            .font(.caption).foregroundStyle(Theme.textDim)
                            .lineLimit(2)
                        Spacer()
                        Button("重新加载") {
                            Haptics.tap()
                            Task { await retryCurrent() }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(10)
                    .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10))
                }
                if items.isEmpty {
                    EmptyStateView(icon: "square.stack.3d.up.slash",
                                   title: "这个栏目暂时没有内容",
                                   message: "换个栏目或关键词试试",
                                   actionTitle: "重新加载",
                                   action: { Task { await load(reset: true, bypassCache: true) } },
                                   compact: true)
                } else {
                    posterGrid(items)
                }
                if canLoadMore && !items.isEmpty {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        HStack(spacing: 8) {
                            if loadingMore { ProgressView().tint(Theme.text) }
                            Text("加载更多")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(loadingMore)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 110)
        }
    }

    /// One input-param row (v1.75): a text field whose return key
    /// (or the 加载 button) reloads with the typed value, plus the
    /// metadata's placeholder suggestions as tappable chips.
    @ViewBuilder
    private func inputRow(_ param: FWDParam) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField(meta.localized(param.desc.isEmpty
                            ? (param.title.isEmpty ? param.name : param.title)
                            : param.desc),
                          text: Binding(
                            get: { selections[param.name] ?? param.value },
                            set: { selections[param.name] = $0 }))
                    .font(.subheadline)
                    .padding(10)
                    .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit {
                        page = 1
                        Task { await load(reset: true) }
                    }
                Button("加载") {
                    Haptics.tap()
                    page = 1
                    Task { await load(reset: true) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            }
            if !param.placeholders.isEmpty {
                chipRow(param.placeholders.map { meta.localized($0.title) },
                        selected: param.placeholders.firstIndex {
                            $0.value == (selections[param.name]
                                ?? param.placeholders.first?.value ?? "")
                        } ?? 0) { idx in
                    selections[param.name] = param.placeholders[idx].value
                    page = 1
                    Task { await load(reset: true) }
                }
            }
        }
    }

    private func chipRow(_ titles: [String], selected: Int,
                         onPick: @escaping (Int) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(titles.indices, id: \.self) { idx in
                    Text(titles[idx])
                        .font(.subheadline.weight(idx == selected ? .semibold : .regular))
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .background(idx == selected ? Color.white : Theme.glass, in: Capsule())
                        .foregroundStyle(idx == selected ? .black : Theme.text.opacity(0.85))
                        .onTapGesture { Haptics.selection(); onPick(idx) }
                }
            }
        }
    }

    private func posterGrid(_ list: [FWDItem]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                  spacing: 16) {
            ForEach(list) { item in
                Button {
                    open(item)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        PosterImage(urlString: item.posterURL)
                            .aspectRatio(2/3, contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.glass))
                        Text(item.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        // v2.27: the guide's `subtitle` is the
                        // card subtitle — show it when the
                        // module sent one; the year·rating line
                        // stays as its own row below it.
                        if !item.subtitle.isEmpty {
                            Text(item.subtitle)
                                .font(.caption2)
                                .foregroundStyle(Theme.textDim)
                                .lineLimit(1)
                        }
                        if !item.releaseDate.isEmpty || !item.rating.isEmpty {
                            Text([String(item.releaseDate.prefix(4)),
                                  item.rating.isEmpty ? "" : "★\(item.rating)"]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(Theme.textDim)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Tap routing: items carrying a link / videoUrl / episode
    /// list open the module detail page (which resolves playback);
    /// bare catalogue items (the TMDB-type lists most modules
    /// return) go to cross-line search by title, exactly like a
    /// Discover poster tap.
    /// v2.29 (guide 音乐章): a genre / radio / person item
    /// drills into the module's OWN parameterized entry —
    /// musicGenres (genreId), musicRadios (radioId),
    /// musicArtists (peopleId), or any entry declaring the
    /// matching *Id param — instead of falling through to
    /// cross-line search, which could never open a genre page.
    private func open(_ item: FWDItem) {
        Haptics.tap()
        if let drill = drillTarget(for: item) {
            moduleIndex = drill.index
            selections[drill.param] = item.id
            page = 1
            lastSearchKeyword = nil
            Task { await load(reset: true) }
            return
        }
        if !item.link.isEmpty || !item.videoUrl.isEmpty || !item.episodeItems.isEmpty {
            detailItem = item
        } else {
            searchSeed = item.title
            showSearch = true
        }
    }

    private func drillTarget(for item: FWDItem) -> (index: Int, param: String)? {
        let param: String?
        switch item.mediaType {
        case "genre": param = "genreId"
        case "radio": param = "radioId"
        default: param = item.type == "person" ? "peopleId" : nil
        }
        guard let param else { return nil }
        for (i, m) in listModules.enumerated()
        where m.params.contains(where: { $0.name == param }) {
            return (i, param)
        }
        return nil
    }

    private func buildParams(for module: FWDModuleEntry, page: Int) -> [String: Any] {
        // v2.26: one shared combiner for the guide's rules
        // (caller → saved globals → globalParams → entry
        // defaults, belongTo hiding, string values only).
        fwdCombineParams(meta: meta, entry: module, caller: selections,
                         page: page,
                         savedGlobals: FWDStore.savedGlobalParams(for: record.id))
    }

    /// Params the column UI shows: belongTo-hidden params are
    /// not rendered at all (guide: hidden = not displayed).
    /// Visibility is judged against the effective values the
    /// handler would receive (defaults included).
    private func visibleParams(_ params: [FWDParam]) -> [FWDParam] {
        guard let module = currentModule else { return params }
        let known = fwdCombineParams(meta: meta, entry: module,
                                     caller: selections, page: page,
                                     savedGlobals: FWDStore.savedGlobalParams(for: record.id))
        return params.filter { $0.isVisible(given: known) }
    }

    /// Page-1 list loads consult FWDColumnCache first (v2.06):
    /// re-entering a column replays the last result while the
    /// TTL holds (module `cacheDuration` or 30 min), so the
    /// column opens instantly and skips the JS + network round
    /// trip. Manual retries bypass the cache; searches and
    /// pages > 1 never read or write it. Returns false on
    /// failure so loadMore can roll the page back.
    @discardableResult
    private func load(reset: Bool, bypassCache: Bool = false) async -> Bool {
        guard let module = currentModule,
              let source = FWDStore.source(for: record) else {
            loading = false
            return false
        }
        if reset { loading = true; errorText = nil; lastSearchKeyword = nil; searchPage = 1 }
        let params = buildParams(for: module, page: page)
        // v2.26: TTL honours the ENTRY's declared cacheDuration
        // (Rex guide); the legacy top-level value is only a
        // fallback for index files written before v2.26.
        let ttl = module.cacheDuration > 0
            ? TimeInterval(module.cacheDuration)
            : (meta.cacheDuration > 0
               ? TimeInterval(meta.cacheDuration) : FWDColumnCache.defaultTTL)
        let cacheKey = FWDColumnCache.key(moduleID: record.id,
                                          columnID: module.id, params: params)
        if reset, page == 1, !bypassCache,
           let cached = FWDColumnCache.get(key: cacheKey, ttl: ttl) {
            items = cached.map(FWDItem.init)
            loading = false
            return true
        }
        do {
            let result = try await FWDRuntime(widgetID: record.id)
                .call(function: module.functionName,
                      params: params,
                      source: source)
            let rows = (result as? [[String: Any]] ?? [])
            items = reset ? rows.map(FWDItem.init) : items + rows.map(FWDItem.init)
            if reset, page == 1, !rows.isEmpty {
                FWDColumnCache.set(key: cacheKey, rows: rows)
            }
            errorText = nil
        } catch {
            if reset { errorText = "加载失败：\(error.localizedDescription)" }
            else { errorText = "加载更多失败：\(error.localizedDescription)" }
            loading = false
            return false
        }
        loading = false
        return true
    }

    private func loadMore() async {
        // v2.27: a search showing means the button pages the
        // search, not the column (see searchPage).
        if lastSearchKeyword != nil {
            loadingMore = true
            searchPage += 1
            if await performSearch(append: true) == false {
                searchPage = max(1, searchPage - 1)
            }
            loadingMore = false
            return
        }
        loadingMore = true
        page += 1
        if await load(reset: false) == false {
            page = max(1, page - 1)
        }
        loadingMore = false
    }

    /// Retry whatever the page was last doing: a failed search
    /// re-runs the search with the same keyword, anything else
    /// reloads the column bypassing the cache (v2.19).
    private func retryCurrent() async {
        if let keyword = lastSearchKeyword {
            await runSearch(keyword: keyword)
        } else {
            await load(reset: true, bypassCache: true)
        }
    }

    private func runSearch(keyword: String? = nil) async {
        guard let fn = meta.searchFunction,
              let source = FWDStore.source(for: record) else { return }
        let keyword = (keyword ?? searchText).trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }
        lastSearchKeyword = keyword
        searchPage = 1
        loading = true
        errorText = nil
        await performSearch(append: false)
        loading = false
    }

    /// One search request at the current `searchPage`.
    /// Returns false on failure so loadMore can roll the
    /// page back (same contract as load, v2.06).
    @discardableResult
    private func performSearch(append: Bool) async -> Bool {
        guard let fn = meta.searchFunction,
              let source = FWDStore.source(for: record),
              let keyword = lastSearchKeyword else { return false }
        // v2.27: search params go through the same combiner
        // as columns (guide: search is a top-level entry with
        // the same param rules). keyword is the caller value;
        // the query/searchKeyword aliases stay for modules
        // written against the older convention. page walks
        // searchPage so "加载更多" fetches the next page.
        let searchEntry = FWDModuleEntry(id: "search", title: "", functionName: fn,
                                         type: "", params: meta.searchParams)
        let params: [String: Any] = fwdCombineParams(
            meta: meta, entry: searchEntry,
            caller: ["keyword": keyword, "query": keyword, "searchKeyword": keyword],
            page: searchPage, savedGlobals: FWDStore.savedGlobalParams(for: record.id))
        do {
            let result = try await FWDRuntime(widgetID: record.id)
                .call(function: fn, params: params, source: source)
            let rows = (result as? [[String: Any]] ?? []).map(FWDItem.init)
            items = append ? items + rows : rows
            errorText = nil
            return true
        } catch {
            errorText = append
                ? "加载更多失败：\(error.localizedDescription)"
                : "搜索失败：\(error.localizedDescription)"
            return false
        }
    }
}

// MARK: - Widget detail + playback

struct FWDDetailView: View {
    let record: FWDRecord
    let item: FWDItem
    @State private var full: FWDItem
    @State private var loadingDetail = false
    /// v2.19: enrich() used to swallow a loadDetail failure into
    /// the diagnostics log only — the page showed the thin list
    /// item with no episodes and no hint why. Surface it.
    @State private var detailError: String?
    @State private var playSelection: FWDPlaySelection?
    @State private var resolvingNote: String?

    private struct FWDPlaySelection: Identifiable {
        var episodes: [PlayerView.EpisodeRef]
        var index: Int
        var initial: (url: String, header: [String: String])?
        var resolver: PlayerView.Resolver?
        /// v1.61: module danmaku for this title (same package's
        /// danmu entries), fed to the player's danmaku layer per
        /// episode; forced on when the package has danmu modules.
        var danmakuLoader: ((Int) async -> Data?)?
        var danmakuForced: Bool = false
        /// v2.28: the winning resource's playerType (or the
        /// item's own) — "system" forces the native engine,
        /// "app" the software (mpv) one, empty means auto.
        var playerType: String = ""
        /// v2.29 (guide 内容类型章): continuous play for this
        /// session — the module's continuousPlay declaration,
        /// or music/audiobook content, where track-after-track
        /// is the expected model. False leaves the user's
        /// global "自动播放下一集" untouched: the guide's
        /// default is false, so false must never switch a
        /// user's setting off.
        var continuousPlay: Bool = false
        /// v2.28: module subtitles for the opening episode,
        /// plus a per-episode loader (item externalSubtitles
        /// first, then the loadSubtitle entry).
        var initialSubtitles: [FWDSubtitle] = []
        var subtitleLoader: ((Int) async -> [FWDSubtitle])?
        var id: String { episodes[index].url + "#\(index)" }
    }
    /// v2.28: a loadResource answer with more than one line
    /// pauses for the user to pick one (guide: the entry
    /// returns playback LINES, plural). Pending episode while
    /// the picker sheet is up.
    @State private var resourceChoices: [FWDResource]?
    @State private var resourcePendingIndex: Int = 0
    @State private var resourcePendingSingle: Bool = false

    init(record: FWDRecord, item: FWDItem) {
        self.record = record
        self.item = item
        _full = State(initialValue: item)
    }

    private var meta: FWDMeta { record.meta }
    /// Guide 0.0.7 (music): valid `tracks` win, falling
    /// back to `episodeItems`, then `childItems`. v2.27.
    private var episodes: [FWDItem] {
        if !full.tracks.isEmpty { return full.tracks }
        if !full.episodeItems.isEmpty { return full.episodeItems }
        if !full.childItems.isEmpty { return full.childItems }
        return []
    }

    /// Media-info rows (v2.12): same spec as DetailView's card —
    /// only fields the module actually sent; empty ones dropped.
    private var fwdMediaInfoRows: [(label: String, value: String)] {
        [
            ("来源模块", meta.localized(meta.title)),
            ("类型", full.mediaType.isEmpty ? full.type : full.mediaType),
            ("年份", String(full.releaseDate.prefix(4))),
            ("评分", full.rating),
            ("时长", full.durationText),
            ("语言", full.language),
            ("分类", full.genreTitle),
            // v2.29 (guide 音乐章): albumMotionArtwork is a video
            // URL, not an image — note its presence rather than
            // pretending the hero can play it.
            ("动态封面", full.albumMotionArtwork.isEmpty ? "" : "视频"),
        ].filter { !$0.value.isEmpty }
    }

    /// v2.29 (guide 音乐章): an album / playlist shows its
    /// tracks under "曲目", an albumList under "专辑"; video
    /// detail keeps "选集".
    private var episodesSectionTitle: String {
        if full.mediaType == "albumList" { return "专辑" }
        if !full.tracks.isEmpty || ["album", "playlist"].contains(full.mediaType)
            || meta.effectiveContentType == "music" { return "曲目" }
        return "选集"
    }

    /// True when the episode grid is really a track list.
    private var isMusicDetail: Bool { episodesSectionTitle == "曲目" }

    /// Track sub-line: the artist line (the track's own
    /// subtitle) plus its duration, so a song row never shows
    /// just a bare title. Video episodes keep the old rule
    /// (subtitle, else duration) unchanged.
    private func episodeSubline(_ ep: FWDItem) -> String {
        if isMusicDetail {
            var parts: [String] = []
            if !ep.subtitle.isEmpty { parts.append(ep.subtitle) }
            let dur = ep.durationText.isEmpty ? fwdDurationText(ep) : ep.durationText
            if !dur.isEmpty { parts.append(dur) }
            return parts.joined(separator: " · ")
        }
        return ep.subtitle.isEmpty ? ep.durationText : ep.subtitle
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                PosterImage(urlString: full.backdropURL, pixelSize: 900)
                    .aspectRatio(16/9, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Text(full.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.text)
                // v2.27: the guide's card `subtitle`, shown
                // as the title's sub-line when present.
                if !full.subtitle.isEmpty {
                    Text(full.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                }
                if !metaLine.isEmpty {
                    Text(metaLine).font(.caption).foregroundStyle(Theme.textDim)
                }
                if let score = Double(full.rating), score > 0 {
                    HStack(spacing: 8) {
                        StarBarView(value: score)
                        Text(full.rating)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                        // v2.20: plain "评分" — the number comes
                        // from the module's own rating field, and
                        // only rex-tmdb's happens to be TMDB
                        // vote_average; labelling every module's
                        // number "TMDB 评分" asserted a source the
                        // module never promised.
                        Text("评分")
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                    }
                }
                if !full.overview.isEmpty {
                    Text(full.overview)
                        .font(.subheadline)
                        .foregroundStyle(Theme.text.opacity(0.8))
                        .lineSpacing(4)
                }
                MediaInfoCard(rows: fwdMediaInfoRows)
                CastRowView(people: full.peoples.map { (name: $0.name, role: $0.role, avatar: $0.avatar) })
                if loadingDetail {
                    HStack(spacing: 8) {
                        ProgressView().tint(Theme.text)
                        Text("正在加载详情…").font(.caption).foregroundStyle(Theme.textDim)
                    }
                }
                if let detailError, !loadingDetail {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Theme.accent)
                        Text(detailError)
                            .font(.caption).foregroundStyle(Theme.textDim)
                            .lineLimit(2)
                        Spacer()
                        Button("重试") {
                            Haptics.tap()
                            Task { await enrich() }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(10)
                    .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10))
                }
                if let resolvingNote {
                    Text(resolvingNote).font(.footnote).foregroundStyle(.orange)
                }
                if episodes.isEmpty {
                    if !full.videoUrl.isEmpty || meta.resourceFunction != nil || !full.link.isEmpty {
                        Button {
                            Task { await playSingle() }
                        } label: {
                            Label("播放", systemImage: "play.fill")
                                .font(.headline)
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text(episodesSectionTitle).font(.headline).foregroundStyle(Theme.text)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                        GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(Array(episodes.enumerated()), id: \.element.id) { pair in
                            Button {
                                Task { await playEpisode(at: pair.offset) }
                            } label: {
                                // v2.27 (R2 加料): episode sub-line
                                // — the episode's own subtitle, else
                                // its duration — so a bare "第N集"
                                // never sits alone when the module
                                // sent more info. v2.29: music tracks
                                // show artist + duration instead.
                                VStack(alignment: .center, spacing: 3) {
                                    Text(guageEpisodeDisplayName(pair.element.title,
                                                                 index: pair.element.episode.map { $0 - 1 } ?? pair.offset))
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                    let sub = episodeSubline(pair.element)
                                    if !sub.isEmpty {
                                        Text(sub)
                                            .font(.caption2)
                                            .foregroundStyle(Theme.textDim)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !full.relatedItems.isEmpty {
                    Text("相关推荐").font(.headline).foregroundStyle(Theme.text)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(full.relatedItems) { rel in
                                NavigationLink {
                                    FWDDetailView(record: record, item: rel)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        PosterImage(urlString: rel.posterURL)
                                            .aspectRatio(2/3, contentMode: .fill)
                                            .frame(width: 92, height: 138)
                                            .clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.glass))
                                        Text(rel.title)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(Theme.text)
                                            .lineLimit(1)
                                            .frame(width: 92, alignment: .leading)
                                        // v2.27 (R2 加料): the year·rating
                                        // row falls back to the card
                                        // subtitle when the module sent
                                        // no year and no rating — no
                                        // blank second line either way.
                                        let relMeta = rel.shortMetaLine.isEmpty
                                            ? rel.subtitle : rel.shortMetaLine
                                        if !relMeta.isEmpty {
                                            Text(relMeta)
                                                .font(.caption2)
                                                .foregroundStyle(Theme.textDim)
                                                .lineLimit(1)
                                                .frame(width: 92, alignment: .leading)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 110)
        }
        .background(AmbientBackground(imageURL: full.backdropURL.isEmpty ? nil : full.backdropURL))
        .navigationTitle(full.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playSelection) { sel in
            PlayerView(episodes: sel.episodes, startIndex: sel.index,
                       header: [:], title: full.title,
                       initialResolved: sel.initial,
                       resolver: sel.resolver,
                       danmakuLoader: sel.danmakuLoader,
                       danmakuForced: sel.danmakuForced,
                       modulePlayerType: sel.playerType,
                       initialSubtitles: sel.initialSubtitles,
                       subtitleLoader: sel.subtitleLoader,
                       autoNextOverride: sel.continuousPlay ? true : nil)
        }
        .sheet(isPresented: Binding(
            get: { resourceChoices != nil },
            set: { if !$0 { resourceChoices = nil } })) {
            if let choices = resourceChoices {
                NavigationStack {
                    List {
                        Section("选择播放线路（模块返回了 \(choices.count) 条）") {
                            ForEach(Array(choices.enumerated()), id: \.offset) { pair in
                                Button {
                                    let picked = pair.element
                                    let idx = resourcePendingIndex
                                    let single = resourcePendingSingle
                                    resourceChoices = nil
                                    Task { await startPlayback(at: idx, single: single, resource: picked) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(pair.element.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Theme.text)
                                        if !pair.element.description.isEmpty {
                                            Text(pair.element.description)
                                                .font(.caption).foregroundStyle(Theme.textDim)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle("播放线路")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { resourceChoices = nil }
                        }
                    }
                }
            }
        }
        .task { await enrich() }
    }

    private var metaLine: String {
        [String(full.releaseDate.prefix(4)), full.genreTitle,
         full.rating.isEmpty ? "" : "★\(full.rating)", full.durationText]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Items with a link ask the widget's loadDetail for the full
    /// record (episodes, playback URL, related titles). The call
    /// takes the bare link string (guide: no params object),
    /// and the result is MERGED into the list item (v2.27):
    /// a TMDB item's loadDetail result joins the built-in
    /// detail page instead of replacing it. An empty array is
    /// a valid "no detail" answer (guide: return [] — never
    /// null), so it keeps the list item with no error banner.
    private func enrich() async {
        guard !item.link.isEmpty, meta.hasDetail,
              let source = FWDStore.source(for: record) else { return }
        loadingDetail = true
        defer { loadingDetail = false }
        do {
            let result = try await FWDRuntime(widgetID: record.id)
                .callString(function: "loadDetail", argument: item.link, source: source)
            if let dict = result as? [String: Any] {
                full = full.mergedDetail(FWDItem(dict))
                detailError = nil
            } else if let list = result as? [[String: Any]] {
                if let first = list.first {
                    full = full.mergedDetail(FWDItem(first))
                }
                detailError = nil
            } else {
                detailError = "详情没有返回内容，集数与播放地址为空"
            }
        } catch {
            detailError = "详情加载失败：\(error.localizedDescription)"
            Diagnostics.log("模块", "loadDetail 失败：\(error.localizedDescription)")
        }
    }

    /// All playback lines for one episode (guide 资源与字幕章,
    /// v2.28): the loadResource entry returns an ARRAY of lines,
    /// each {name, url, description, customHeaders, playerType}.
    /// Params are the guide's playback context (all strings,
    /// missing fields not passed; no `title` — that only goes
    /// to subtitle/danmu entries). A line without its own
    /// headers falls back to the item's customHeaders. A
    /// direct videoUrl short-circuits as a single unnamed line.
    private func resolveAll(_ ep: FWDItem, episodeIndex: Int = 0) async -> [FWDResource] {
        if !ep.videoUrl.isEmpty {
            // v2.27: an item's own customHeaders ride along
            // with its direct videoUrl (guide: headers are
            // carried when playing); previously this played
            // headerless.
            return [FWDResource(["name": "直接播放", "url": ep.videoUrl,
                                 "playerType": ep.playerType,
                                 "customHeaders": ep.customHeaders], index: 0)]
        }
        guard let source = FWDStore.source(for: record) else { return [] }
        let runtime = FWDRuntime(widgetID: record.id)
        if let fn = meta.resourceFunction {
            let params = FWDPlaybackContext.withGlobals(
                FWDPlaybackContext.build(item: ep, seriesTitle: full.title,
                                         episodeName: ep.title == full.title ? nil : ep.title,
                                         includeTitle: false,
                                         episodeFallback: episodeIndex + 1), meta: meta)
            if let result = try? await runtime.call(function: fn, params: params, source: source),
               let resources = result as? [[String: Any]] {
                return resources.enumerated().compactMap { i, dict in
                    var res = FWDResource(dict, index: i)
                    guard !res.url.isEmpty else { return nil }
                    for (k, v) in ep.customHeaders where res.customHeaders[k] == nil {
                        res.customHeaders[k] = v
                    }
                    res.customHeaders.removeValue(forKey: "X-Forward-Skip-Redirect-Probe")
                    return res
                }
            }
        }
        if !ep.link.isEmpty, meta.hasDetail {
            if let result = try? await runtime.callString(function: "loadDetail",
                                                          argument: ep.link, source: source),
               let dict = result as? [String: Any] {
                let detail = FWDItem(dict)
                if !detail.videoUrl.isEmpty {
                    return [FWDResource(["name": "直接播放", "url": detail.videoUrl,
                                        "playerType": detail.playerType,
                                        "customHeaders": detail.customHeaders], index: 0)]
                }
            }
        }
        return []
    }

    private func resolve(_ ep: FWDItem, episodeIndex: Int = 0) async -> PlayerView.ResolveResult {
        let lines = await resolveAll(ep, episodeIndex: episodeIndex)
        guard let first = lines.first else {
            return .failed("该条目没有可播放地址")
        }
        return .ok(url: first.url, header: first.customHeaders)
    }

    /// Module subtitles for one episode (guide 资源与字幕章,
    /// v2.28): the item's own externalSubtitles first, then
    /// the loadSubtitle entry (same playback context plus
    /// `title`). Deduped by URL; an entry returning a bare
    /// array is the norm, a {subtitles:[…]} wrapper is also
    /// accepted. Empty when the module offers no subtitles.
    private func resolveSubtitles(_ ep: FWDItem, episodeIndex: Int = 0) async -> [FWDSubtitle] {
        var out = ep.externalSubtitles
        var seen = Set(out.map(\.url).filter { !$0.isEmpty })
        guard let fn = meta.subtitleFunction,
              let source = FWDStore.source(for: record) else { return out }
        let params = FWDPlaybackContext.withGlobals(
            FWDPlaybackContext.build(item: ep, seriesTitle: full.title,
                                     episodeName: ep.title == full.title ? nil : ep.title,
                                     includeTitle: true,
                                     episodeFallback: episodeIndex + 1), meta: meta)
        guard let result = try? await FWDRuntime(widgetID: record.id)
                .call(function: fn, params: params, source: source) else { return out }
        var dicts: [[String: Any]] = []
        if let arr = result as? [[String: Any]] { dicts = arr }
        else if let dict = result as? [String: Any],
                let arr = dict["subtitles"] as? [[String: Any]] { dicts = arr }
        for d in dicts {
            let track = FWDSubtitle(d)
            guard !track.url.isEmpty, !seen.contains(track.url) else { continue }
            seen.insert(track.url)
            out.append(track)
        }
        return out
    }

    private func playSingle() async {
        resolvingNote = nil
        let lines = await resolveAll(full, episodeIndex: 0)
        if lines.isEmpty {
            resolvingNote = "该条目没有可播放地址"
            return
        }
        if lines.count > 1 {
            resourcePendingIndex = 0
            resourcePendingSingle = true
            resourceChoices = lines
            return
        }
        await startPlayback(at: 0, single: true, resource: lines[0])
    }

    private func playEpisode(at idx: Int) async {
        resolvingNote = nil
        let list = episodes
        guard list.indices.contains(idx) else { return }
        let lines = await resolveAll(list[idx], episodeIndex: idx)
        if lines.isEmpty {
            resolvingNote = "该条目没有可播放地址"
            return
        }
        if lines.count > 1 {
            resourcePendingIndex = idx
            resourcePendingSingle = false
            resourceChoices = lines
            return
        }
        await startPlayback(at: idx, single: false, resource: lines[0])
    }

    /// Build the PlayerView session for one episode once its
    /// line is chosen: resolver (later episodes still resolve
    /// first-line-only), danmu loader (guide three-step chain),
    /// subtitle loader (item subtitles + loadSubtitle entry),
    /// and the winning line's playerType.
    private func startPlayback(at idx: Int, single: Bool, resource: FWDResource) async {
        let list = single ? [full] : episodes
        guard list.indices.contains(idx) else { return }
        let ep = list[idx]
        let refs: [PlayerView.EpisodeRef]
        if single {
            refs = [PlayerView.EpisodeRef(name: full.title, url: resource.url)]
        } else {
            refs = list.enumerated().map { i, ep in
                PlayerView.EpisodeRef(
                    name: guageEpisodeDisplayName(ep.title, index: ep.episode.map { $0 - 1 } ?? i),
                    url: !ep.link.isEmpty ? ep.link : (ep.videoUrl.isEmpty ? "ep#\(i)" : ep.videoUrl))
            }
        }
        let subtitles = await resolveSubtitles(ep, episodeIndex: idx)
        let playerType = resource.playerType.isEmpty ? ep.playerType : resource.playerType
        let resolver: PlayerView.Resolver? = single ? nil : { _, i in
            guard list.indices.contains(i) else { return .failed("集数越界") }
            return await resolve(list[i], episodeIndex: i)
        }
        playSelection = FWDPlaySelection(
            episodes: refs, index: idx, initial: (resource.url, resource.customHeaders),
            resolver: resolver,
            danmakuLoader: { i in
                guard list.indices.contains(i) else { return nil }
                return await FWDDanmu.fetch(record: record, item: list[i], episodeIndex: i,
                                            seriesTitle: single ? nil : full.title)
            },
            danmakuForced: FWDDanmu.hasDanmu(meta),
            playerType: playerType,
            continuousPlay: meta.continuousPlay
                || ["music", "audiobook"].contains(meta.effectiveContentType),
            initialSubtitles: subtitles,
            subtitleLoader: { i in
                guard list.indices.contains(i) else { return [] }
                return await resolveSubtitles(list[i], episodeIndex: i)
            })
    }
}
