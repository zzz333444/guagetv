import Foundation
import SwiftUI

/// Emby client + browser (v1.41): sign in with the user's own
/// server account, browse libraries / latest / series episodes,
/// and play through the normal PlayerView via direct-stream
/// URLs. Credentials live only in local AppStorage.
enum EmbyClient {
    /// One signed-in Emby server (multi-server since v1.74 — the
    /// user asked to keep several servers logged in at once). Only
    /// the access token is stored, never the password.
    struct Server: Codable, Identifiable {
        var id: String        // url + "|" + userID, one entry per account
        var name: String      // account display name from the server
        var url: String
        var userID: String
        var token: String
        var userName: String
        /// v2.44: last time this server answered a browse call
        /// (home load or a fresh login). Nil = never synced yet;
        /// old installs decode without the key and get nil.
        var lastSyncAt: Date? = nil
    }

    private static let serversKey = "emby.servers.v1"
    private static let activeKey = "emby.activeServerID"

    static var servers: [Server] {
        if let data = UserDefaults.standard.data(forKey: serversKey),
           let list = try? JSONDecoder().decode([Server].self, from: data) {
            return list
        }
        // Pre-multi-server install: the legacy keys are one server.
        let url = UserDefaults.standard.string(forKey: "emby.url") ?? ""
        let token = UserDefaults.standard.string(forKey: "emby.token") ?? ""
        let uid = UserDefaults.standard.string(forKey: "emby.userId") ?? ""
        guard !url.isEmpty, !token.isEmpty, !uid.isEmpty else { return [] }
        return [Server(id: url + "|" + uid, name: url, url: url,
                       userID: uid, token: token,
                       userName: UserDefaults.standard.string(forKey: "emby.user") ?? "")]
    }

