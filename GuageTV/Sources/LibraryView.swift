import SwiftUI

/// 资源库 (Library) — Rex's two-column source cards: icon, name, route line,
/// content counts, freshness + status dot. Backed by the imported config's
/// sites; counts/freshness fill in once a source has been synced.
struct LibraryView: View {
    @Binding var config: TVBoxConfig?
    var onImportTap: () -> Void = {}
    @State private var entries: [ConfigLibrary.Entry] = []
    @State private var activeID: String?
    @State private var groups: [ConfigLibrary.Group] = []
    @State private var showGroupEditor = false
    /// Per-line "CMS 12 · py 3 · Jar 5" summaries, computed on appear
    /// from the stored configs (local files, cheap).
    @State private var kindSummary: [String: String] = [:]
    /// Line cards precomputed at refresh time: the grid renders
    /// these models only and never re-derives card content in body.
    /// Sections carry a stable id (group UUID / "loose"): the
    /// section TITLE is not an identity — it flips between
    /// "我的线路" and "未分组" as groups appear, and two groups may
    /// share a name, so keying ForEach on title collapsed or
    /// rebuilt whole sections on rename/group changes.
    @State private var cardSections: [(id: String, title: String, models: [LineCardModel])] = []
    /// The automatic Python-file group, collapsed into ONE entry
    /// card (v1.58, user request): tapping it opens a picker page
    /// listing the py sites instead of one card per file.
    @State private var pyGroupEntries: [ConfigLibrary.Entry] = []
    @State private var renamingEntry: ConfigLibrary.Entry?
    @State private var renameText = ""
    /// Manual line refresh (v1.87): in-flight ids, the all-lines
    /// flag, and the bottom toast that reports each outcome.
    @State private var refreshingLineIDs: Set<String> = []
    @State private var refreshingAll = false
    @State private var lineToast: String?
    @State private var lineToastGeneration = 0
    /// 资源库配置排序（v1.81）：名称 / 站点数 / 最近使用。
    /// 排序只作用于分组内的线路卡片顺序，分组本身的创建顺序不动。
    private enum LibrarySort: String, CaseIterable {
        case name, siteCount, recent
        var label: String {
            switch self {
            case .name: return "名称"
            case .siteCount: return "站点数"
            case .recent: return "最近使用"
            }
        }
    }
    private static let sortKey = "librarySort.v1"
    @State private var sortMode: LibrarySort = LibrarySort(rawValue: UserDefaults.standard.string(forKey: sortKey) ?? "") ?? .name
    /// Direct-open route for single-file (py / JS) lines: tapping
    /// the card pushes its one site's browse page immediately.
    @State private var directRoute: FileSiteRoute?
    /// v2.30: direct-open routes, computed ONCE per refresh.
    /// fileRoute(for:) parses the line's stored config off disk,
    /// and both tap sites used to call it from the view body —
    /// i.e. once per card, per body evaluation, on the main
    /// thread. The routes now come from this dictionary; the
    /// body only reads it.
    @State private var fileRoutes: [String: FileSiteRoute] = [:]
    /// Ambient glow source for the page background: the freshest
    /// artwork the user actually has — a continue-watching poster,
    /// else a favourite's. The library used to sit on a flat static
    /// gradient while every other tab glowed (v1.74 glass pass).
    @ObservedObject private var history = HistoryStore.shared
    /// v2.16: the Emby poster prefetch batch handle — leaving the
    /// page cancels the pending queue (see prefetchEmbyPosters).
    @State private var embyPrefetchTask: Task<Void, Never>?

