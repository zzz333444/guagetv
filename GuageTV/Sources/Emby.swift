import Foundation
import SwiftUI

/// Emby client + browser (v1.41): sign in with the user's own
/// server account, browse libraries / latest / series episodes,
/// and play through the normal PlayerView via direct-stream
/// URLs. Credentials live only in local AppStorage.
enum EmbyClient {
    static var base: String {
        UserDefaults.standard.string(forKey: "emby.url") ?? ""
    }
    static var token: String {
        UserDefaults.standard.string(forKey: "emby.token") ?? ""
    }
    static var userID: String {
        UserDefaults.standard.string(forKey: "emby.userId") ?? ""
    }
    static var configured: Bool {
        !base.isEmpty && !token.isEmpty && !userID.isEmpty
    }

    struct Item: Identifiable {
        var id: String
        var name: String
        var type: String          // Movie | Series | Season | Episode | Folder | CollectionFolder …
        var year: String = ""
        var overview: String = ""
        var runtimeText: String = ""
        var indexNumber: Int?     // episode number
        var parentIndexNumber: Int?
        var childCount: Int?
    }

    private static let clientInfo = "Client=\"GuageTV\", Device=\"iPhone\", DeviceId=\"guagetv-ios\", Version=\"1.41\""

    static func authenticate(base: String, user: String, password: String) async throws -> String {
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: root + "/Users/AuthenticateByName") else {
            throw failure("服务器地址不对")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Emby \(clientInfo)", forHTTPHeaderField: "X-Emby-Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["Username": user, "Pw": password])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw failure("登录失败（HTTP \(http.statusCode)）——检查地址、账号、密码")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["AccessToken"] as? String,
              let userObj = json["User"] as? [String: Any],
              let uid = userObj["Id"] as? String else {
            throw failure("服务器返回无法识别")
        }
        UserDefaults.standard.set(root, forKey: "emby.url")
        UserDefaults.standard.set(accessToken, forKey: "emby.token")
        UserDefaults.standard.set(uid, forKey: "emby.userId")
        return (userObj["Name"] as? String) ?? user
    }

    static func signOut() {
        for key in ["emby.token", "emby.userId"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Emby", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func get(_ path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        var comps = URLComponents(string: base + path)
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "api_key", value: token))
        comps?.queryItems = items
        guard let url = comps?.url else { throw failure("地址拼装失败") }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw failure("服务器返回无法识别")
        }
        return json
    }

    private static func mapItem(_ raw: [String: Any]) -> Item? {
        guard let id = raw["Id"] as? String, let name = raw["Name"] as? String else { return nil }
        var item = Item(id: id, name: name, type: (raw["Type"] as? String) ?? "")
        if let year = (raw["ProductionYear"] as? NSNumber)?.intValue {
            item.year = String(year)
        }
        item.overview = (raw["Overview"] as? String) ?? ""
        item.indexNumber = (raw["IndexNumber"] as? NSNumber)?.intValue
        item.parentIndexNumber = (raw["ParentIndexNumber"] as? NSNumber)?.intValue
        item.childCount = (raw["ChildCount"] as? NSNumber)?.intValue
        if let ticks = (raw["RunTimeTicks"] as? NSNumber)?.int64Value {
            let minutes = Int(ticks / 10_000_000 / 60)
            item.runtimeText = minutes >= 60 ? "\(minutes / 60)小时\(minutes % 60)分" : "\(minutes)分钟"
        }
        return item
    }

    static func imageURL(itemID: String) -> String {
        "\(base)/Items/\(itemID)/Images/Primary?api_key=\(token)&maxHeight=480"
    }

    static func libraryViews() async throws -> [Item] {
        let json = try await get("/Users/\(userID)/Views")
        return (json["Items"] as? [[String: Any]] ?? []).compactMap(mapItem)
    }

    static func latest() async throws -> [Item] {
        // /Items/Latest answers with a bare JSON array.
        var comps = URLComponents(string: base + "/Users/\(userID)/Items/Latest")
        comps?.queryItems = [
            URLQueryItem(name: "Limit", value: "20"),
            URLQueryItem(name: "Fields", value: "ProductionYear,Overview"),
            URLQueryItem(name: "api_key", value: token),
        ]
        guard let url = comps?.url else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        return (rows ?? []).compactMap(mapItem)
    }

    static func items(parentID: String, recursive: Bool = false,
                      types: String = "", search: String = "") async throws -> [Item] {
        var query: [String: String] = [
            "ParentId": parentID,
            "Fields": "ProductionYear,Overview,ChildCount",
            "SortBy": "SortName", "SortOrder": "Ascending",
            "Limit": "200",
        ]
        if recursive { query["Recursive"] = "true" }
        if !types.isEmpty { query["IncludeItemTypes"] = types }
        if !search.isEmpty {
            query["SearchTerm"] = search
            query["Recursive"] = "true"
        }
        let json = try await get("/Users/\(userID)/Items", query: query)
        return (json["Items"] as? [[String: Any]] ?? []).compactMap(mapItem)
    }

    static func seasons(seriesID: String) async throws -> [Item] {
        let json = try await get("/Shows/\(seriesID)/Seasons", query: ["UserId": userID])
        return (json["Items"] as? [[String: Any]] ?? []).compactMap(mapItem)
    }

    static func episodes(seriesID: String, seasonID: String) async throws -> [Item] {
        let json = try await get("/Shows/\(seriesID)/Episodes", query: [
            "UserId": userID, "SeasonId": seasonID, "Fields": "Overview",
        ])
        return (json["Items"] as? [[String: Any]] ?? []).compactMap(mapItem)
    }

    /// Direct-stream URL for a playable item (movie or episode).
    static func streamURL(itemID: String) async throws -> String {
        var request = URLRequest(url: URL(string: base + "/Items/\(itemID)/PlaybackInfo?api_key=\(token)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "UserId": userID,
            "AutoOpenLiveStream": false,
            "DeviceProfile": [
                "MaxStreamingBitrate": 140_000_000,
                "DirectPlayProfiles": [["Container": "mp4,mkv,mov,webm,m4v,ts,m2ts,avi", "Type": "Video"]],
                "TranscodingProfiles": [["Container": "ts", "Type": "Video", "VideoCodec": "h264",
                                          "AudioCodec": "aac", "Protocol": "hls", "MaxAudioChannels": "6"]],
                "SubtitleProfiles": [],
            ],
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sources = json["MediaSources"] as? [[String: Any]],
              let source = sources.first,
              let sourceID = source["Id"] as? String else {
            throw failure("没拿到播放信息")
        }
        if let direct = source["DirectStreamUrl"] as? String, !direct.isEmpty {
            return base + direct
        }
        // Static direct-play URL works for any direct-playable file.
        return "\(base)/Videos/\(itemID)/stream?static=true&mediaSourceId=\(sourceID)&api_key=\(token)"
    }
}

// MARK: - Views

struct EmbyHomeView: View {
    @State private var views: [EmbyClient.Item] = []
    @State private var latestItems: [EmbyClient.Item] = []
    @State private var errorText: String?
    @State private var loading = true
    @State private var searchText = ""
    @State private var searchResults: [EmbyClient.Item] = []

    var body: some View {
        Group {
            if loading {
                ProgressView().tint(Theme.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText {
                Text(errorText)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .background(AmbientBackground(imageURL: nil))
        .navigationTitle("Emby")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    TextField("搜索服务器…", text: $searchText)
                        .font(.subheadline)
                        .padding(10)
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10))
                    Button("搜索") { Task { await search() } }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                if !searchResults.isEmpty {
                    sectionTitle("搜索结果")
                    posterGrid(searchResults)
                }
                sectionTitle("媒体库")
                ForEach(views) { view in
                    NavigationLink {
                        EmbyLibraryView(library: view)
                    } label: {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(Theme.accent)
                            Text(view.name).foregroundStyle(Theme.text)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Theme.textDim)
                        }
                        .padding(14)
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
                if !latestItems.isEmpty {
                    sectionTitle("最近加入")
                    posterGrid(latestItems)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 110)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline).foregroundStyle(Theme.text)
    }

    private func posterGrid(_ items: [EmbyClient.Item]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                  spacing: 16) {
            ForEach(items) { item in
                NavigationLink {
                    EmbyItemDestination(item: item)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        PosterImage(urlString: EmbyClient.imageURL(itemID: item.id))
                            .aspectRatio(2/3, contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.glass))
                        Text(item.name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        if !item.year.isEmpty {
                            Text(item.year).font(.caption2).foregroundStyle(Theme.textDim)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func load() async {
        loading = true
        errorText = nil
        do {
            views = try await EmbyClient.libraryViews()
            latestItems = (try? await EmbyClient.latest()) ?? []
        } catch {
            errorText = "连接 Emby 失败：\(error.localizedDescription)"
        }
        loading = false
    }

    private func search() async {
        guard !searchText.isEmpty else { return }
        searchResults = (try? await EmbyClient.items(parentID: "", search: searchText)) ?? []
    }
}

/// Route a tapped item: playable → straight to the player flow;
/// series → seasons; folder-ish → item grid.
struct EmbyItemDestination: View {
    let item: EmbyClient.Item

    var body: some View {
        switch item.type {
        case "Series":
            EmbySeriesView(series: item)
        case "Movie", "Episode", "Video":
            EmbyPlayLoader(item: item)
        default:
            EmbyLibraryView(library: item)
        }
    }
}

struct EmbyLibraryView: View {
    let library: EmbyClient.Item
    @State private var items: [EmbyClient.Item] = []
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        Group {
            if loading {
                ProgressView().tint(Theme.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText {
                Text(errorText).font(.subheadline).foregroundStyle(Theme.textDim).padding(24)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                              spacing: 16) {
                        ForEach(items) { item in
                            NavigationLink {
                                EmbyItemDestination(item: item)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    PosterImage(urlString: EmbyClient.imageURL(itemID: item.id))
                                        .aspectRatio(2/3, contentMode: .fill)
                                        .frame(maxWidth: .infinity)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.glass))
                                    Text(item.name)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 110)
                }
            }
        }
        .background(AmbientBackground(imageURL: nil))
        .navigationTitle(library.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                items = try await EmbyClient.items(parentID: library.id)
            } catch {
                errorText = "读取失败：\(error.localizedDescription)"
            }
            loading = false
        }
    }
}

struct EmbySeriesView: View {
    let series: EmbyClient.Item
    @State private var seasons: [EmbyClient.Item] = []
    @State private var episodes: [EmbyClient.Item] = []
    @State private var selectedSeason: EmbyClient.Item?
    @State private var loading = true
    @State private var errorText: String?
    @State private var playSelection: EmbyPlaySelection?

    private struct EmbyPlaySelection: Identifiable {
        var episodes: [PlayerView.EpisodeRef]
        var index: Int
        var initial: (url: String, header: [String: String])?
        var resolver: PlayerView.Resolver?
        var id: String { episodes[index].url + "#\(index)" }
    }

    var body: some View {
        Group {
            if loading {
                ProgressView().tint(Theme.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText {
                Text(errorText).font(.subheadline).foregroundStyle(Theme.textDim).padding(24)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        if !series.overview.isEmpty {
                            Text(series.overview)
                                .font(.subheadline)
                                .foregroundStyle(Theme.text.opacity(0.75))
                                .lineSpacing(4)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(seasons) { season in
                                    Text(season.name)
                                        .font(.subheadline.weight(selectedSeason?.id == season.id ? .semibold : .regular))
                                        .padding(.horizontal, 14).padding(.vertical, 7)
                                        .background(selectedSeason?.id == season.id ? Color.white : Theme.glass, in: Capsule())
                                        .foregroundStyle(selectedSeason?.id == season.id ? .black : Theme.text.opacity(0.85))
                                        .onTapGesture { Task { await pickSeason(season) } }
                                }
                            }
                        }
                        ForEach(episodes) { ep in
                            Button {
                                Task { await playFrom(ep) }
                            } label: {
                                HStack(spacing: 12) {
                                    Text(ep.indexNumber.map { "第\($0)集" } ?? ep.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                    Spacer()
                                    if !ep.runtimeText.isEmpty {
                                        Text(ep.runtimeText).font(.caption).foregroundStyle(Theme.textDim)
                                    }
                                    Image(systemName: "play.circle")
                                        .foregroundStyle(Theme.accent)
                                }
                                .padding(12)
                                .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 110)
                }
            }
        }
        .background(AmbientBackground(imageURL: nil))
        .navigationTitle(series.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playSelection) { sel in
            PlayerView(episodes: sel.episodes, startIndex: sel.index,
                       header: [:], title: series.name,
                       initialResolved: sel.initial,
                       resolver: sel.resolver)
        }
        .task {
            do {
                seasons = try await EmbyClient.seasons(seriesID: series.id)
                if let first = seasons.first { await pickSeason(first) }
            } catch {
                errorText = "读取失败：\(error.localizedDescription)"
            }
            loading = false
        }
    }

    private func pickSeason(_ season: EmbyClient.Item) async {
        selectedSeason = season
        episodes = (try? await EmbyClient.episodes(seriesID: series.id, seasonID: season.id)) ?? []
    }

    /// Hand the player the season's episode refs (url = Emby
    /// item id) plus a resolver that turns an id into a stream
    /// URL on demand — the same shape spider lines use.
    private func playFrom(_ tapped: EmbyClient.Item) async {
        guard let start = episodes.firstIndex(where: { $0.id == tapped.id }) else { return }
        let refs = episodes.map {
            PlayerView.EpisodeRef(name: $0.indexNumber.map { "第\($0)集" } ?? $0.name, url: $0.id)
        }
        let ids = episodes.map(\.id)
        let firstURL = try? await EmbyClient.streamURL(itemID: tapped.id)
        playSelection = EmbyPlaySelection(
            episodes: refs, index: start,
            initial: firstURL.map { ($0, [:]) },
            resolver: { _, idx in
                guard ids.indices.contains(idx) else { return .failed("集数越界") }
                do {
                    return .ok(url: try await EmbyClient.streamURL(itemID: ids[idx]), header: [:])
                } catch {
                    return .failed(error.localizedDescription)
                }
            })
    }
}

/// One-shot loader for a movie: resolve its stream URL, then
/// swap itself for the player.
struct EmbyPlayLoader: View {
    let item: EmbyClient.Item
    @State private var selection: SinglePlay?
    @State private var errorText: String?

    private struct SinglePlay: Identifiable {
        var url: String
        var id: String { url }
    }

    var body: some View {
        Group {
            if let errorText {
                Text(errorText).font(.subheadline).foregroundStyle(Theme.textDim).padding(24)
            } else {
                ProgressView().tint(Theme.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AmbientBackground(imageURL: nil))
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selection) { sel in
            PlayerView(episodes: [PlayerView.EpisodeRef(name: item.name, url: sel.url)],
                       startIndex: 0, header: [:], title: item.name)
        }
        .task {
            do {
                selection = SinglePlay(url: try await EmbyClient.streamURL(itemID: item.id))
            } catch {
                errorText = "取播放地址失败：\(error.localizedDescription)"
            }
        }
    }
}