    private static func saveServers(_ list: [Server]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: serversKey)
        }
    }

    static var activeServer: Server? {
        let list = servers
        guard !list.isEmpty else { return nil }
        let wanted = UserDefaults.standard.string(forKey: activeKey) ?? ""
        return list.first { $0.id == wanted } ?? list[0]
    }

    static var activeServerID: String { activeServer?.id ?? "" }
    static var activeServerName: String { activeServer?.name ?? "" }

    static var base: String { activeServer?.url ?? "" }
    static var token: String { activeServer?.token ?? "" }
    static var userID: String { activeServer?.userID ?? "" }
    static var configured: Bool { activeServer != nil }

    /// Keep the legacy single-server keys pointing at the active
    /// server: Backup whitelists the whole emby. prefix, and any
    /// reader of emby.url keeps seeing the current server.
    private static func syncLegacy() {
        let d = UserDefaults.standard
        if let s = activeServer {
            d.set(s.url, forKey: "emby.url")
            d.set(s.token, forKey: "emby.token")
            d.set(s.userID, forKey: "emby.userId")
        } else {
            d.removeObject(forKey: "emby.token")
            d.removeObject(forKey: "emby.userId")
        }
    }

    static func setActiveServer(_ id: String) {
        UserDefaults.standard.set(id, forKey: activeKey)
        syncLegacy()
    }

    /// v2.44: stamp a successful browse as this server's last
    /// sync. Called from EmbyHomeView after libraryViews lands;
    /// a login counts too (see authenticate).
    static func noteSync(serverID: String? = nil) {
        let id = serverID ?? activeServerID
        guard !id.isEmpty else { return }
        var list = servers
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        list[idx].lastSyncAt = Date()
        saveServers(list)
    }

    /// v2.44: short "MM-dd HH:mm" for the server card, or nil
    /// when this server has never synced.
    static func lastSyncText(serverID: String) -> String? {
        guard let at = servers.first(where: { $0.id == serverID })?.lastSyncAt else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: at)
    }

    static func removeServer(_ id: String) {
        var list = servers
        list.removeAll { $0.id == id }
        saveServers(list)
        let wanted = UserDefaults.standard.string(forKey: activeKey) ?? ""
        if !list.contains(where: { $0.id == wanted }) {
            UserDefaults.standard.set(list.first?.id ?? "", forKey: activeKey)
        }
        syncLegacy()
        // v2.55: drop the removed server's cached posters — its
        // art must not linger (or resurface under a re-added
        // server with the same item ids).
        Task { await PosterCache.shared.clearEmbyPosters(serverID: id) }
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
        var positionTicks: Int64 = 0   // resume position (UserData)
        var runTimeTicks: Int64 = 0
        var rating: Double = 0         // CommunityRating
        /// v2.61: starred on the server (UserData.IsFavorite).
        /// List endpoints may omit UserData — the movie detail
        /// page re-reads it from the full-item fetch.
        var isFavorite: Bool = false
        /// v2.12 detail alignment: only the full-item fetch carries
        /// these (list endpoints don't return People), so they stay
        /// empty until itemDetail() fills them in.
        var genres: [String] = []
        var officialRating: String = ""  // e.g. PG-13
        var people: [(name: String, role: String)] = []
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
        // Upsert into the multi-server list and make it active;
        // signing in on another server no longer evicts the first.
        let server = Server(id: root + "|" + uid,
                            name: (userObj["Name"] as? String) ?? user,
                            url: root, userID: uid,
                            token: accessToken, userName: user,
                            lastSyncAt: Date())
        var list = servers
        if let idx = list.firstIndex(where: { $0.id == server.id }) {
            list[idx] = server
        } else {
            list.append(server)
        }
        saveServers(list)
        UserDefaults.standard.set(server.id, forKey: activeKey)
        syncLegacy()
        return server.name
    }

    /// Sign out = drop the ACTIVE server from the list; any other
    /// signed-in server becomes active in its place.
    static func signOut() {
        let id = activeServerID
        if !id.isEmpty { removeServer(id) }
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
            item.runTimeTicks = ticks
            let minutes = Int(ticks / 10_000_000 / 60)
            item.runtimeText = minutes >= 60 ? "\(minutes / 60)小时\(minutes % 60)分" : "\(minutes)分钟"
        }
        if let r = (raw["CommunityRating"] as? NSNumber)?.doubleValue {
            item.rating = r
        }
        item.genres = (raw["Genres"] as? [String]) ?? []
        item.officialRating = (raw["OfficialRating"] as? String) ?? ""
        // v2.12: People only arrives on the full-item fetch.
        // Keep actors + directors; a director's Role is usually
        // "Director", shown as 导演 when the server sends none.
        if let people = raw["People"] as? [[String: Any]] {
            item.people = people.compactMap { p in
                guard let name = p["Name"] as? String, !name.isEmpty else { return nil }
                let type = (p["Type"] as? String) ?? ""
                guard type == "Actor" || type == "Director" else { return nil }
                var role = (p["Role"] as? String) ?? ""
                if role.isEmpty, type == "Director" { role = "导演" }
                return (name: name, role: role)
            }
        }
        if let ud = raw["UserData"] as? [String: Any],
           let pos = (ud["PlaybackPositionTicks"] as? NSNumber)?.int64Value {
            item.positionTicks = pos
        }
        if let ud = raw["UserData"] as? [String: Any] {
            item.isFavorite = (ud["IsFavorite"] as? Bool) ?? false
        }
        return item
    }

    static func imageURL(itemID: String) -> String {
        "\(base)/Items/\(itemID)/Images/Primary?api_key=\(token)&maxHeight=480"
    }

    /// v2.44: stable poster-cache key for one item on one server.
    /// The fetch URL carries api_key, and the token rotates on
    /// re-login — keying the disk cache on the URL orphaned every
    /// cached poster. The key here is server id (url + userID) +
    /// item id, so posters survive token rotation and two servers
    /// never share one item's cached art.
    static func imageCacheKey(itemID: String) -> String {
        "emby|\(activeServerID)|\(itemID)"
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

    /// In-progress items for the home page's 继续观看 row,
    /// most recently played first (the server orders Resume).
    static func resume() async throws -> [Item] {
        let json = try await get("/Users/\(userID)/Items/Resume", query: [
            "Limit": "16", "MediaTypes": "Video",
            "Fields": "ProductionYear,Overview",
        ])
        return (json["Items"] as? [[String: Any]] ?? []).compactMap(mapItem)
    }

    /// The user's favourites (starred on the server), newest
    /// favourited content in server order.
    static func favorites() async throws -> [Item] {
        let json = try await get("/Users/\(userID)/Items", query: [
            "Recursive": "true", "Filters": "IsFavorite",
            "IncludeItemTypes": "Movie,Series",
            "Fields": "ProductionYear,Overview,ChildCount,CommunityRating",
            "SortBy": "SortName", "SortOrder": "Ascending",
            "Limit": "24",
        ])
        return (json["Items"] as? [[String: Any]] ?? []).compactMap(mapItem)
    }

    /// Movie / Series totals for the Library card (v1.91).
    /// GET /Items/Counts answers {"MovieCount": n, "SeriesCount": n, …};
    /// a nil on either side means the server didn't answer — the
    /// caller shows — for that side.
    static func libraryCounts() async -> (movies: Int?, series: Int?) {
        guard let json = try? await get("/Items/Counts", query: ["UserId": userID]) else {
            return (nil, nil)
        }
        let movies = (json["MovieCount"] as? NSNumber)?.intValue
        let series = (json["SeriesCount"] as? NSNumber)?.intValue
        return (movies, series)
    }

    /// Star / unstar an item (POST adds, DELETE removes).
    /// Emby's FavoriteItems endpoint, same auth as the rest.
    static func setFavorite(itemID: String, favorite: Bool) async throws {
        var comps = URLComponents(string: base + "/Users/\(userID)/FavoriteItems/\(itemID)")
        comps?.queryItems = [URLQueryItem(name: "api_key", value: token)]
        guard let url = comps?.url else { throw failure("地址拼装失败") }
        var request = URLRequest(url: url)
        request.httpMethod = favorite ? "POST" : "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw failure("服务器拒绝（HTTP \(http.statusCode)）")
        }
    }

    /// Next episode(s) up for a series, from watch progress.
    static func nextUp(seriesID: String) async throws -> [Item] {
        let json = try await get("/Shows/NextUp", query: [
            "UserId": userID, "SeriesId": seriesID, "Limit": "3",
            "Fields": "Overview",
        ])
        return (json["Items"] as? [[String: Any]] ?? []).compactMap(mapItem)
    }

    static func items(parentID: String, recursive: Bool = false,
                      types: String = "", search: String = "",
                      sortBy: String = "SortName",
                      sortOrder: String = "Ascending",
                      limit: Int = 200) async throws -> [Item] {
        var query: [String: String] = [
            "Fields": "ProductionYear,Overview,ChildCount,CommunityRating",
            "SortBy": sortBy, "SortOrder": sortOrder,
            "Limit": "\(limit)",
        ]
        // An empty ParentId used to be sent as `ParentId=`, which the
        // server reads as Guid.Empty and answers with zero rows —
        // that silently broke Emby search (E1 audit).
        if !parentID.isEmpty { query["ParentId"] = parentID }
        if recursive { query["Recursive"] = "true" }
        if !types.isEmpty { query["IncludeItemTypes"] = types }
        if !search.isEmpty {
            query["SearchTerm"] = search
            query["Recursive"] = "true"
            if types.isEmpty { query["IncludeItemTypes"] = "Movie,Series,Episode,Season" }
        }
        let json = try await get("/Users/\(userID)/Items", query: query)
        return (json["Items"] as? [[String: Any]] ?? []).compactMap(mapItem)
    }

    /// Full single-item fetch (v2.12): the list endpoints never
    /// return People/Genres/OfficialRating, so the series detail
    /// page pulls its own item to fill the media-info card and
    /// the cast row. The bare /Items/{id} response carries them.
    static func itemDetail(id: String) async throws -> Item {
        let json = try await get("/Users/\(userID)/Items/\(id)")
        guard let item = mapItem(json) else { throw failure("服务器返回无法识别") }
        return item
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
        guard let url = URL(string: base + "/Items/\(itemID)/PlaybackInfo?api_key=\(token)") else {
            throw failure("Emby 地址无效")
        }
        var request = URLRequest(url: url)
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
    @State private var resumeItems: [EmbyClient.Item] = []
    @State private var favoriteItems: [EmbyClient.Item] = []
    @State private var libraryLatest: [(library: EmbyClient.Item, items: [EmbyClient.Item])] = []
    @State private var errorText: String?
    @State private var loading = true
    @State private var searchText = ""
    @State private var searchResults: [EmbyClient.Item] = []
    @State private var searching = false
    @State private var searchedKeyword = ""
    @State private var showUnfavoriteError = false
    /// Multi-server: the page renders the ACTIVE server; switching
    /// re-runs load() through .task(id:).
    @State private var activeServerID = EmbyClient.activeServerID

    var body: some View {
        Group {
            if loading {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        SkeletonRowList(count: 2)
                        SkeletonPosterGrid()
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 110)
                }
                .transition(.opacity)
            } else if let errorText {
                EmptyStateCopy.loadFailed(message: errorText,
                                          retry: { Task { await load() } })
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .animation(Theme.animStandard, value: loading)
        .background(AmbientBackground(imageURL: nil))
        .navigationTitle("Emby")
        .navigationBarTitleDisplayMode(.inline)
        .alert("取消收藏失败", isPresented: $showUnfavoriteError) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请检查网络后重试")
        }
        .task(id: activeServerID) { await load() }
    }

    /// Server switcher, shown only when more than one server is
    /// signed in: a glass row with a menu of servers.
    @ViewBuilder
    private var serverSwitcher: some View {
        if EmbyClient.servers.count > 1 {
            Menu {
                ForEach(EmbyClient.servers) { server in
                    Button {
                        Haptics.tap()
                        EmbyClient.setActiveServer(server.id)
                        activeServerID = server.id
                    } label: {
                        if server.id == activeServerID {
                            Label(server.name, systemImage: "checkmark")
                        } else {
                            Text(server.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack").foregroundStyle(Theme.accent)
                    Text(EmbyClient.activeServerName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    Text(EmbyClient.base)
                        .font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2).foregroundStyle(Theme.textDim)
                }
                .padding(12)
                .glassPanel(cornerRadius: 16)
            }
            .buttonStyle(.plain)
        }
    }

    private var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                serverSwitcher
                HStack {
                    TextField("搜索服务器…", text: $searchText)
                        .font(.subheadline)
                        .padding(10)
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                        .onChange(of: searchText) { _, newValue in
                            if newValue.isEmpty { searchResults = []; searchedKeyword = "" }
                        }
                    if !searchText.isEmpty {
                        Button {
                            Haptics.tap()
                            searchText = ""; searchResults = []; searchedKeyword = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Theme.textDim)
                        }
                        .buttonStyle(.plain)
                    }
                    Button("搜索") { Haptics.tap(); Task { await search() } }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                }
                if searching {
                    SkeletonRowList(count: 3)
                        .padding(.vertical, 8)
                        .transition(.opacity)
                } else if !searchedKeyword.isEmpty && searchResults.isEmpty {
                    EmptyStateView(icon: "magnifyingglass",
                                   title: "没有搜到结果",
                                   message: "没有找到与「\(searchedKeyword)」相关的内容，换个关键词试试",
                                   actionTitle: "清除搜索",
                                   action: { searchText = ""; searchResults = []; searchedKeyword = "" },
                                   compact: true)
                }
                if !searchResults.isEmpty {
                    sectionTitle("搜索结果")
                    posterGrid(searchResults)
                }
                if !resumeItems.isEmpty {
                    sectionTitle("继续观看")
                    resumeRow(resumeItems)
                }
                if !favoriteItems.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        sectionTitle("我的收藏")
                        Spacer()
                        Text("长按可取消收藏")
                            .font(.caption2)
                            .foregroundStyle(Theme.textDim)
                    }
                    favoritesRow(favoriteItems)
                }
                sectionTitle("媒体库")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(views) { view in
                        NavigationLink {
                            EmbyLibraryView(library: view)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(view.name)
                                        .foregroundStyle(Theme.text)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    if let count = view.childCount {
                                        Text("\(count) 项")
                                            .font(.caption2)
                                            .foregroundStyle(Theme.textDim)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(14)
                            .background(Theme.glass, in: RoundedRectangle(cornerRadius: Theme.posterRadius))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !latestItems.isEmpty {
                    sectionTitle("最近加入")
                    posterRow(latestItems)
                }
                ForEach(libraryLatest, id: \.library.id) { entry in
                    sectionTitle("\(entry.library.name) · 最新")
                    posterRow(entry.items)
                }
                if views.isEmpty && resumeItems.isEmpty && favoriteItems.isEmpty
                    && latestItems.isEmpty && libraryLatest.isEmpty
                    && searchResults.isEmpty && searchedKeyword.isEmpty {
                    EmptyStateView(icon: "server.rack",
                                   title: "服务器上还没有内容",
                                   message: "在 Emby 里加个媒体库，这里就会出现")
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 110)
        }
        .animation(Theme.animStandard, value: searching)
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
                        PosterImage(urlString: EmbyClient.imageURL(itemID: item.id), cacheKey: EmbyClient.imageCacheKey(itemID: item.id))
                            .aspectRatio(2/3, contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.smallRadius))
                            .background(RoundedRectangle(cornerRadius: Theme.smallRadius).fill(Theme.glass))
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

    /// Wide 16:9 cards with a progress bar and remaining time —
    /// the reference Emby client's home-screen resume row.
    private func resumeRow(_ items: [EmbyClient.Item]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    NavigationLink {
                        EmbyItemDestination(item: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ZStack(alignment: .bottom) {
                                PosterImage(urlString: EmbyClient.imageURL(itemID: item.id), cacheKey: EmbyClient.imageCacheKey(itemID: item.id))
                                    .aspectRatio(16/9, contentMode: .fill)
                                    .frame(width: 232, height: 130)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.smallRadius))
                                    .background(RoundedRectangle(cornerRadius: Theme.smallRadius).fill(Theme.glass))
                                if item.runTimeTicks > 0, item.positionTicks > 0 {
                                    GeometryReader { geo in
                                        Rectangle()
                                            .fill(Theme.accent)
                                            .frame(width: geo.size.width * CGFloat(item.positionTicks) / CGFloat(item.runTimeTicks), height: 3)
                                    }
                                    .frame(height: 3)
                                }
                            }
                            .frame(width: 232, height: 130)
                            Text(item.name)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                                .frame(width: 232, alignment: .leading)
                            Text(resumeSubtitle(item))
                                .font(.caption2)
                                .foregroundStyle(Theme.textDim)
                                .lineLimit(1)
                                .frame(width: 232, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func resumeSubtitle(_ item: EmbyClient.Item) -> String {
        var parts: [String] = []
        if item.type == "Episode", let s = item.parentIndexNumber, let e = item.indexNumber {
            parts.append("第\(s)季 第\(e)集")
        } else if !item.year.isEmpty {
            parts.append(item.year)
        }
        if item.runTimeTicks > 0, item.positionTicks > 0 {
            let remaining = Int((item.runTimeTicks - item.positionTicks) / 10_000_000 / 60)
            if remaining > 0 { parts.append("还剩 \(remaining) 分钟") }
        }
        return parts.joined(separator: " · ")
    }

    /// Shared poster card for the home rows (resume uses its own
    /// wide 16:9 cards, posterGrid its own 3-column cards).
    private func posterCard(_ item: EmbyClient.Item) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            PosterImage(urlString: EmbyClient.imageURL(itemID: item.id), cacheKey: EmbyClient.imageCacheKey(itemID: item.id))
                .aspectRatio(2/3, contentMode: .fill)
                .frame(width: 104, height: 156)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallRadius))
                .background(RoundedRectangle(cornerRadius: Theme.smallRadius).fill(Theme.glass))
            Text(item.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(width: 104, alignment: .leading)
            if !item.year.isEmpty {
                Text(item.year).font(.caption2).foregroundStyle(Theme.textDim)
            }
        }
    }

    /// Horizontal poster strip (home page rows).
    private func posterRow(_ items: [EmbyClient.Item]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    NavigationLink {
                        EmbyItemDestination(item: item)
                    } label: {
                        posterCard(item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Favorites row: same poster cards, but a long-press menu
    /// offers 取消收藏 (DELETE FavoriteItems on the server).
    private func favoritesRow(_ items: [EmbyClient.Item]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    NavigationLink {
                        EmbyItemDestination(item: item)
                    } label: {
                        posterCard(item)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("取消收藏", role: .destructive) {
                            Task { await unfavorite(item) }
                        }
                    }
                }
            }
        }
    }

    private func unfavorite(_ item: EmbyClient.Item) async {
        do {
            try await EmbyClient.setFavorite(itemID: item.id, favorite: false)
            favoriteItems.removeAll { $0.id == item.id }
        } catch {
            showUnfavoriteError = true
        }
    }

    private func load() async {
        loading = true
        errorText = nil
        do {
            views = try await EmbyClient.libraryViews()
            // v2.44: a successful browse is this server's sync
            // stamp — the server card shows "上次同步" from it.
            EmbyClient.noteSync()
            latestItems = (try? await EmbyClient.latest()) ?? []
            resumeItems = (try? await EmbyClient.resume()) ?? []
            favoriteItems = (try? await EmbyClient.favorites()) ?? []
            var rows: [(library: EmbyClient.Item, items: [EmbyClient.Item])] = []
            for view in views.prefix(4) {
                let recent = (try? await EmbyClient.items(
                    parentID: view.id, recursive: true,
                    types: "Movie,Series",
                    sortBy: "DateCreated", sortOrder: "Descending",
                    limit: 12)) ?? []
                if !recent.isEmpty { rows.append((view, recent)) }
            }
            libraryLatest = rows
        } catch {
            errorText = "连接 Emby 失败：\(error.localizedDescription)"
        }
        loading = false
    }

    private func search() async {
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }
        searching = true
        defer { searching = false }
        searchResults = (try? await EmbyClient.items(parentID: "", search: keyword)) ?? []
        searchedKeyword = keyword
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
        case "Movie":
            EmbyMovieView(movie: item)
        case "Episode", "Video":
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
    @State private var sortMode: SortMode = .recent
    @State private var typeFilter: String = ""

    /// Library ordering (v1.57): server-side sorts, defaulting
    /// to newest-added first like the reference client.
    enum SortMode: String, CaseIterable {
        case recent, name, year, rating
        var label: String {
            switch self {
            case .recent: return "最近加入"
            case .name: return "名称"
            case .year: return "年份"
            case .rating: return "评分"
            }
        }
        var params: (by: String, order: String) {
            switch self {
            case .recent: return ("DateCreated", "Descending")
            case .name: return ("SortName", "Ascending")
            case .year: return ("PremiereDate", "Descending")
            case .rating: return ("CommunityRating", "Descending")
            }
        }
    }

    var body: some View {
        Group {
            if loading {
                ScrollView(showsIndicators: false) {
                    SkeletonPosterGrid()
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 110)
                }
                .transition(.opacity)
            } else if let errorText {
                EmptyStateCopy.loadFailed(message: errorText,
                                            retry: { Task { await reload() } })
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            ForEach([("", "全部"), ("Movie", "电影"), ("Series", "剧集")], id: \.0) { option in
                                Text(option.1)
                                    .font(.caption.weight(typeFilter == option.0 ? .semibold : .regular))
                                    .padding(.horizontal, 11).padding(.vertical, 6)
                                    .background(typeFilter == option.0 ? Color.white : Theme.glass, in: Capsule())
                                    .foregroundStyle(typeFilter == option.0 ? .black : Theme.text.opacity(0.85))
                                    .onTapGesture { Haptics.selection(); typeFilter = option.0 }
                            }
                            Spacer()
                        }
                        HStack {
                            Text("共 \(items.count) 部")
                                .font(.caption)
                                .foregroundStyle(Theme.textDim)
                            Spacer()
                            Text("排序 · \(sortMode.label)")
                                .font(.caption)
                                .foregroundStyle(Theme.textDim)
                        }
                        if items.isEmpty {
                            EmptyStateView(icon: "folder",
                                           title: "这个媒体库还没有内容",
                                           message: "服务器上这个库里还没有内容",
                                           compact: true)
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                                      spacing: 16) {
                                ForEach(items) { item in
                                    NavigationLink {
                                        EmbyItemDestination(item: item)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            PosterImage(urlString: EmbyClient.imageURL(itemID: item.id), cacheKey: EmbyClient.imageCacheKey(itemID: item.id))
                                                .aspectRatio(2/3, contentMode: .fill)
                                                .frame(maxWidth: .infinity)
                                                .clipShape(RoundedRectangle(cornerRadius: Theme.smallRadius))
                                                .background(RoundedRectangle(cornerRadius: Theme.smallRadius).fill(Theme.glass))
                                            Text(item.name)
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(Theme.text)
                                                .lineLimit(1)
                                            metaLine(item)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 110)
                }
            }
        }
        .animation(Theme.animStandard, value: loading)
        .background(AmbientBackground(imageURL: nil))
        .navigationTitle(library.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(SortMode.allCases, id: \.self) { mode in
                        Button {
                            Haptics.selection()
                            sortMode = mode
                        } label: {
                            if mode == sortMode {
                                Label(mode.label, systemImage: "checkmark")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundStyle(Theme.text)
                }
            }
        }
        .task(id: sortMode.rawValue + "|" + typeFilter) { await reload() }
    }

    private func metaLine(_ item: EmbyClient.Item) -> some View {
        var parts: [String] = []
        if !item.year.isEmpty { parts.append(item.year) }
        if item.rating > 0 { parts.append("★\(String(format: "%.1f", item.rating))") }
        if item.type == "Series", let count = item.childCount { parts.append("\(count) 季") }
        return Text(parts.joined(separator: " · "))
            .font(.caption2)
            .foregroundStyle(Theme.textDim)
            .lineLimit(1)
    }

    private func reload() async {
        loading = true
        errorText = nil
        do {
            items = try await EmbyClient.items(parentID: library.id,
                                               types: typeFilter,
                                               sortBy: sortMode.params.by,
                                               sortOrder: sortMode.params.order)
        } catch {
            errorText = "读取失败：\(error.localizedDescription)"
        }
        loading = false
    }
}