    private var ambientPic: String? {
        history.continueWatching.first?.pic ?? history.favourites.first?.pic
    }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("资源库").font(.largeTitle.bold()).foregroundStyle(Theme.text)
                    Spacer()
                    Menu {
                        Picker("排序", selection: $sortMode) {
                            ForEach(LibrarySort.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                            Text("排序：\(sortMode.label)")
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .glassCapsule()
                        .foregroundStyle(Theme.text)
                    }
                    .onChange(of: sortMode) { _, newMode in
                        UserDefaults.standard.set(newMode.rawValue, forKey: Self.sortKey)
                        Haptics.tap()
                        rebuildCardModels()
                    }
                    Button("编辑") { Haptics.tap(); showGroupEditor = true }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .glassCapsule()
                        .foregroundStyle(Theme.text)
                        .sheet(isPresented: $showGroupEditor, onDismiss: refreshLibrary) {
                            GroupEditorView()
                        }
                    Button {
                        refreshAllLines()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .glassCapsule()
                            .foregroundStyle(Theme.text)
                    }
                    .disabled(refreshingAll)
                }

                MediaHubSection()

                if !pyGroupEntries.isEmpty {
                    Text("Python 站点 · \(pyGroupEntries.count) 个源").font(.headline).foregroundStyle(Theme.section)
                    NavigationLink {
                        PyGroupView(config: $config,
                                    onPick: { entry in
                                        if let route = fileRoutes[entry.id] {
                                            directRoute = route
                                        }
                                    })
                    } label: {
                        LightGlassCard(padding: 14) {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(Theme.accent.opacity(0.25)).frame(width: 38, height: 38)
                                    Text("py").font(.headline).foregroundStyle(Theme.text)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Python 站点")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.text)
                                    Text("共 \(pyGroupEntries.count) 个单文件源 · 点按选择")
                                        .font(.caption).foregroundStyle(Theme.textDim)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(Theme.textDim)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    // v2.21: NavigationLink itself fires no haptic —
                    // tap the card, feel the tap.
                    .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
                }

                ForEach(cardSections, id: \.id) { section in
                    Text(section.title).font(.headline).foregroundStyle(Theme.section)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(section.models) { model in
                            LineCardView(model: model, groups: groups,
                                         onTap: { handleLineTap(model) },
                                         onRename: {
                                             renameText = ConfigLibrary.alias(for: model.id) ?? ""
                                             renamingEntry = model.entry
                                         },
                                         onSetHome: {
                                             ConfigLibrary.setHomeLineID(model.id)
                                             refreshLibrary()
                                         },
                                         onMoveToGroup: { groupID in
                                             ConfigLibrary.setGroup(entryID: model.id, groupID: groupID)
                                             refreshLibrary()
                                         },
                                         onDelete: {
                                             config = ConfigLibrary.remove(id: model.id)
                                             refreshLibrary()
                                         },
                                         onRefresh: model.entry.sourceURL.hasPrefix("http")
                                             ? { refreshLine(model) } : nil)
                                .equatable()
                        }
                    }
                }

                if let sites = config?.sites, !sites.isEmpty {
                    Text("点播源").font(.headline).foregroundStyle(Theme.section)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(sites) { site in
                            NavigationLink {
                                SiteBrowseView(site: site, parses: config?.parses ?? [])
                            } label: {
                                sourceCard(site)
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
                        }
                    }
                } else {
                    EmptyStateView(icon: "tray.and.arrow.down",
                                   title: "还没有资源",
                                   message: "导入一个 TVBox 配置或猫源，站点会出现在这里",
                                   actionTitle: "去导入",
                                   action: onImportTap)
                }

                if let lives = config?.lives, !lives.isEmpty {
                    Text("直播源").font(.headline).foregroundStyle(Theme.section)
                    LazyVGrid(columns: columns, spacing: 12) {
                        // Live names repeat across sources, so the
                        // row id is name + URL, not name alone.
                        ForEach(lives, id: \.liveID) { live in
                            NavigationLink {
                                LiveView(live: live)
                            } label: {
                                GlassCard(padding: 14) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Image(systemName: "tv").foregroundStyle(Theme.accent)
                                        Text(live.name).font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Theme.text).lineLimit(1)
                                        Text("直播线路").font(.caption).foregroundStyle(Theme.textDim)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .background(AmbientBackground(imageURL: ambientPic))
        .overlay(alignment: .bottom) {
            if let lineToast {
                Text(lineToast)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassCapsule()
                    .padding(.bottom, 118)
                    .transition(.opacity)
            }
        }
        .animation(Theme.animQuick, value: lineToast)
        .onAppear { refreshLibrary() }
        .onDisappear { embyPrefetchTask?.cancel() }
        .alert("线路备注名", isPresented: Binding(get: { renamingEntry != nil },
                                                set: { if !$0 { renamingEntry = nil } })) {
            TextField("备注名（留空恢复原名）", text: $renameText)
            Button("保存") {
                if let entry = renamingEntry {
                    ConfigLibrary.setAlias(renameText, for: entry.id)
                }
                renamingEntry = nil
                refreshLibrary()
            }
            Button("取消", role: .cancel) { renamingEntry = nil }
        }
        .navigationDestination(item: $directRoute) { route in
            if route.isJS {
                JSSiteBrowseView(site: route.site, parses: route.parses)
            } else {
                PySiteBrowseView(site: route.site, parses: route.parses)
            }
        }
        }
    }

    /// Long-press → 更新线路 (v1.87): fetch the line's remote config
    /// now and report the outcome in the bottom toast.
    private func refreshLine(_ model: LineCardModel) {
        let id = model.id
        guard !refreshingLineIDs.contains(id) else { return }
        refreshingLineIDs.insert(id)
        Haptics.tap()
        showLineToast("正在更新「\(model.shownName)」…")
        Task {
            let outcome = await ConfigLibrary.refreshEntry(id: id)
            refreshingLineIDs.remove(id)
            switch outcome {
            case .updated(let count):
                showLineToast("「\(model.shownName)」已更新：\(count) 个站点")
            case .alreadyLatest:
                showLineToast("「\(model.shownName)」已是最新")
            case .notRemote:
                showLineToast("本地线路没有远程地址，不能更新")
            case .failed(let why):
                showLineToast("更新失败：\(why)")
            }
            refreshLibrary()
        }
    }

    /// Header ↻ button: refresh every remote line, one summary toast.
    private func refreshAllLines() {
        guard !refreshingAll else { return }
        refreshingAll = true
        Haptics.tap()
        showLineToast("正在更新全部线路…")
        Task {
            let tally = await ConfigLibrary.refreshAllEntries()
            refreshingAll = false
            var parts: [String] = []
            if tally.updated > 0 { parts.append("\(tally.updated) 条已更新") }
            if tally.latest > 0 { parts.append("\(tally.latest) 条已是最新") }
            if tally.failed > 0 { parts.append("\(tally.failed) 条失败") }
            showLineToast(parts.isEmpty ? "没有可更新的远程线路" : "更新完成：" + parts.joined(separator: "、"))
            refreshLibrary()
        }
    }

    private func showLineToast(_ text: String) {
        lineToast = text
        lineToastGeneration += 1
        let generation = lineToastGeneration
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if lineToastGeneration == generation { lineToast = nil }
        }
    }

    /// Cached per-line kind summaries. Parsing every stored config
    /// on the main thread made the library scroll stutter, so:
    /// appear paints the UserDefaults cache instantly, then a
    /// detached task recomputes off-main and rewrites the cache
    /// (rebuilt from the live entry list, so imports/deletes
    /// invalidate stale rows automatically).
    private static let kindSummaryCacheKey = "libraryKindSummary.v2"
    private static let kindSummaryTimestampKey = "libraryKindSummary.v2.ts"

    private func refreshLibrary() {
        entries = ConfigLibrary.entries()
        activeID = ConfigLibrary.activeID()
        groups = ConfigLibrary.groups()
        // v2.30: routes for single-file lines, once per refresh
        // (see fileRoutes) instead of once per card per body eval.
        fileRoutes = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            fileRoute(for: entry).map { (entry.id, $0) }
        })
        let liveIDs = Set(entries.map(\.id))
        if let cached = UserDefaults.standard.dictionary(forKey: Self.kindSummaryCacheKey) as? [String: String] {
            kindSummary = cached.filter { liveIDs.contains($0.key) }
        }
        rebuildCardModels()
        // Throttle the off-main recompute: a cache younger than
        // 5 minutes is trusted on repeat appears, unless a live line
        // is missing from it (a fresh import must not wait 5 min).
        let cacheCoversAll = liveIDs.allSatisfy { kindSummary[$0] != nil }
        let cacheAge = Date().timeIntervalSince1970
            - UserDefaults.standard.double(forKey: Self.kindSummaryTimestampKey)
        guard !cacheCoversAll || cacheAge > 300 else { return }
        let snapshot = entries
        Task.detached(priority: .utility) {
            let summary = Self.computeKindSummary(for: snapshot)
            UserDefaults.standard.set(summary, forKey: Self.kindSummaryCacheKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970,
                                      forKey: Self.kindSummaryTimestampKey)
            await MainActor.run {
                kindSummary = summary
                rebuildCardModels()
            }
        }
    }

