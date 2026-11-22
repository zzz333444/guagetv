import SwiftUI

/// Re-opens a favourite/history entry's detail page on its original
/// line, routing to the loader matching the site's runtime. (Same
/// contract as the history tab's destination; jar sites report the
/// same "not directly openable" message there too.)
struct EntryDetailDestination: View {
    let entry: HistoryStore.Entry

    var body: some View {
        Group {
            if let resolved {
                let item = VodItem(id: entry.vodId, name: entry.name, pic: entry.pic,
                                   remarks: "", year: "", score: "")
                switch resolved.site.kind {
                case .cmsJSON, .cmsXML:
                    DetailLoaderView(site: resolved.site, item: item, lineID: entry.lineID, parses: resolved.parses)
                case .spiderPY:
                    PyDetailLoaderView(site: resolved.site, item: item, parses: resolved.parses)
                case .spiderJS, .drpyJS:
                    JSDetailLoaderView(site: resolved.site, item: item,
                                       ruleRef: (try? JSSiteBrowseView.resolveRuleRef(resolved.site)) ?? "",
                                       parses: resolved.parses)
                default:
                    message("该站点类型暂不支持直接打开")
                }
            } else {
                message("原线路已删除或站点不存在")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmbientBackground(imageURL: entry.pic))
    }

    private var resolved: (site: TVBoxConfig.Site, parses: [TVBoxConfig.Parse])? {
        let lineID = entry.lineID.isEmpty ? (ConfigLibrary.activeID() ?? "") : entry.lineID
        guard let config = ConfigLibrary.load(id: lineID),
              let site = config.sites.first(where: { $0.key == entry.siteKey })
        else { return nil }
        return (site, config.parses ?? [])
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(Theme.textDim)
    }
}

/// 追剧 — every favourited series in one place: which ones have new
/// episodes (per the site's own「更新至…」remarks), where you left
/// off, and one tap back into the detail page. Update checks reuse
/// HistoryStore.checkFavouritesForUpdates (CMS favourites; py/JS
/// favourites are listed but not mass-checked).
struct WatchlistView: View {
    @ObservedObject private var history = HistoryStore.shared
    @StateObject private var downloads = DownloadManager.shared
    @State private var checking = false
    @AppStorage("watchNotify.enabled") private var notifyEnabled = true
    /// v2.35 今日更新：今天 bangumi 每日放送的片名（归一化后）。
    /// 无 bangumi 模块时保持空集、静默不显示；标题比对只做
    /// 归一化相等或包含，不做模糊猜测。
    @State private var todayTitles: Set<String> = []

    /// v2.11 排序复核：有更新的置顶（hasUpdate 优先），其余按
    /// 最近观看时间倒序。进详情页会清掉该条的 hasUpdate
    /// (DetailView 调 markUpdateSeen)，红点随之消失。
    private var sortedFavourites: [HistoryStore.Entry] {
        history.favourites.sorted { a, b in
            if a.hasUpdate != b.hasUpdate { return a.hasUpdate }
            return a.updatedAt > b.updatedAt
        }
    }

    private var updateCount: Int { history.favourites.filter(\.hasUpdate).count }

    /// 今天在 bangumi 每日放送里的追剧（与 hasUpdate 是两个
    /// 独立信号：前者是模块说今天播，后者是站点备注变了）。
    private var todayUpdated: [HistoryStore.Entry] {
        sortedFavourites.filter { isTodayUpdated($0) }
    }

    /// 标题归一化：去空白与全部标点/符号、转小写，供跨源比对。
    private static func normalizeTitle(_ s: String) -> String {
        let drop = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters).union(.symbols)
        return s.unicodeScalars.filter { !drop.contains($0) }
            .map { Character($0).lowercased() }.joined()
    }

    private func isTodayUpdated(_ entry: HistoryStore.Entry) -> Bool {
        let name = Self.normalizeTitle(entry.name)
        guard !name.isEmpty, !todayTitles.isEmpty else { return false }
        if todayTitles.contains(name) { return true }
        // 包含匹配只在较短一方 ≥4 字时才认，避免「海」「风」
        // 之类的单字误撞。
        return todayTitles.contains { t in
            min(t.count, name.count) >= 4 && (t.contains(name) || name.contains(t))
        }
    }