struct EmbySeriesView: View {
    let series: EmbyClient.Item
    @State private var seasons: [EmbyClient.Item] = []
    @State private var episodes: [EmbyClient.Item] = []
    @State private var nextUpItem: EmbyClient.Item?
    @State private var selectedSeason: EmbyClient.Item?
    @State private var loading = true
    @State private var errorText: String?
    @State private var playSelection: EmbyPlaySelection?
    /// v2.44: one-line download feedback under the season chips
    /// ("已加入下载：第 3 集" / "这一集取不到地址，下载不了").
    @State private var downloadNote: String?
    /// v2.55: in-flight Emby downloads tracked by item id so
    /// the note above can report the actual finish ("第 3 集
    /// 已下载完成") instead of going stale at "已加入下载"
    /// while the user stays on this page. Paused items stay
    /// pending — a retry can still finish them.
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var pendingDownloads: [String: String] = [:]
    @State private var pendingSeason = false
    @State private var batchDone = 0
    @State private var batchFailed = 0
    /// v2.12: full item (People/Genres/OfficialRating) for the
    /// media-info card + cast row; nil until the fetch lands or
    /// when it fails — the page works off `series` either way.
    @State private var detailItem: EmbyClient.Item?

    /// Media-info rows (v2.12): same spec as DetailView's card —
    /// only fields the server actually sent; empty ones dropped.
    private var mediaInfoRows: [(label: String, value: String)] {
        let detail = detailItem ?? series
        return [
            ("来源", "Emby · \(EmbyClient.activeServerName)"),
            ("类型", detail.genres.joined(separator: " / ")),
            ("年份", series.year),
            ("评分", series.rating > 0 ? String(format: "%.1f", series.rating) : ""),
            ("分级", detail.officialRating),
            ("季数", seasons.isEmpty ? "" : "\(seasons.count) 季"),
            ("单集片长", series.runtimeText),
        ].filter { !$0.value.isEmpty }
    }

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
                ScrollView(showsIndicators: false) {
                    SkeletonRowList(count: 5)
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 110)
                }
                .transition(.opacity)
            } else if let errorText {
                EmptyStateCopy.loadFailed(message: errorText,
                                            retry: { Task { await load() } })
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        if series.rating > 0 {
                            HStack(spacing: 8) {
                                StarBarView(value: series.rating)
                                Text(String(format: "%.1f", series.rating))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.text)
                                Text("Emby 评分")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textDim)
                            }
                        }
                        if !series.overview.isEmpty {
                            Text(series.overview)
                                .font(.subheadline)
                                .foregroundStyle(Theme.text.opacity(0.75))
                                .lineSpacing(4)
                        }
                        MediaInfoCard(rows: mediaInfoRows)
                        // v2.27: CastRowView now takes an avatar
                        // slot; Emby people carry none, pass "".
                        CastRowView(people: (detailItem ?? series).people.map { (name: $0.name, role: $0.role, avatar: "") })
                        if let next = nextUpItem {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("接下来").font(.headline).foregroundStyle(Theme.text)
                                Button {
                                    Haptics.medium()
                                    Task { await playSingle(next) }
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(next.indexNumber.map { "第\($0)集" } ?? "下一集")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Theme.text)
                                        if next.indexNumber != nil, !next.name.isEmpty {
                                            Text(next.name)
                                                .font(.subheadline)
                                                .foregroundStyle(Theme.text.opacity(0.75))
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "play.circle.fill")
                                            .foregroundStyle(Theme.accent)
                                    }
                                    .padding(12)
                                    .glassSurface(RoundedRectangle(cornerRadius: Theme.posterRadius, style: .continuous), shadow: false)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(seasons) { season in
                                    Text(season.name)
                                        .font(.subheadline.weight(selectedSeason?.id == season.id ? .semibold : .regular))
                                        .padding(.horizontal, 14).padding(.vertical, 7)
                                        .background(selectedSeason?.id == season.id ? Color.white : Theme.glass, in: Capsule())
                                        .foregroundStyle(selectedSeason?.id == season.id ? .black : Theme.text.opacity(0.85))
                                        .onTapGesture { Haptics.selection(); Task { await pickSeason(season) } }
                                }
                            }
                        }
                        if let note = downloadNote {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(Theme.textDim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(episodes) { ep in
                            Button {
                                Haptics.medium()
                                Task { await playFrom(ep) }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(ep.indexNumber.map { "第\($0)集" } ?? "正片")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Theme.text)
                                        if ep.indexNumber != nil, !ep.name.isEmpty {
                                            Text(ep.name)
                                                .font(.subheadline)
                                                .foregroundStyle(Theme.text.opacity(0.75))
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        if !ep.runtimeText.isEmpty {
                                            Text(ep.runtimeText).font(.caption).foregroundStyle(Theme.textDim)
                                        }
                                        Image(systemName: "play.circle")
                                            .foregroundStyle(Theme.accent)
                                    }
                                    if !ep.overview.isEmpty {
                                        Text(ep.overview)
                                            .font(.caption)
                                            .foregroundStyle(Theme.textDim)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                                .padding(12)
                                .glassSurface(RoundedRectangle(cornerRadius: Theme.posterRadius, style: .continuous), shadow: false)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("下载这一集") {
                                    Haptics.medium()
                                    Task { await downloadEpisode(ep) }
                                }
                                Button("下载整季（\(episodes.count) 集）") {
                                    Haptics.medium()
                                    Task { await downloadSeason() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 110)
                }
            }
        }
        .animation(Theme.animStandard, value: loading)
        // v2.55: ambient glow from the series poster (intensity
        // 0.65, same as the site detail page) instead of a flat
        // background; the cache key is the stable one, so token
        // rotation does not orphan the glow.
        .background(AmbientBackground(
            imageURL: EmbyClient.imageURL(itemID: series.id),
            intensity: 0.65,
            cacheKey: EmbyClient.imageCacheKey(itemID: series.id)))
        .navigationTitle(series.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: downloads.items.map { $0.id + "|" + $0.state }) { _ in
            updateDownloadNotes()
        }
        .fullScreenCover(item: $playSelection) { sel in
            PlayerView(episodes: sel.episodes, startIndex: sel.index,
                       header: [:], title: series.name,
                       initialResolved: sel.initial,
                       resolver: sel.resolver)
        }
        .task { await load() }
    }

    /// First load (and the error-state retry): seasons, the first
    /// season's episodes, and the NextUp card.
    private func load() async {
        loading = true
        errorText = nil
        do {
            seasons = try await EmbyClient.seasons(seriesID: series.id)
            if let first = seasons.first { await pickSeason(first) }
            nextUpItem = (try? await EmbyClient.nextUp(seriesID: series.id))?.first
            // v2.12: non-fatal — People/Genres only enrich the card.
            detailItem = try? await EmbyClient.itemDetail(id: series.id)
        } catch {
            errorText = "读取失败：\(error.localizedDescription)"
        }
        loading = false
    }

    /// NextUp episodes are not necessarily in the selected
    /// season's list, so they play as a one-item selection.
    private func playSingle(_ ep: EmbyClient.Item) async {
        let firstURL = try? await EmbyClient.streamURL(itemID: ep.id)
        playSelection = EmbyPlaySelection(
            episodes: [PlayerView.EpisodeRef(
                name: ep.indexNumber.map { "第\($0)集" } ?? ep.name, url: ep.id)],
            index: 0,
            initial: firstURL.map { ($0, [:]) },
            resolver: { _, _ in
                do {
                    return .ok(url: try await EmbyClient.streamURL(itemID: ep.id), header: [:])
                } catch {
                    return .failed(error.localizedDescription)
                }
            })
    }

    private func pickSeason(_ season: EmbyClient.Item) async {
        selectedSeason = season
        let fetched = (try? await EmbyClient.episodes(seriesID: series.id, seasonID: season.id)) ?? []
        episodes = fetched.sorted { ($0.indexNumber ?? Int.max) < ($1.indexNumber ?? Int.max) }
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

    /// v2.44: Emby downloads ride the existing DownloadManager
    /// engine — same manifest, same HLS/file split, same
    /// vodName grouping on the downloads page as spider lines.
    /// The stream URL comes from PlaybackInfo (direct stream or
    /// static /Videos/.../stream), exactly like playback.
    private func episodeDisplayName(_ ep: EmbyClient.Item) -> String {
        ep.indexNumber.map { "第\($0)集" } ?? ep.name
    }

    private func downloadEpisode(_ ep: EmbyClient.Item) async {
        let name = episodeDisplayName(ep)
        if pendingDownloads.isEmpty { batchDone = 0; batchFailed = 0; pendingSeason = false }
        downloadNote = "正在取 \(name) 的下载地址…"
        guard let url = try? await EmbyClient.streamURL(itemID: ep.id) else {
            downloadNote = "\(name) 取不到播放地址，下载不了"
            return
        }
        guard await DownloadManager.probeDownloadable(url: url, header: [:]) else {
            downloadNote = "\(name) 的地址下载不了"
            return
        }
        guard let item = DownloadManager.shared.enqueue(
            vodName: series.name, episodeName: name,
            pic: EmbyClient.imageURL(itemID: series.id),
            picCacheKey: EmbyClient.imageCacheKey(itemID: series.id),
            url: url, header: [:]) else {
            downloadNote = "\(name) 的地址下载不了"
            return
        }
        // Already finished → say so instead of "已加入下载";
        // still downloading / paused → track it so the note
        // updates when it actually lands (v2.55).
        if item.state == "done" {
            downloadNote = "\(name) 已经下载好了"
            return
        }
        pendingDownloads[item.id] = name
        downloadNote = "已加入下载：\(name)"
    }

    /// Whole current season: resolve up to 3 episodes at a time
    /// (same chunking as DetailView's whole-line download), skip
    /// the ones that won't resolve or probe, report the count.
    private func downloadSeason() async {
        guard !episodes.isEmpty else { return }
        if pendingDownloads.isEmpty { batchDone = 0; batchFailed = 0 }
        pendingSeason = true
        downloadNote = "正在取整季下载地址…"
        var added = 0
        var skipped = 0
        for chunkStart in stride(from: 0, to: episodes.count, by: 3) {
            let chunkEnd = min(chunkStart + 3, episodes.count)
            let outcomes = await withTaskGroup(of: (String, String?).self) { group in
                for ep in episodes[chunkStart..<chunkEnd] {
                    group.addTask {
                        guard let url = try? await EmbyClient.streamURL(itemID: ep.id),
                              await DownloadManager.probeDownloadable(url: url, header: [:])
                        else { return (ep.id, nil) }
                        return (ep.id, url)
                    }
                }
                var results: [(String, String?)] = []
                for await result in group { results.append(result) }
                return results
            }
            for (id, url) in outcomes {
                guard let ep = episodes.first(where: { $0.id == id }),
                      let url else { skipped += 1; continue }
                guard let item = DownloadManager.shared.enqueue(
                    vodName: series.name, episodeName: episodeDisplayName(ep),
                    pic: EmbyClient.imageURL(itemID: series.id),
                    picCacheKey: EmbyClient.imageCacheKey(itemID: series.id),
                    url: url, header: [:]) else { skipped += 1; continue }
                // Already done counts toward the batch total and
                // the finish summary; anything still in flight is
                // tracked so the note updates when it lands.
                if item.state == "done" { batchDone += 1 }
                else { pendingDownloads[item.id] = episodeDisplayName(ep) }
                added += 1
            }
        }
        downloadNote = "整季下载已加入 \(added) 集"
            + (skipped > 0 ? "，\(skipped) 集下不了跳过" : "")
        // Nothing left in flight and every queued episode was
        // already done: report finished at once instead of
        // waiting on a state change that will never come.
        if pendingDownloads.isEmpty && added > 0 && batchDone == added {
            downloadNote = "整季已全部下载完成"
            batchDone = 0; batchFailed = 0; pendingSeason = false
        }
    }

    /// v2.55: fold finished/failed tracked downloads out of
    /// the pending set and report them in the note. Single
    /// episodes report at once; a season batch reports a
    /// summary when its last item resolves. Paused items stay
    /// pending — a retry can still finish them. An item that
    /// vanished from the list (deleted on the downloads page)
    /// leaves the set without counting either way.
    private func updateDownloadNotes() {
        guard !pendingDownloads.isEmpty else { return }
        var finishedName: String?
        // Snapshot first: removing keys while iterating the
        // live dictionary traps at runtime.
        for (id, name) in Array(pendingDownloads) {
            guard let item = downloads.items.first(where: { $0.id == id }) else {
                pendingDownloads.removeValue(forKey: id)
                continue
            }
            switch item.state {
            case "done":
                pendingDownloads.removeValue(forKey: id)
                batchDone += 1
                finishedName = name
            case "failed":
                pendingDownloads.removeValue(forKey: id)
                batchFailed += 1
            default:
                break
            }
        }
        guard pendingDownloads.isEmpty else { return }
        defer { batchDone = 0; batchFailed = 0 }
        if pendingSeason {
            pendingSeason = false
            guard batchDone + batchFailed > 0 else { return }
            downloadNote = "整季下载完成：\(batchDone) 集已下好"
                + (batchFailed > 0 ? "，\(batchFailed) 集失败" : "")
        } else if batchDone > 0 && batchFailed == 0 {
            downloadNote = batchDone == 1
                ? "\(finishedName ?? "") 已下载完成"
                : "已下载完成 \(batchDone) 集"
        } else if batchFailed > 0 {
            downloadNote = "下载失败 \(batchFailed) 集，可去下载页重试"
        }
    }
}

/// Movie detail page (v2.61): movies used to go straight into
/// EmbyPlayLoader — no synopsis, no cast, no media-info card,
/// no favourite/download state. This mirrors EmbySeriesView
/// (same StarBar / MediaInfoCard / CastRowView / ambient glow)
/// and DetailView's white-capsule play + glass action capsule.
/// The play button reuses the EmbyPlayLoader chain (streamURL
/// → single-episode PlayerView) and passes the server's resume
/// position via PlayerView resumeAt, which the series page
/// never did. All movie entries (home rows, library grid)
/// route through EmbyItemDestination, so this page is the
/// single new entry point.
struct EmbyMovieView: View {
    let movie: EmbyClient.Item
    /// v2.12 pattern, same as the series page: the full-item
    /// fetch fills People/Genres/OfficialRating/IsFavorite;
    /// nil until it lands or when it fails — the page works
    /// off `movie` either way.
    @State private var detailItem: EmbyClient.Item?
    @State private var playSelection: MoviePlaySelection?
    @State private var isFavorite: Bool
    @State private var favoriteBusy = false
    @State private var note: String?
    @State private var downloadNote: String?
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var pendingDownloadID: String?

    init(movie: EmbyClient.Item) {
        self.movie = movie
        _isFavorite = State(initialValue: movie.isFavorite)
    }

    /// Media-info rows (v2.12 spec, same as the series page):
    /// only fields the server actually sent; empty ones dropped.
    private var mediaInfoRows: [(label: String, value: String)] {
        let detail = detailItem ?? movie
        return [
            ("来源", "Emby · \(EmbyClient.activeServerName)"),
            ("类型", detail.genres.joined(separator: " / ")),
            ("年份", movie.year),
            ("评分", movie.rating > 0 ? String(format: "%.1f", movie.rating) : ""),
            ("分级", detail.officialRating),
            ("片长", movie.runtimeText),
        ].filter { !$0.value.isEmpty }
    }

    /// Server resume position in seconds; the player only
    /// honours it past 5 seconds (its own resumeAt guard).
    private var resumeSeconds: Double {
        Double(movie.positionTicks) / 10_000_000
    }

    private var hasResume: Bool { resumeSeconds > 5 }

    private var remainingMinutes: Int {
        guard movie.runTimeTicks > movie.positionTicks else { return 0 }
        return Int((movie.runTimeTicks - movie.positionTicks) / 10_000_000 / 60)
    }

    /// v2.61 review — favourite/download parity with the
    /// series page: the series page shows NEITHER (no
    /// favourite control at all; downloads only per episode
    /// via context menu). A movie has no episode list to
    /// carry actions, so this page adds both, on the same
    /// APIs the home favourites row (setFavorite) and the
    /// series page (DownloadManager.enqueue) already use.
    /// Downloaded = a done DownloadManager item filed under
    /// this movie's name (vodName == movie.name).
    private var isDownloaded: Bool {
        downloads.items.contains {
            $0.vodName == movie.name && $0.state == "done"
        }
    }

    private struct MoviePlaySelection: Identifiable {
        var initial: (url: String, header: [String: String])?
        var resumeAt: Double
        var resolver: PlayerView.Resolver?
        var id: String { movieID }
        var movieID: String
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                if movie.rating > 0 {
                    HStack(spacing: 8) {
                        StarBarView(value: movie.rating)
                        Text(String(format: "%.1f", movie.rating))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                        Text("Emby 评分")
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                    }
                }
                if !movie.overview.isEmpty {
                    Text(movie.overview)
                        .font(.subheadline)
                        .foregroundStyle(Theme.text.opacity(0.75))
                        .lineSpacing(4)
                }
                actionRow
                if hasResume, movie.runTimeTicks > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.white.opacity(0.2))
                                    .frame(height: 4)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Theme.accent)
                                    .frame(width: geo.size.width * CGFloat(movie.positionTicks) / CGFloat(movie.runTimeTicks), height: 4)
                            }
                        }
                        .frame(height: 4)
                        Text("已看到 \(Int(resumeSeconds / 60)) 分钟"
                             + (remainingMinutes > 0 ? " · 还剩 \(remainingMinutes) 分钟" : ""))
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                    }
                }
                MediaInfoCard(rows: mediaInfoRows)
                CastRowView(people: (detailItem ?? movie).people.map { (name: $0.name, role: $0.role, avatar: "") })
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let downloadNote {
                    Text(downloadNote)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 110)
        }
        .background(AmbientBackground(
            imageURL: EmbyClient.imageURL(itemID: movie.id),
            intensity: 0.65,
            cacheKey: EmbyClient.imageCacheKey(itemID: movie.id)))
        .navigationTitle(movie.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: downloads.items.map { $0.id + "|" + $0.state }) { _ in
            updateDownloadNote()
        }
        .fullScreenCover(item: $playSelection) { sel in
            PlayerView(episodes: [PlayerView.EpisodeRef(name: movie.name, url: movie.id)],
                       startIndex: 0, header: [:], title: movie.name,
                       resumeAt: sel.resumeAt,
                       initialResolved: sel.initial,
                       resolver: sel.resolver)
        }
        .task {
            if let detail = try? await EmbyClient.itemDetail(id: movie.id) {
                detailItem = detail
                isFavorite = detail.isFavorite
            }
        }
    }

    /// DetailView actionRow, Emby edition: white play capsule
    /// (two lines: 播放/继续播放 + 还剩 X 分钟/片长) + one
    /// glass capsule holding 收藏 / 下载. No 追剧 — that is
    /// the series page's concept; a movie only has 收藏.
    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.medium()
                Task { await play() }
            } label: {
                VStack(spacing: 1) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text(hasResume ? "继续播放" : "播放")
                    }
                    .font(.headline)
                    let subline = hasResume
                        ? (remainingMinutes > 0 ? "还剩 \(remainingMinutes) 分钟" : "")
                        : movie.runtimeText
                    if !subline.isEmpty {
                        Text(subline)
                            .font(.caption.weight(.medium))
                            .opacity(0.65)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.white, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            HStack(spacing: 2) {
                movieActionItem(
                    icon: isFavorite ? "star.fill" : "star",
                    label: isFavorite ? "已收藏" : "收藏",
                    active: isFavorite) {
                        Haptics.tap()
                        Task { await toggleFavorite() }
                    }
                    .disabled(favoriteBusy)
                movieActionItem(
                    icon: isDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle",
                    label: isDownloaded ? "已下载" : "下载",
                    active: isDownloaded) {
                        Haptics.medium()
                        Task { await downloadMovie() }
                    }
                    .disabled(isDownloaded)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Theme.glass, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.glassStroke, lineWidth: 1))
        }
    }

    /// DetailView.actionCapsuleItem, local copy (that one is
    /// private to DetailView): 46pt labeled mini-action.
    private func movieActionItem(icon: String, label: String, active: Bool,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 17))
                Text(label).font(.caption2.weight(.medium))
            }
            .foregroundStyle(active ? Theme.accent : Theme.text)
            .frame(width: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Same shape as the series page's playSingle: pre-resolve
    /// once for instant start; the resolver re-resolves on
    /// demand (line switches / retries) by item id.
    private func play() async {
        let firstURL = try? await EmbyClient.streamURL(itemID: movie.id)
        playSelection = MoviePlaySelection(
            initial: firstURL.map { ($0, [:]) },
            resumeAt: hasResume ? resumeSeconds : 0,
            resolver: { _, _ in
                do {
                    return .ok(url: try await EmbyClient.streamURL(itemID: movie.id), header: [:])
                } catch {
                    return .failed(error.localizedDescription)
                }
            },
            movieID: movie.id)
    }

    private func toggleFavorite() async {
        guard !favoriteBusy else { return }
        favoriteBusy = true
        defer { favoriteBusy = false }
        let target = !isFavorite
        do {
            try await EmbyClient.setFavorite(itemID: movie.id, favorite: target)
            isFavorite = target
            note = target ? "已收藏，可在 Emby 首页收藏行看到" : "已取消收藏"
        } catch {
            note = "收藏失败：\(error.localizedDescription)"
        }
    }

    /// Series page's downloadEpisode, single-item edition:
    /// resolve → probe → enqueue under vodName/episodeName =
    /// the movie's name, then track the item id so the note
    /// reports the real finish (v2.55 pattern).
    private func downloadMovie() async {
        guard !isDownloaded else { return }
        downloadNote = "正在取下载地址…"
        guard let url = try? await EmbyClient.streamURL(itemID: movie.id) else {
            downloadNote = "取不到播放地址，下载不了"
            return
        }
        guard await DownloadManager.probeDownloadable(url: url, header: [:]) else {
            downloadNote = "这个地址下载不了"
            return
        }
        guard let item = DownloadManager.shared.enqueue(
            vodName: movie.name, episodeName: movie.name,
            pic: EmbyClient.imageURL(itemID: movie.id),
            picCacheKey: EmbyClient.imageCacheKey(itemID: movie.id),
            url: url, header: [:]) else {
            downloadNote = "这个地址下载不了"
            return
        }
        if item.state == "done" {
            downloadNote = "已经下载好了"
            return
        }
        pendingDownloadID = item.id
        downloadNote = "已加入下载"
    }

    private func updateDownloadNote() {
        guard let id = pendingDownloadID else { return }
        guard let item = downloads.items.first(where: { $0.id == id }) else {
            pendingDownloadID = nil
            return
        }
        switch item.state {
        case "done":
            pendingDownloadID = nil
            downloadNote = "已下载完成"
        case "failed":
            pendingDownloadID = nil
            downloadNote = "下载失败，可去下载页重试"
        default:
            break
        }
    }
}

/// One-shot loader for an episode / Video: resolve its stream
/// URL, then swap itself for the player. (Movies got their own
/// detail page in v2.61 and no longer come through here.)
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
                // v2.13: bare spinner → hero + rows skeleton while
                // the stream URL is being resolved.
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        SkeletonHero()
                        SkeletonRowList(count: 3)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                }
                .transition(.opacity)
            }
        }
        .animation(Theme.animStandard, value: selection == nil)
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