    private static func computeKindSummary(for entries: [ConfigLibrary.Entry]) -> [String: String] {
        var summary: [String: String] = [:]
        for entry in entries {
            guard let cfg = ConfigLibrary.load(id: entry.id) else { continue }
            var counts: [String: Int] = [:]
            for site in cfg.sites {
                switch site.kind {
                case .cmsXML, .cmsJSON: counts["CMS", default: 0] += 1
                case .spiderPY: counts["py", default: 0] += 1
                case .spiderJS, .drpyJS: counts["JS", default: 0] += 1
                case .spiderJAR: counts["Jar", default: 0] += 1
                case .unknown: counts["其他", default: 0] += 1
                }
            }
            let parts = ["CMS", "py", "JS", "Jar", "其他"].compactMap { key -> String? in
                guard let n = counts[key], n > 0 else { return nil }
                return "\(key) \(n)"
            }
            summary[entry.id] = parts.isEmpty ? "\(entry.siteCount) 个站点" : parts.joined(separator: " · ")
        }
        return summary
    }

    /// A single-file line's direct-open route, when this entry is a
    /// py / JS file import whose stored config loads.
    private func fileRoute(for entry: ConfigLibrary.Entry) -> FileSiteRoute? {
        let isPy = ConfigLibrary.isPyFileEntry(entry)
        let isJS = entry.sourceURL.hasPrefix("js-import://")
        guard isPy || isJS,
              let cfg = ConfigLibrary.load(id: entry.id),
              let site = cfg.sites.first else { return nil }
        return FileSiteRoute(site: site, parses: cfg.parses ?? [], isJS: isJS)
    }