    /// 该剧已下载好的集数（按 vodName 精确匹配，与下载页
    /// 分组同一口径；0 集时不显示）。
    private func downloadedCount(for entry: HistoryStore.Entry) -> Int {
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return 0 }
        return downloads.items.filter {
            $0.vodName.trimmingCharacters(in: .whitespacesAndNewlines) == name
                && $0.state == "done"
        }.count
    }

    var body: some View {
        Group {
            if sortedFavourites.isEmpty {
                emptyState
            } else {
                List {
                    summaryRow
                    ForEach(sortedFavourites) { entry in
                        NavigationLink {
                            EntryDetailDestination(entry: entry)
                        } label: {
                            row(entry)
                        }
                        .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(AmbientBackground(imageURL: sortedFavourites.first?.pic))
        .navigationTitle("追剧")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if !sortedFavourites.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        notifyEnabled.toggle()
                        if notifyEnabled { WatchNotify.requestAuthorizationIfNeeded() }
                    } label: {
                        Image(systemName: notifyEnabled ? "bell.fill" : "bell.slash")
                    }
                    .foregroundStyle(Theme.text)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(checking ? "检测中…" : "检测更新") { Haptics.tap(); runCheck(force: true) }
                        .disabled(checking)
                        .foregroundStyle(Theme.text)
                }
            }
        }
        .task {
            // Quiet auto-check; the 6-hour throttle lives in
            // HistoryStore (v2.23) so every entry point shares it.
            if !sortedFavourites.isEmpty {
                runCheck()
            }
            await loadTodayTitles()
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 8) {
            Text("共 \(sortedFavourites.count) 部在追")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
            if updateCount > 0 {
                Text("\(updateCount) 部有更新")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.white)
            }
            if !todayUpdated.isEmpty {
                Text("今日更新 \(todayUpdated.count) 部")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.ok, in: Capsule())
                    .foregroundStyle(.white)
            }
            Spacer()
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 18, bottom: 2, trailing: 18))
    }

    private func row(_ entry: HistoryStore.Entry) -> some View {
        HStack(spacing: 12) {
            // v2.11: 有更新的海报右上角挂红点（与「有更新」胶囊并列）。
            ZStack(alignment: .topTrailing) {
                PosterImage(urlString: entry.pic, pixelSize: 240)
                    .frame(width: 46, height: 69)
                    .posterFrame()
                if entry.hasUpdate {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                        .offset(x: 3, y: -3)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                var metaParts = [entry.siteName, entry.lastRemarks].filter { !$0.isEmpty }
                let done = downloadedCount(for: entry)
                if done > 0 { metaParts.append("已下载 \(done) 集") }
                let meta = metaParts.joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                }
                if !entry.episodeName.isEmpty {
                    Text("看到 \(entry.episodeName)")
                        .font(.caption2).foregroundStyle(Theme.textDim).lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if isTodayUpdated(entry) {
                    Text("今日更新")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.ok, in: Capsule())
                        .foregroundStyle(.white)
                }
                if entry.hasUpdate {
                    Text("有更新")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.accent, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(10)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: Theme.innerCardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.innerCardRadius).strokeBorder(Theme.glassStroke, lineWidth: 1))
    }

    private var emptyState: some View {
        EmptyStateView(icon: "calendar.badge.clock",
                       title: "还没有在追的剧",
                       message: "在详情页点爱心收藏，连载剧更新了会在这里标出来")
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// v2.35 今日更新：拉今天 bangumi 每日放送的片名（与
    /// 播出日历同一缓存键与 TTL：重进即出屏、不重复拉模块）。
    /// 无 bangumi 模块、拉取失败或当天无放送时静默留空，
    /// 追剧页不挂任何标记、不报错。
    private func loadTodayTitles() async {
        guard let record = FWDStore.records().first(where: { $0.id == "rex.bangumi" })
                ?? FWDStore.records().first(where: {
                    $0.meta.listModules.contains { $0.id == "dailySchedule" }
                }),
              let module = record.meta.listModules.first(where: { $0.id == "dailySchedule" }),
              let source = FWDStore.source(for: record) else { return }
        var params: [String: Any] = ["day": "today"]
        for p in record.meta.globalParams where !p.value.isEmpty {
            params[p.name] = p.value
        }
        let ttl = record.meta.cacheDuration > 0
            ? TimeInterval(record.meta.cacheDuration) : FWDColumnCache.defaultTTL
        let cacheKey = FWDColumnCache.key(moduleID: record.id,
                                          columnID: module.id, params: params)
        let rows: [[String: Any]]
        if let cached = FWDColumnCache.get(key: cacheKey, ttl: ttl) {
            rows = cached
        } else {
            guard let result = try? await FWDRuntime(widgetID: record.id)
                    .call(function: module.functionName, params: params, source: source),
                  let list = result as? [[String: Any]] else { return }
            rows = list
            if !rows.isEmpty { FWDColumnCache.set(key: cacheKey, rows: rows) }
        }
        let names = rows.map { FWDItem($0).title }
            .map(Self.normalizeTitle).filter { !$0.isEmpty }
        if !names.isEmpty { todayTitles = Set(names) }
    }

    /// 手动点「检测更新」绕过 6 小时节流（force: true）；
    /// 进页自动检查走节流。
    private func runCheck(force: Bool = false) {
        guard !checking else { return }
        checking = true
        Task {
            await HistoryStore.shared.checkFavouritesForUpdates(force: force)
            checking = false
        }
    }
}