    /// "今天 / 昨天 / N天前 / N周前 / N月前" for a line's import day.
    private static func relativeDay(_ ts: TimeInterval) -> String {
        let days = Calendar.current.dateComponents(
            [.day], from: Date(timeIntervalSince1970: ts), to: Date()).day ?? 0
        switch days {
        case ..<1: return "今天"
        case 1: return "昨天"
        case 2..<7: return "\(days)天前"
        case 7..<30: return "\(days / 7)周前"
        default: return "\(days / 30)月前"
        }
    }

    /// Rebuild the precomputed card sections from the current
    /// entries / groups / summaries. Section order: custom groups
    /// (creation order) → the automatic Python 文件 group →
    /// ungrouped lines. Everything a card shows (name, icon letter,
    /// freshness, role, kind summary) is frozen into the model here
    /// so the grid's body never re-derives it while scrolling.
    private func rebuildCardModels() {
        let homeID = ConfigLibrary.homeLineID()
        func model(_ entry: ConfigLibrary.Entry) -> LineCardModel {
            let shown = ConfigLibrary.shownName(entry)
            let isActive = entry.id == activeID
            let isHome = entry.id == homeID
            let isFile = ConfigLibrary.isPyFileEntry(entry) || entry.sourceURL.hasPrefix("js-import://")
            // No tap-hint role lines at all (the user asked off
            // first "点按打开" on file cards, then "点按启用" on
            // plain lines): only the real states 主线路 / 首页线路
            // still show.
            let role = isActive ? "主线路" : (isHome ? "首页线路" : "")
            return LineCardModel(entry: entry,
                                 shownName: shown,
                                 iconText: String(shown.prefix(1)),
                                 freshnessText: Self.relativeDay(max(entry.addedAt, ConfigLibrary.lastRefreshAt(id: entry.id) ?? entry.addedAt)),
                                 isActive: isActive, isHome: isHome, isFile: isFile,
                                 roleText: role,
                                 kindText: kindSummary[entry.id] ?? "\(entry.siteCount) 个站点")
        }
        var sections: [(id: String, title: String, models: [LineCardModel])] = []
        for group in groups {
            let items = sortedEntries(entries.filter { ConfigLibrary.effectiveGroupID(for: $0) == group.id })
            if !items.isEmpty { sections.append((group.id, sectionTitle(group.name, items), items.map(model))) }
        }
        // Python files no longer render as a card grid: they
        // collapse into the single group entry above the sections.
        pyGroupEntries = sortedEntries(entries.filter {
            ConfigLibrary.effectiveGroupID(for: $0) == ConfigLibrary.pyAutoGroupID
        })
        let loose = sortedEntries(entries.filter { ConfigLibrary.effectiveGroupID(for: $0) == nil })
        if !loose.isEmpty {
            sections.append(("loose", sectionTitle(sections.isEmpty && pyGroupEntries.isEmpty ? "我的线路" : "未分组", loose), loose.map(model)))
        }
        cardSections = sections
        prefetchEmbyPosters()
    }

    /// 分组头带站点数（v1.81）："分组名 · N 站"，N 为组内各线路
    /// siteCount 之和；无站点记录的线路按 0 计。
    private func sectionTitle(_ name: String, _ items: [ConfigLibrary.Entry]) -> String {
        let total = items.reduce(0) { $0 + $1.siteCount }
        return "\(name) · \(total) 站"
    }

    /// 按当前排序模式排一组线路。名称用本地化比较；站点数降序；
    /// 最近使用按上次激活时间降序，无记录回退导入时间。
    private func sortedEntries(_ list: [ConfigLibrary.Entry]) -> [ConfigLibrary.Entry] {
        switch sortMode {
        case .name:
            return list.sorted {
                ConfigLibrary.shownName($0).localizedStandardCompare(ConfigLibrary.shownName($1)) == .orderedAscending
            }
        case .siteCount:
            return list.sorted {
                if $0.siteCount != $1.siteCount { return $0.siteCount > $1.siteCount }
                return ConfigLibrary.shownName($0).localizedStandardCompare(ConfigLibrary.shownName($1)) == .orderedAscending
            }
        case .recent:
            return list.sorted {
                let a = ConfigLibrary.lastUsedAt(for: $0.id) ?? $0.addedAt
                let b = ConfigLibrary.lastUsedAt(for: $1.id) ?? $1.addedAt
                if a != b { return a > b }
                return ConfigLibrary.shownName($0).localizedStandardCompare(ConfigLibrary.shownName($1)) == .orderedAscending
            }
        }
    }

    /// F1: the library page itself shows no posters, but its
    /// MediaHubSection leads straight into Emby home, whose
    /// 继续观看 / 我的收藏 / 最近加入 rows are all poster grids.
    /// Warm those posters while the user is still on this page, so
    /// Emby home opens with art already in PosterCache instead of
    /// flashing in row by row. Throttled to once per 10 minutes and
    /// fully silent on failure — a prefetch must never surface an
    /// error or block the library. Line cards and source cards have
    /// no poster URL (icon letter only), so there is nothing else
    /// on this page to warm.
    /// v2.16: routed through the cancellable PosterCache.prefetch
    /// batch (replacing the old un-cancellable detached task) and
    /// re-fetched at 480 px — the Emby grids are 480 px cells;
    /// leaving the page cancels the pending queue.
    private static let embyPrefetchTimestampKey = "libraryEmbyPrefetch.ts"

    private func prefetchEmbyPosters() {
        guard EmbyClient.configured else { return }
        let last = UserDefaults.standard.double(forKey: Self.embyPrefetchTimestampKey)
        guard Date().timeIntervalSince1970 - last > 600 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970,
                                  forKey: Self.embyPrefetchTimestampKey)
        embyPrefetchTask?.cancel()
        // A plain Task (not detached) inherits the main actor, so
        // the embyPrefetchTask assignment below stays on the main
        // thread; the EmbyClient awaits suspend off-thread.
        embyPrefetchTask = Task(priority: .utility) {
            let resume = (try? await EmbyClient.resume()) ?? []
            let favorites = (try? await EmbyClient.favorites()) ?? []
            let latest = (try? await EmbyClient.latest()) ?? []
            let urls = Array(Set(
                (Array(resume.prefix(5)) + Array(favorites.prefix(5)) + Array(latest.prefix(5)))
                    .map { EmbyClient.imageURL(itemID: $0.id) }
            )).prefix(14)
            guard !Task.isCancelled else { return }
            embyPrefetchTask = PosterCache.shared.prefetch(Array(urls))
        }
    }

    /// Card tap (from LineCardView): single-file lines (py / JS
    /// imports) open their one site directly; other lines activate.
    /// Deletion lives on the long-press menu only (the swipe
    /// reveal was removed at the user's request).
    private func handleLineTap(_ model: LineCardModel) {
        Haptics.tap()
        if let route = fileRoutes[model.id] {
            directRoute = route
            return
        }
        guard !model.isActive else { return }
        config = ConfigLibrary.activate(id: model.id)
        JarProxyClient.warmLine(id: model.id)
        refreshLibrary()
    }


    private func sourceCard(_ site: TVBoxConfig.Site) -> some View {
        LightGlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top) {
                    ZStack {
                        Circle().fill(Theme.accent.opacity(0.25)).frame(width: 38, height: 38)
                        Text(String(site.name.prefix(1)))
                            .font(.headline).foregroundStyle(Theme.text)
                    }
                    Spacer()
                    Circle().fill(site.kind == .spiderJAR ? Color.orange : Theme.ok)
                        .frame(width: 7, height: 7)
                }
                Text(site.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text).lineLimit(1)
                Text(routeText(site))
                    .font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                Text(kindText(site.kind))
                    .font(.caption2).foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func routeText(_ site: TVBoxConfig.Site) -> String {
        site.kind == .spiderJAR ? (JarProxyClient.configured ? "主线路 · Jar 代理" : "主线路 · 需 Jar 代理") : "主线路"
    }

    private func kindText(_ kind: TVBoxConfig.Site.Kind) -> String {
        switch kind {
        case .cmsXML, .cmsJSON: return "CMS 接口"
        case .spiderPY: return "Python 源"
        case .spiderJS: return "JS 源"
        case .drpyJS: return "drpy 源"
        case .spiderJAR: return JarProxyClient.configured ? "Jar 源 · 代理执行" : "Jar 源 · 需设置代理"
        case .unknown: return "未知类型"
        }
    }
}

/// 资源库 → 编辑： create / rename / delete line groups and file
/// every line into one. Group data lives in ConfigLibrary; this
/// sheet is only the editor.
struct GroupEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [ConfigLibrary.Group] = []
    @State private var entries: [ConfigLibrary.Entry] = []
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var renamingGroup: ConfigLibrary.Group?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("分组").font(.headline).foregroundStyle(Theme.section)
                        Spacer()
                        Button {
                            newGroupName = ""
                            showNewGroup = true
                        } label: {
                            Label("新建分组", systemImage: "plus")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Theme.glass, in: Capsule())
                        }
                    }
                    if groups.isEmpty {
                        EmptyStateView(icon: "folder.badge.plus",
                                       title: "还没有自建分组",
                                       message: "导入的 py 文件会自动收进「Python 文件」组。",
                                       compact: true)
                    }
                    ForEach(groups) { group in
                        GlassCard(padding: 14) {
                            HStack(spacing: 10) {
                                Image(systemName: "folder").foregroundStyle(Theme.accent)
                                Text(group.name).font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.text).lineLimit(1)
                                Spacer()
                                Button("改名") {
                                    renameText = group.name
                                    renamingGroup = group
                                }
                                .font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
                                Button("删除") {
                                    ConfigLibrary.removeGroup(id: group.id)
                                    reload()
                                }
                                .font(.caption.weight(.semibold)).foregroundStyle(.red.opacity(0.9))
                            }
                        }
                    }

                    Text("线路归组").font(.headline).foregroundStyle(Theme.section)
                        .padding(.top, 4)
                    ForEach(entries) { entry in
                        GlassCard(padding: 14) {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(ConfigLibrary.shownName(entry)).font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.text).lineLimit(1)
                                    Text(groupName(for: entry)).font(.caption)
                                        .foregroundStyle(Theme.textDim)
                                }
                                Spacer()
                                Menu {
                                    Button("未分组") {
                                        ConfigLibrary.setGroup(entryID: entry.id, groupID: ConfigLibrary.noGroupID)
                                        reload()
                                    }
                                    if ConfigLibrary.isPyFileEntry(entry) {
                                        Button("Python 文件（自动）") {
                                            ConfigLibrary.setGroup(entryID: entry.id, groupID: ConfigLibrary.pyAutoGroupID)
                                            reload()
                                        }
                                    }
                                    ForEach(groups) { group in
                                        Button(group.name) {
                                            ConfigLibrary.setGroup(entryID: entry.id, groupID: group.id)
                                            reload()
                                        }
                                    }
                                } label: {
                                    Text("移动").font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Theme.glass, in: Capsule())
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(AmbientBackground(imageURL: nil))
            .navigationTitle("编辑分组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.foregroundStyle(Theme.text)
                }
            }
            .alert("新建分组", isPresented: $showNewGroup) {
                TextField("分组名称", text: $newGroupName)
                Button("创建") {
                    let name = newGroupName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        ConfigLibrary.addGroup(name: name)
                        reload()
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .alert("分组改名", isPresented: Binding(get: { renamingGroup != nil },
                                                    set: { if !$0 { renamingGroup = nil } })) {
                TextField("分组名称", text: $renameText)
                Button("保存") {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if let group = renamingGroup, !name.isEmpty {
                        ConfigLibrary.renameGroup(id: group.id, name: name)
                    }
                    renamingGroup = nil
                    reload()
                }
                Button("取消", role: .cancel) { renamingGroup = nil }
            }
            .onAppear { reload() }
        }
        .presentationDetents([.large])
    }

    private func reload() {
        groups = ConfigLibrary.groups()
        entries = ConfigLibrary.entries()
    }

    private func groupName(for entry: ConfigLibrary.Entry) -> String {
        switch ConfigLibrary.effectiveGroupID(for: entry) {
        case ConfigLibrary.pyAutoGroupID: return "Python 文件"
        case let gid?: return groups.first { $0.id == gid }?.name ?? "未分组"
        default: return "未分组"
        }
    }
}

/// The collapsed Python group's picker page (v1.58): every
/// auto-grouped py file line as one row; tapping opens its site
/// directly (routed back through LibraryView's direct-open
/// destination), long-press deletes.
struct PyGroupView: View {
    @Binding var config: TVBoxConfig?
    var onPick: (ConfigLibrary.Entry) -> Void
    @State private var entries: [ConfigLibrary.Entry] = []

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(entries) { entry in
                    LightGlassCard(padding: 14) {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Theme.accent.opacity(0.25)).frame(width: 38, height: 38)
                                Text("py").font(.subheadline.weight(.bold)).foregroundStyle(Theme.text)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(ConfigLibrary.shownName(entry))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.text).lineLimit(1)
                                Text(entry.sourceURL.replacingOccurrences(of: "py-import://", with: ""))
                                    .font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(Theme.textDim)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.tap()
                        onPick(entry)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            config = ConfigLibrary.remove(id: entry.id)
                            reload()
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
                if entries.isEmpty {
                    EmptyStateView(icon: "folder",
                                   title: "这个分组是空的",
                                   message: "长按资源库的线路卡片可以把它移进来",
                                   compact: true)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 110)
        }
        .background(AmbientBackground(imageURL: nil))
        .navigationTitle("Python 站点")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
    }

    private func reload() {
        entries = ConfigLibrary.entries().filter {
            ConfigLibrary.effectiveGroupID(for: $0) == ConfigLibrary.pyAutoGroupID
        }
    }
}

/// Direct-open target for a single-file line: its config's only
/// site plus the config's parse interfaces.
private struct FileSiteRoute: Identifiable, Hashable {
    let site: TVBoxConfig.Site
    let parses: [TVBoxConfig.Parse]
    let isJS: Bool
    var id: String { site.id + (isJS ? "#js" : "#py") }
    // Manual conformance: Site carries JSONValue ext, which is not
    // Hashable, so identity (not memberwise synthesis) is the key.
    static func == (lhs: FileSiteRoute, rhs: FileSiteRoute) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The library grid's glass card: the full Rex recipe — tint wash
/// over a translucent fill, gradient rim light, soft shadow — minus
/// the live blur material per card (stacked .ultraThinMaterial was
/// the scroll-stutter source; over the page's ambient blurred
/// backdrop the wash reads as frosted glass without it). Upgraded
/// in v1.74: the old flat fill + hairline stroke read as plain
/// grey blocks next to the other tabs' glass.
private struct LightGlassCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Theme.cardTint,
                        in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .background(Theme.glass,
                        in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.glassEdge, lineWidth: 1))
        // No drop shadow: this card repeats in the library grids,
        // and a shadow per cell is an offscreen pass per cell while
        // scrolling. The tint + rim light carry the separation.
    }
}

/// Everything one line card renders, frozen at refresh time:
/// shown name, icon letter, freshness text, role line and kind
/// summary. Identifiable by line id; equality covers only the
/// rendered fields, so .equatable() can skip unchanged cards.
private struct LineCardModel: Identifiable, Equatable {
    let entry: ConfigLibrary.Entry
    let shownName: String
    let iconText: String
    let freshnessText: String
    let isActive: Bool
    let isHome: Bool
    let isFile: Bool
    let roleText: String
    let kindText: String

    var id: String { entry.id }

    static func == (lhs: LineCardModel, rhs: LineCardModel) -> Bool {
        lhs.entry.id == rhs.entry.id
            && lhs.shownName == rhs.shownName
            && lhs.iconText == rhs.iconText
            && lhs.freshnessText == rhs.freshnessText
            && lhs.isActive == rhs.isActive
            && lhs.isHome == rhs.isHome
            && lhs.isFile == rhs.isFile
            && lhs.roleText == rhs.roleText
            && lhs.kindText == rhs.kindText
    }
}

/// One line = one big card (Rex's 资源库 layout), rendered purely
/// from its LineCardModel; all actions route back to LibraryView
/// through closures (excluded from equality). Long-press menu:
/// rename （备注名）, set home line, move to a group, or delete.
private struct LineCardView: View, Equatable {
    let model: LineCardModel
    let groups: [ConfigLibrary.Group]
    let onTap: () -> Void
    let onRename: () -> Void
    let onSetHome: () -> Void
    let onMoveToGroup: (String) -> Void
    let onDelete: () -> Void
    /// v1.87: remote lines only — long-press 更新线路.
    let onRefresh: (() -> Void)?

    static func == (lhs: LineCardView, rhs: LineCardView) -> Bool {
        lhs.model == rhs.model
            && lhs.groups.map(\.id) == rhs.groups.map(\.id)
            && lhs.groups.map(\.name) == rhs.groups.map(\.name)
    }

    var body: some View {
        LightGlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top) {
                    ZStack {
                        Circle().fill(Theme.accent.opacity(0.25)).frame(width: 38, height: 38)
                        Text(model.iconText)
                            .font(.headline).foregroundStyle(Theme.text)
                    }
                    Spacer()
                    HStack(spacing: 5) {
                        Text(model.freshnessText)
                            .font(.caption2).foregroundStyle(Theme.textDim)
                        Circle().fill(model.isActive ? Theme.ok : Color.gray.opacity(0.55))
                            .frame(width: 7, height: 7)
                    }
                }
                Text(model.shownName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text).lineLimit(2)
                if !model.roleText.isEmpty {
                    Text(model.roleText)
                        .font(.caption)
                        .foregroundStyle(model.isActive ? Theme.ok : (model.isHome ? Theme.accent : Theme.textDim))
                }
                Text(model.kindText)
                    .font(.caption2).foregroundStyle(Theme.textDim).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(model.isActive ? Theme.accent.opacity(0.55) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { Haptics.tap(); onTap() }
        .contextMenu {
            if let onRefresh {
                Button {
                    onRefresh()
                } label: {
                    Label("更新线路", systemImage: "arrow.clockwise")
                }
            }
            Button {
                onRename()
            } label: {
                Label("改备注名", systemImage: "pencil")
            }
            if !model.isHome {
                Button {
                    onSetHome()
                } label: {
                    Label("设为首页线路", systemImage: "house")
                }
            }
            Menu("移动到分组") {
                Button("未分组") { onMoveToGroup(ConfigLibrary.noGroupID) }
                if ConfigLibrary.isPyFileEntry(model.entry) {
                    Button("Python 文件（自动）") { onMoveToGroup(ConfigLibrary.pyAutoGroupID) }
                }
                ForEach(groups) { group in
                    Button(group.name) { onMoveToGroup(group.id) }
                }
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除线路", systemImage: "trash")
            }
        }
    }
}

/// (Removed in v1.74: the library's flat StaticPageBackground —
/// both library pages now sit on the shared AmbientBackground
/// like every other tab.)
