import SwiftUI

/// Search across all imported sites: CMS natively, py spiders via
/// the embedded Python runtime, drpy sites via the JS engine.
struct SearchView: View {
    var config: TVBoxConfig?
    /// Seeded keyword (the Discover page's TMDB rows hand their
    /// title over through this): filled into the field and searched
    /// automatically on first appearance.
    var initialKeyword: String = ""
    @Environment(\.dismiss) private var dismiss

    @State private var keyword = ""
    @StateObject private var voice = VoiceSearchController()
    @State private var results: [(site: TVBoxConfig.Site, items: [VodItem])] = []
    @State private var searching = false
    @State private var searched = false
    @State private var progressText = ""
    @State private var failureNote = ""
    @State private var finalNote = ""
    /// The running search, kept so the 停止 button can cancel it
    /// (entry points used to fire untracked Tasks nobody could stop).
    @State private var searchTask: Task<Void, Never>?
    /// Pending debounced auto-search (F2): each keystroke cancels
    /// the previous one, so a fast typist fires one search, not
    /// one per letter. Cancelled in beginSearch() / onDisappear.
    @State private var debounceTask: Task<Void, Never>?
    /// Keyword of the last search that actually started (set in
    /// run() after its guard): the debounce task skips when the
    /// field still holds it, so a manual submit or a recent-chip
    /// tap — which already searched — is not searched twice.
    @State private var lastSearchedKeyword = ""
    /// Kinds sniffed for .unknown subscription sites during this
    /// search (key: site.key) — results from such a site must open
    /// in the probed runtime's detail loader, not the CMS default.
    @State private var probedKinds: [String: TVBoxConfig.Site.Kind] = [:]
    /// Parse interfaces per site key, filled at search start: results
    /// from imported single-file lines need their own line's parses.
    @State private var parsesByKey: [String: [TVBoxConfig.Parse]] = [:]
    /// Site filter for the results browser (nil = 全部）: the left
    /// rail lists every site that produced results, tapping one
    /// narrows the poster grid to just that site.
    @State private var selectedSiteKey: String?
    /// Sites that answered this search with zero results (v1.96):
    /// they never reach `results` (only non-empty groups do), so
    /// they used to vanish silently. They now collect in a folded
    /// "无结果" section at the foot of the site rail instead —
    /// folded by default, tap the header to expand.
    @State private var emptySites: [TVBoxConfig.Site] = []
    @State private var showEmptySites = false
    /// Title aggregation (v1.42): same-title hits from many
    /// sites collapse into one card ("N 条线"), tapping opens
    /// the per-site list. On by default; the toggle lives above
    /// the results.
    @AppStorage("search.aggregate") private var aggregateTitles = true
    @State private var selectedTitleGroup: TitleGroup?
    /// The left rail can be hidden from the header's filter button.
    @State private var showSiteFilter = true
    /// Result filters (v2.09): year + type, applied client-side to
    /// the current result set. A chip row only appears when the
    /// results actually carry that field — sources that send no
    /// vod_year / type_name get no chips instead of a dead filter.
    /// Reset on every new search in run().
    @State private var selectedYear: String? = nil
    @State private var selectedType: String? = nil
    /// Progress counters for the rail's 全部 (done/total) label,
    /// mirrored out of run()'s local tallies as sites answer.
    @State private var searchDoneCount = 0
    @State private var searchTotalCount = 0
    /// The active line's jar URL when the Jar proxy is configured;
    /// jar sites join the search only then.
    @State private var searchJarURL = ""
    /// Per-site jar URLs: cross-line search pulls jar sites from
    /// every library line, and each line ships its own spider jar.
    @State private var jarURLByKey: [String: String] = [:]

    private var cmsSites: [TVBoxConfig.Site] {
        (config?.sites ?? []).filter { $0.kind == .cmsJSON || $0.kind == .cmsXML }
    }
    private var pySites: [TVBoxConfig.Site] {
        (config?.sites ?? []).filter { $0.kind == .spiderPY && $0.searchable != 0 }
    }
    private var jsSites: [TVBoxConfig.Site] {
        (config?.sites ?? []).filter { ($0.kind == .spiderJS || $0.kind == .drpyJS) && $0.searchable != 0 }
    }
    /// Type-3 sites whose api carries no classifiable extension
    /// (tokenised subscription URLs): they land in NO kind pool, so
    /// search used to skip them entirely. run() sniffs them (the
    /// SiteBrowseView probe) and deals them into the py/JS pools.
    private var probeableSites: [TVBoxConfig.Site] {
        (config?.sites ?? []).filter { $0.kind == .unknown && $0.type == 3 && $0.searchable != 0 }
    }
    private var hasSites: Bool {
        !cmsSites.isEmpty || !pySites.isEmpty || !jsSites.isEmpty || !probeableSites.isEmpty
    }
    /// Two poster columns beside the site rail (the rail takes the
    /// rest of the width budget, like the reference layout).
    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 2)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                statusRow
                content
            }
            .animation(.easeOut(duration: 0.25), value: searching)
            .background(AmbientBackground(imageURL: nil))
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear {
            voice.onFinal = { text in
                keyword = text
                beginSearch()
            }
            if keyword.isEmpty, !initialKeyword.isEmpty {
                keyword = initialKeyword
                beginSearch()
            }
            if !hotLoaded {
                hotLoaded = true
                Task { await loadHotTitles() }
            }
        }
        .onChange(of: voice.partial) { _, text in
            if voice.listening { keyword = text }
        }
        .onDisappear {
            debounceTask?.cancel()
            voice.stop()
        }
    }

    /// Reference-layout header: round back button, the search
    /// field as a full-width pill, and a round filter button that
    /// shows/hides the site rail.
    private var headerBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 42, height: 42)
                    .glassCircle()
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textDim)
                TextField("搜片名", text: $keyword)
                    .foregroundStyle(Theme.text)
                    .submitLabel(.search)
                    .onSubmit { beginSearch() }
                    .onChange(of: keyword) { _, newValue in
                        scheduleDebouncedSearch(newValue)
                    }
                if !keyword.isEmpty {
                    Button { keyword = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textDim)
                    }
                    .buttonStyle(.plain)
                }
                Button { voice.toggle() } label: {
                    Image(systemName: voice.listening ? "mic.fill" : "mic")
                        .foregroundStyle(voice.listening ? Color.red : Theme.textDim)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .glassCapsule()
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showSiteFilter.toggle() }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(showSiteFilter ? Theme.accent : Theme.text)
                    .frame(width: 42, height: 42)
                    .glassCircle()
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// 最近搜索 — stored locally, newest first, capped at 10.
    @State private var recentsList: [String] =
        UserDefaults.standard.stringArray(forKey: "searchRecents.v1") ?? []
    /// v2.22: clearing recents now asks first — it used to wipe
    /// immediately on one tap, and the button sits next to the
    /// chips it deletes.
    @State private var confirmClearRecents = false
    /// TMDB 热门标题（v1.80 热搜）：点即搜；未开 TMDB 时不显示。
    @State private var hotTitles: [String] = []
    @State private var hotLoaded = false

    private var recents: [String] { recentsList }

    private func saveRecent(_ kw: String) {
        var list = recents.filter { $0 != kw }
        list.insert(kw, at: 0)
        recentsList = Array(list.prefix(10))
        UserDefaults.standard.set(recentsList, forKey: "searchRecents.v1")
    }

    /// 单条删除一条搜索历史（v1.80）。
    private func removeRecent(_ kw: String) {
        recentsList.removeAll { $0 == kw }
        UserDefaults.standard.set(recentsList, forKey: "searchRecents.v1")
    }

    /// TMDB 当日热门标题（v1.80 热搜）：只取标题，前 10 条。
    private func loadHotTitles() async {
        guard TMDBClient.isOn else { return }
        let titles = await TMDBClient.trending()
        hotTitles = Array(titles.map(\.title).filter { !$0.isEmpty }.prefix(10))
    }

    @ViewBuilder
    private var recentsView: some View {
        if recents.isEmpty && hotTitles.isEmpty {
            hint("跨已导入的 CMS / py / JS 站点一起搜")
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if !hotTitles.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "flame.fill").foregroundStyle(Color.orange)
                            Text("热搜").font(.headline).foregroundStyle(Theme.text)
                        }
                        FlowChips(words: hotTitles) { word in
                            keyword = word
                            beginSearch()
                        }
                    }
                    if !recents.isEmpty {
                        HStack {
                            Text("最近搜索").font(.headline).foregroundStyle(Theme.text)
                            Spacer()
                            Button("清空") {
                                Haptics.tap()
                                confirmClearRecents = true
                            }
                            .font(.caption).foregroundStyle(Theme.textDim)
                        }
                        DeletableFlowChips(words: recents) { word in
                            keyword = word
                            beginSearch()
                        } onDelete: { word in
                            removeRecent(word)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
            }
            .confirmationDialog("清空最近搜索？", isPresented: $confirmClearRecents,
                                titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    recentsList = []
                    UserDefaults.standard.removeObject(forKey: "searchRecents.v1")
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if searching {
            HStack(spacing: 8) {
                ProgressView().tint(Theme.text)
                Text(progressText.isEmpty ? "搜索中…" : progressText)
                    .font(.footnote).foregroundStyle(Theme.textDim)
                Spacer()
                Button("停止") { stopSearch() }
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Theme.glass, in: Capsule())
            }
            .padding(.horizontal, 18).padding(.vertical, 6)
        } else if searched && !finalNote.isEmpty {
            Text(finalNote).font(.footnote).foregroundStyle(Theme.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !hasSites {
            // R8 (v1.85): bare hint text → shared empty state.
            VStack {
                Spacer()
                EmptyStateView(
                    icon: "square.stack.3d.up.slash",
                    title: "还没有导入配置",
                    message: "先在设置里导入一个配置，搜索才能开工")
                    .padding(.horizontal, 18)
                Spacer()
            }
        } else if searching && results.isEmpty {
            // v2.12: bare spinner → poster-grid skeleton (search
            // results render as posters).
            // v2.21: cross-fades when results land.
            SkeletonPosterGrid()
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .transition(.opacity)
        } else if !results.isEmpty {
            // Results branch MUST outrank the !searched branch below:
            // `searched` stays false for the whole run, so ordering
            // the recents branch first hid every in-flight result
            // behind the recents list until the run ended — the
            // "results only appear when the search finishes" bug.
            aggregateToggleBar
            resultFilterBar
            if filteredResults.isEmpty {
                EmptyStateView(icon: "line.3.horizontal.decrease.circle",
                               title: "筛选后没有结果",
                               message: "换个年份或类型试试",
                               actionTitle: "清除筛选",
                               action: { selectedYear = nil; selectedType = nil },
                               compact: true)
                    .padding(.horizontal, 18)
            } else if aggregateTitles, selectedSiteKey == nil {
                aggregatedBrowser
            } else {
                resultsBrowser
            }
            if searching {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.text)
                    Text(progressText.isEmpty ? "还在搜其他站点…" : progressText)
                        .font(.footnote).foregroundStyle(Theme.textDim)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
        } else if searched {
            // R8 (v1.85): bare hint text → shared empty state with
            // a clear-search action back to recents.
            VStack {
                Spacer()
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "没有搜到结果",
                    message: failureNote.isEmpty ? "换个片名或换条线路试试" : failureNote,
                    actionTitle: "清除搜索",
                    action: {
                        keyword = ""
                        results = []
                        failureNote = ""
                        searched = false
                    })
                    .padding(.horizontal, 18)
                Spacer()
            }
        } else {
            recentsView
        }
    }

    private var aggregateToggleBar: some View {
        HStack {
            Spacer()
            Toggle("同名聚合", isOn: $aggregateTitles)
                .font(.caption)
                .foregroundStyle(Theme.textDim)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    struct TitleGroup: Identifiable {
        var key: String
        var title: String
        var entries: [(site: TVBoxConfig.Site, item: VodItem)]
        var id: String { key }
        var representative: VodItem { entries[0].item }
    }

    /// Results after the year/type filter: groups that filter
    /// down to nothing drop out entirely. Both browsers
    /// (titleGroups, visibleGroups) read this, never `results`.
    private var filteredResults: [(site: TVBoxConfig.Site, items: [VodItem])] {
        guard selectedYear != nil || selectedType != nil else { return results }
        return results.compactMap { group in
            let items = group.items.filter { item in
                (selectedYear == nil || item.year == selectedYear)
                && (selectedType == nil || item.typeName == selectedType)
            }
            return items.isEmpty ? nil : (site: group.site, items: items)
        }
    }

    /// Distinct years present in this result set, newest first.
    private var availableYears: [String] {
        Array(Set(results.flatMap(\.items).map(\.year).filter { !$0.isEmpty }))
            .sorted { (Int($0) ?? 0, $0) > (Int($1) ?? 0, $1) }
    }

    /// Distinct content types present in this result set.
    private var availableTypes: [String] {
        Array(Set(results.flatMap(\.items).map(\.typeName).filter { !$0.isEmpty }))
            .sorted()
    }

    /// Horizontal chip row for the year/type filter. Only rendered
    /// when at least one section has values; each section keeps its
    /// own 全部 chip so either dimension clears independently.
    private var resultFilterBar: some View {
        Group {
            if !availableYears.isEmpty || !availableTypes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if !availableYears.isEmpty {
                            filterChip(label: "全部年份", selected: selectedYear == nil) {
                                selectedYear = nil
                            }
                            ForEach(availableYears, id: \.self) { year in
                                filterChip(label: year, selected: selectedYear == year) {
                                    selectedYear = year
                                }
                            }
                        }
                        if !availableTypes.isEmpty {
                            filterChip(label: "全部类型", selected: selectedType == nil) {
                                selectedType = nil
                            }
                            ForEach(availableTypes, id: \.self) { type in
                                filterChip(label: type, selected: selectedType == type) {
                                    selectedType = type
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func filterChip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Text(label)
                .font(.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? .black : Theme.text.opacity(0.85))
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(selected ? Color.white : Theme.glass, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.glassStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var titleGroups: [TitleGroup] {
        var order: [String] = []
        var map: [String: TitleGroup] = [:]
        for group in filteredResults {
            for item in group.items {
                let key = Self.normalizedTitle(item.name)
                if map[key] == nil {
                    map[key] = TitleGroup(key: key, title: item.name, entries: [])
                    order.append(key)
                }
                map[key]?.entries.append((group.site, item))
            }
        }
        return order.compactMap { map[$0] }
    }

    static func normalizedTitle(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var aggregatedBrowser: some View {
        HStack(alignment: .top, spacing: 0) {
            if showSiteFilter { siteRail }
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: gridColumns, spacing: 14) {
                    ForEach(titleGroups) { group in
                        Button {
                            selectedTitleGroup = group
                        } label: {
                            SearchPosterCell(
                                item: group.representative,
                                badge: group.entries.count > 1 ? "\(group.entries.count) 条线" : group.entries[0].site.name)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
        .sheet(item: $selectedTitleGroup) { group in
            NavigationStack {
                List(group.entries, id: \.site.key) { entry in
                    NavigationLink {
                        destination(for: entry.site, item: entry.item)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.site.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.text)
                                if !entry.item.remarks.isEmpty {
                                    Text(entry.item.remarks)
                                        .font(.caption)
                                        .foregroundStyle(Theme.textDim)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Theme.textDim)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Theme.bg)
                .navigationTitle(group.title)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    /// The groups the poster grid shows: everything, or just the
    /// site picked on the rail — after the year/type filter.
    private var visibleGroups: [(site: TVBoxConfig.Site, items: [VodItem])] {
        guard let key = selectedSiteKey else { return filteredResults }
        return filteredResults.filter { $0.site.key == key }
    }

    /// Results browser (reference layout): a site rail on the
    /// left — 全部 with the (done/total) progress, then one row
    /// per site that found something, with an orange count badge —
    /// and a two-column poster grid on the right. In 全部 mode
    /// each poster carries its site name as an orange badge; in
    /// single-site mode the badge falls back to the item's remarks.
    private var resultsBrowser: some View {
        HStack(alignment: .top, spacing: 0) {
            if showSiteFilter { siteRail }
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: gridColumns, spacing: 14) {
                    ForEach(visibleGroups, id: \.site.id) { group in
                        ForEach(group.items) { item in
                            NavigationLink {
                                destination(for: group.site, item: item)
                            } label: {
                                SearchPosterCell(
                                    item: item,
                                    badge: selectedSiteKey == nil ? group.site.name : item.remarks)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
    }

    private var siteRail: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 2) {
                railRow(title: "全部",
                        badge: nil,
                        countText: "(\(searchDoneCount)/\(searchTotalCount))",
                        selected: selectedSiteKey == nil) {
                    selectedSiteKey = nil
                }
                ForEach(results, id: \.site.id) { group in
                    railRow(title: group.site.name,
                            badge: "\(group.items.count)",
                            countText: nil,
                            selected: selectedSiteKey == group.site.key) {
                        selectedSiteKey = group.site.key
                    }
                }
                // 无结果站点自动折叠（v1.96）：有响应但 0 结果的站
                // 收进这一区，默认折叠只露一行计数，点按展开看站名。
                // 超时/失败的站不进这里，仍只计入底部汇总。
                if !emptySites.isEmpty {
                    Divider().background(Theme.textDim.opacity(0.3))
                        .padding(.vertical, 4)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { showEmptySites.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Text("无结果")
                                .font(.caption.weight(showEmptySites ? .semibold : .regular))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(emptySites.count)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.gray, in: Capsule())
                            Image(systemName: showEmptySites ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.textDim)
                        }
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .padding(.horizontal, 8).padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showEmptySites {
                        ForEach(emptySites) { site in
                            Text(site.name)
                                .font(.caption)
                                .foregroundStyle(Theme.textDim)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .frame(width: 118)
    }

    private func railRow(title: String, badge: String?, countText: String?,
                         selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                if let countText {
                    Text(countText).font(.caption2).monospacedDigit()
                }
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange, in: Capsule())
                }
            }
            .foregroundStyle(selected ? .white : Theme.text.opacity(0.85))
            .padding(.horizontal, 8).padding(.vertical, 9)
            .background(selected ? Color.blue : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hint(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(.subheadline).foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func destination(for site: TVBoxConfig.Site, item: VodItem) -> some View {
        let parses = parsesByKey[site.key] ?? config?.parses ?? []
        switch probedKinds[site.key] ?? site.kind {
        case .spiderPY:
            PyDetailLoaderView(site: site, item: item, parses: parses)
        case .spiderJAR:
            JarDetailLoaderView(site: site, item: item, parses: parses,
                                jar: jarURLByKey[site.key] ?? searchJarURL)
        case .spiderJS, .drpyJS:
            JSDetailLoaderView(site: site, item: item,
                               ruleRef: (try? JSSiteBrowseView.resolveRuleRef(site)) ?? "",
                               parses: parses)
        default:
            DetailLoaderView(site: site, item: item, parses: parses)
        }
    }

    /// Race work against a deadline: one dead or crawling site must
    /// not stall the whole search (the old serial run could sit on a
    /// single host for a minute and look exactly like "broken").
    private func withTimeout<T>(_ seconds: Double,
                                _ work: @escaping () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Timeout race that keeps the error: withTimeout() alone turns
    /// every failure into a bare nil, which is why "search finds
    /// nothing" was undiagnosable from the user's side.
    private func withTimeoutError<T>(_ seconds: Double,
                                     _ work: @escaping () async -> Result<T, Error>) async -> Result<T, Error>? {
        await withTaskGroup(of: Result<T, Error>?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func shortError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain || ns.domain.contains("JSON") {
            return "返回内容不是 JSON（可能被站方拦截）"
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "请求超时"
            case .notConnectedToInternet, .networkConnectionLost: return "网络不通"
            case .cannotFindHost, .dnsLookupFailed: return "域名解析失败"
            case .badServerResponse: return "服务器返回错误状态"
            default: return "网络错误"
            }
        }
        let text = ns.localizedDescription
        return text.count > 42 ? String(text.prefix(42)) + "…" : text
    }

    /// A deadline a blocked bridge call cannot ignore: task-group
    /// races still wait for a child stuck in a synchronous Python/JS
    /// call, which is how a search could hang forever. The loser is
    /// abandoned (it finishes or dies in the background).
    private func hardTimeout(_ seconds: Double,
                             _ work: @escaping @Sendable () async -> [VodItem]?) async -> [VodItem]? {
        await withCheckedContinuation { cont in
            let box = ResumeBox(cont)
            Task.detached { box.resume(await work()) }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                box.resume(nil)
            }
        }
    }

    /// 300 ms debounce on keyword input (F2): wait for a pause in
    /// typing, then search. Each keystroke cancels the pending
    /// task, so only the final keyword is searched; a search
    /// already running is waited out briefly (up to ~3 s) before
    /// starting the new one, so the debounced search is not lost
    /// to run()'s `searching` guard — past the wait the fallback
    /// is the same as a manual submit (cancel + restart).
    private func scheduleDebouncedSearch(_ newValue: String) {
        debounceTask?.cancel()
        let kw = newValue.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            var waited = 0
            while searching && waited < 20 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { return }
                waited += 1
            }
            guard !Task.isCancelled else { return }
            let current = keyword.trimmingCharacters(in: .whitespaces)
            guard current == kw, !current.isEmpty, current != lastSearchedKeyword else { return }
            beginSearch()
        }
    }

    /// All search entry points funnel here so the run is tracked
    /// and the 停止 button can actually cancel it.
    private func beginSearch() {
        Haptics.tap()
        debounceTask?.cancel()
        debounceTask = nil
        searchTask?.cancel()
        searchTask = Task { await run() }
    }

    private func stopSearch() {
        searchTask?.cancel()
        if searching { progressText = "正在停止…" }
    }

    /// Main-actor isolated on purpose: every @State write below
    /// (results, progressText, probedKinds…) then lands on the main
    /// actor the moment a site answers, so each site's section
    /// paints immediately instead of waiting for a later redraw.
    /// The bridge/HTTP calls it awaits are nonisolated and still
    /// run off the main actor.
    @MainActor
    private func run() async {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty, !searching else { return }
        lastSearchedKeyword = kw
        saveRecent(kw)
        searching = true
        searched = false
        results = []
        failureNote = ""
        finalNote = ""
        probedKinds = [:]
        selectedSiteKey = nil
        selectedYear = nil
        selectedType = nil
        emptySites = []
        showEmptySites = false
        searchDoneCount = 0
        searchTotalCount = 0
        // v2.31: warm the active line before the jar phase starts
        // (fire-and-forget, 10-minute TTL in warmLine) — search
        // previously never warmed, so its first jar call paid the
        // cold-proxy wake on the two-attempt budget while browse
        // and detail both warm on appear.
        if JarProxyClient.configured { JarProxyClient.warmActiveLine() }
        // Searchable py/JS pools: the active line's spider sites PLUS
        // every imported single-file py/JS line in the library —
        // those live as their own lines, and the user expects the
        // files they imported to be searched too.
        var pyPool = pySites
        var jsPool = jsSites
        var parseMap: [String: [TVBoxConfig.Parse]] = [:]
        for site in (config?.sites ?? []) { parseMap[site.key] = config?.parses ?? [] }
        let activeID = ConfigLibrary.activeID()
        for entry in ConfigLibrary.entries() where entry.id != activeID
            && (entry.sourceURL.hasPrefix("py-import://") || entry.sourceURL.hasPrefix("js-import://")) {
            guard let cfg = ConfigLibrary.load(id: entry.id) else { continue }
            for site in cfg.sites where site.searchable != 0 {
                parseMap[site.key] = cfg.parses
                if site.kind == .spiderPY, !pyPool.contains(where: { $0.key == site.key }) {
                    pyPool.append(site)
                }
                if site.kind == .spiderJS || site.kind == .drpyJS,
                   !jsPool.contains(where: { $0.key == site.key }) {
                    jsPool.append(site)
                }
            }
        }
        // Jar sites join in when a proxy is set: the active line
        // first, then every other full config line in the library —
        // each line resolves its OWN spider jar, and results keep a
        // per-site jar map so details open against the right jar.
        var jarPool: [TVBoxConfig.Site] = []
        var jarMap: [String: String] = [:]
        var activeJar = ""
        if JarProxyClient.configured {
            if let resolved = JarProxyClient.jarURL(from: config) {
                activeJar = resolved
                for site in (config?.sites ?? []) where site.kind == .spiderJAR && site.searchable != 0 {
                    jarMap[site.key] = resolved
                    jarPool.append(site)
                }
            }
            for entry in ConfigLibrary.entries() where entry.id != activeID
                && !entry.sourceURL.hasPrefix("py-import://") && !entry.sourceURL.hasPrefix("js-import://") {
                if jarPool.count >= 130 { break }
                guard let cfg = ConfigLibrary.load(id: entry.id),
                      let resolved = JarProxyClient.jarURL(from: cfg, base: entry.sourceURL) else { continue }
                for site in cfg.sites where site.kind == .spiderJAR && site.searchable != 0 {
                    if jarMap[site.key] == nil {
                        jarMap[site.key] = resolved
                        jarPool.append(site)
                        if parseMap[site.key] == nil { parseMap[site.key] = cfg.parses }
                    }
                }
            }
        }
        searchJarURL = activeJar
        jarURLByKey = jarMap
        parsesByKey = parseMap
        // .unknown type-3 sites (tokenised subscription apis) sit in
        // no kind pool; they are sniffed after the CMS phase and join
        // the py/JS pools with their probed kind.
        let unknownPool = probeableSites.filter { site in
            !pyPool.contains { $0.key == site.key } && !jsPool.contains { $0.key == site.key }
        }
        let total = cmsSites.count + pyPool.count + jsPool.count + jarPool.count + unknownPool.count
        searchTotalCount = total
        var done = 0
        var responded = 0
        var out: [(site: TVBoxConfig.Site, items: [VodItem])] = []
        /// Sites that answered with zero results (v1.96): streamed
        /// into `emptySites` as they answer, so the rail's folded
        /// 无结果 section grows live instead of only at the end.
        var empty: [TVBoxConfig.Site] = []
        // Per-category tallies: a whole category failing must be
        // sayable in the final note, not hidden in the global count.
        var catTried: [String: Int] = [:]
        var catResponded: [String: Int] = [:]
        var poolNotes: [String] = []

        func foundCount() -> Int { out.reduce(0) { $0 + $1.items.count } }
        func statusLine(_ prefix: String) -> String {
            "\(prefix) · 已找到 \(foundCount()) 部 · 已搜 \(done)/\(total) 站"
        }
        /// v2.22: the per-answer tick used to drop the phase name,
        /// so during the long CMS phase the status line read only
        /// "已找到 N 部 · 已搜 d/t 站" — the user could not tell
        /// which pool was being searched. Every phase now sets
        /// phasePrefix before it starts; tick() keeps it.
        var phasePrefix = "正在搜 CMS 站"
        func tick() {
            done += 1
            searchDoneCount = done
            progressText = "\(phasePrefix) · 已找到 \(foundCount()) 部 · 已搜 \(done)/\(total) 站"
        }

        // CMS sites are independent HTTP calls: search them in
        // parallel — but bounded (12 at a time). The old code fired
        // every CMS site at once, which on a 100+ site config opened
        // a hundred simultaneous connections and spiked memory and
        // socket pressure for no speed gain past a dozen. Results
        // still stream in as each site answers (results = out per
        // arrival), so the first hits reach the screen just as fast.
        let cms = cmsSites
        catTried["CMS"] = cms.count
        var errorSamples: [String] = []
        await withTaskGroup(of: (TVBoxConfig.Site, Result<[VodItem], Error>?).self) { group in
            /// Main-actor isolated: it touches @State (results /
            /// emptySites) and the main-actor local tick(). A plain
            /// nested func here inherits no isolation from the
            /// enclosing function, so calling tick() from it was a
            /// hard error (#266); callers await into it instead.
            @MainActor func handleResult(_ site: TVBoxConfig.Site, _ raced: Result<[VodItem], Error>?) {
                switch raced {
                case .success(let items):
                    responded += 1
                    catResponded["CMS", default: 0] += 1
                    if !items.isEmpty {
                        out.append((site, items))
                        results = out
                    } else {
                        empty.append(site)
                        emptySites = empty
                    }
                case .failure(let error):
                    if errorSamples.count < 3 {
                        errorSamples.append("\(site.name)：\(shortError(error))")
                    }
                case nil:
                    if errorSamples.count < 3 {
                        errorSamples.append("\(site.name)：12 秒超时")
                    }
                }
                tick()
            }
            var pending = 0
            for site in cms {
                if Task.isCancelled { break }
                group.addTask {
                    let raced = await withTimeoutError(12) {
                        do { return .success(try await CMSClient(site: site).search(keyword: kw)) }
                        catch { return .failure(error) }
                    }
                    return (site, raced)
                }
                pending += 1
                if pending >= 12, let next = await group.next() {
                    await handleResult(next.0, next.1)
                    pending -= 1
                }
            }
            if Task.isCancelled { group.cancelAll() }
            for await (site, raced) in group {
                if Task.isCancelled { group.cancelAll(); break }
                await handleResult(site, raced)
            }
        }
        // Sniff the .unknown subscription sites (same probe the
        // browse page uses, same cache): CMS results are already on
        // screen by now, so this never delays the fast category.
        // v2.22: the sniff used to run serially — one dead unknown
        // site cost up to 6 s before any py/JS search could start,
        // and a config with several of them stalled the whole run
        // for close to a minute. Sniff up to 6 at a time now (same
        // bounded pattern as the CMS phase); each answer still
        // ticks the progress counters, and pool appends stay on the
        // main actor — the group only returns (site, kind) pairs.
        if !Task.isCancelled {
            phasePrefix = "正在识别站点类型"
            await withTaskGroup(of: (TVBoxConfig.Site, TVBoxConfig.Site.Kind?).self) { group in
                var pending = 0
                for site in unknownPool {
                    if Task.isCancelled { break }
                    group.addTask {
                        let kind = await withTimeout(6) { await SiteBrowseView.sniffKind(for: site) } ?? nil
                        return (site, kind)
                    }
                    pending += 1
                    if pending >= 6, let next = await group.next() {
                        if let kind = next.1 {
                            probedKinds[next.0.key] = kind
                            if kind == .spiderPY { pyPool.append(next.0) }
                            else if kind == .spiderJS { jsPool.append(next.0) }
                        }
                        pending -= 1
                        tick()
                    }
                }
                if Task.isCancelled { group.cancelAll() }
                for await next in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    if let kind = next.1 {
                        probedKinds[next.0.key] = kind
                        if kind == .spiderPY { pyPool.append(next.0) }
                        else if kind == .spiderJS { jsPool.append(next.0) }
                    }
                    tick()
                }
            }
        }
        // The py and JS bridges each hold ONE loaded site on ONE
        // serial queue, so their searches run serially under a HARD
        // deadline (see hardTimeout). Circuit breaker: if one spider
        // wedges the bridge's serial queue synchronously, EVERY
        // later site on that bridge can only ever time out — after
        // 3 misses in a row, skip the rest of that pool instead of
        // burning 15 s per site on a dead queue.
        // Health ordering (v1.40): sites with a proven record
        // answer first; chronic failures sink to the back of
        // their serial pool instead of eating the front of it.
        pyPool.sort {
            SiteHealth.score(PySiteBrowseView.healthKey(for: $0))
                > SiteHealth.score(PySiteBrowseView.healthKey(for: $1))
        }
        var pyMisses = 0
        phasePrefix = "正在搜 py 站"
        for (index, site) in pyPool.enumerated() {
            if Task.isCancelled { break }
            if pyMisses >= 3 {
                poolNotes.append("py 站连续 3 个超时或失败，疑似 Python 运行时被某个站点卡住，已跳过剩余 \(pyPool.count - index) 个 py 站（逐站打开不受影响）")
                done += pyPool.count - index
                break
            }
            catTried["py", default: 0] += 1
            progressText = statusLine("正在搜 py 站：\(site.name)")
            let items = await hardTimeout(15) { await searchPy(site, keyword: kw) }
            if let items {
                pyMisses = 0
                responded += 1
                catResponded["py", default: 0] += 1
                if !items.isEmpty { out.append((site, items)); results = out }
                else { empty.append(site); emptySites = empty }
            } else {
                pyMisses += 1
            }
            tick()
        }
        var jsMisses = 0
        phasePrefix = "正在搜 JS 站"
        for (index, site) in jsPool.enumerated() {
            if Task.isCancelled { break }
            if jsMisses >= 3 {
                poolNotes.append("JS 站连续 3 个超时或失败，疑似 JS 运行时被某个站点卡住，已跳过剩余 \(jsPool.count - index) 个 JS 站（逐站打开不受影响）")
                done += jsPool.count - index
                break
            }
            catTried["JS", default: 0] += 1
            progressText = statusLine("正在搜 JS 站：\(site.name)")
            let items = await hardTimeout(15) { await searchJS(site, keyword: kw) }
            if let items {
                jsMisses = 0
                responded += 1
                catResponded["JS", default: 0] += 1
                if !items.isEmpty { out.append((site, items)); results = out }
                else { empty.append(site); emptySites = empty }
            } else {
                jsMisses += 1
            }
            tick()
        }
        let orderedJarPool = jarPool.sorted {
            SiteHealth.score("jar:" + $0.key) > SiteHealth.score("jar:" + $1.key)
        }
        // v2.22: the jar pool had no circuit breaker — py/JS skip
        // the rest after 3 straight misses, but a hung JarProxy
        // used to cost every jar site its full 25 s hard timeout,
        // up to 130 sites in a row. Same rule as the other pools.
        var jarMisses = 0
        phasePrefix = "正在搜 Jar 站"
        for (index, site) in orderedJarPool.enumerated() {
            if Task.isCancelled { break }
            if jarMisses >= 3 {
                poolNotes.append("Jar 站连续 3 个超时或失败，疑似 JarProxy 被某个站点卡住，已跳过剩余 \(orderedJarPool.count - index) 个 Jar 站（逐站打开不受影响）")
                done += orderedJarPool.count - index
                break
            }
            catTried["Jar", default: 0] += 1
            progressText = statusLine("正在搜 Jar 站：\(site.name)")
            let items = await hardTimeout(25) { await searchJar(site, jar: jarMap[site.key] ?? activeJar, keyword: kw) }
            if let items {
                jarMisses = 0
                responded += 1
                catResponded["Jar", default: 0] += 1
                if !items.isEmpty { out.append((site, items)); results = out }
                else { empty.append(site); emptySites = empty }
            } else {
                jarMisses += 1
            }
            tick()
        }
        var catNotes: [String] = []
        for (label, key) in [("CMS", "CMS"), ("py", "py"), ("JS", "JS"), ("Jar", "Jar")] {
            let tried = catTried[key] ?? 0
            if tried > 0 && (catResponded[key] ?? 0) == 0 {
                catNotes.append("\(label) 类 \(tried) 个站全部无响应")
            }
        }
        catNotes += poolNotes
        if out.isEmpty {
            failureNote = "共搜了 \(total) 个站，\(responded) 个有响应、\(total - responded) 个超时或失败；换个片名或换条线路试试"
            if !errorSamples.isEmpty {
                failureNote += "\n" + errorSamples.joined(separator: "\n")
            }
        }
        finalNote = (Task.isCancelled ? "已停止 · " : "")
            + "搜完 \(total) 个站 · \(responded) 个有响应 · 命中 \(out.reduce(0) { $0 + $1.items.count }) 条"
        if !catNotes.isEmpty {
            finalNote += "（" + catNotes.joined(separator: "；") + "）"
        }
        if !empty.isEmpty {
            finalNote += " · \(empty.count) 个站无结果"
        }
        searchDoneCount = done
        searched = true
        searching = false
    }

    private func searchPy(_ site: TVBoxConfig.Site, keyword: String) async -> [VodItem]? {
        do {
            let path = try await PySiteBrowseView.downloadSpider(for: site)
            _ = try await SpiderBridge.shared.loadSpider(path: path, extend: site.extJSONString)
            let result = try await SpiderBridge.shared.searchContent(key: keyword)
            return PySiteBrowseView.mapItems(result["list"])
        } catch {
            return nil
        }
    }

    private func searchJar(_ site: TVBoxConfig.Site, jar: String, keyword: String) async -> [VodItem]? {
        do {
            let result = try await JarProxyClient.run(jar: jar, site: site, action: "searchContent",
                                                      extra: ["key": keyword, "quick": false, "searchPg": "1"])
            return PySiteBrowseView.mapItems(result["list"])
        } catch {
            return nil
        }
    }

    private func searchJS(_ site: TVBoxConfig.Site, keyword: String) async -> [VodItem]? {
        do {
            let ruleRef = try JSSiteBrowseView.resolveRuleRef(site)
            try await JSBridge.shared.loadRule(reference: ruleRef)
            let result = try await JSBridge.shared.search(key: keyword, pg: 1)
            return PySiteBrowseView.mapItems(result["list"])
        } catch {
            return nil
        }
    }
}


/// Poster cell for the search grid: PosterCell's layout, but the
/// corner badge is an orange capsule (site name in 全部 mode, the
/// item's remarks in single-site mode), matching the reference
/// search page.
private struct SearchPosterCell: View {
    let item: VodItem
    let badge: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Rectangle()
                    .fill(Theme.glass)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay {
                        if !item.pic.isEmpty {
                            PosterImage(urlString: item.pic)
                        }
                    }
                    .posterFrame()
                if !badge.isEmpty {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.orange, in: Capsule())
                        .padding(6)
                }
            }
            Text(item.name)
                .font(.footnote).foregroundStyle(Theme.text.opacity(0.92))
                .lineLimit(1)
            if !item.year.isEmpty {
                Text(item.year).font(.caption).foregroundStyle(Theme.textDim)
            }
        }
    }
}


/// Wrapping chip row for the recent-search words (simple flow:
/// horizontal scroll per line is overkill — a scrollable wrap via
/// LazyVGrid with adaptive columns reads fine).
private struct FlowChips: View {
    let words: [String]
    let onTap: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(words, id: \.self) { word in
                Text(word)
                    .font(.subheadline)
                    .lineLimit(1)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Theme.glass, in: Capsule())
                    .foregroundStyle(Theme.text)
                    .onTapGesture { Haptics.tap(); onTap(word) }
            }
        }
    }
}


/// Recent-search chips with a per-chip delete button (v1.80):
/// tap the word to search it, tap × to drop just that entry.
private struct DeletableFlowChips: View {
    let words: [String]
    let onTap: (String) -> Void
    let onDelete: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(words, id: \.self) { word in
                HStack(spacing: 4) {
                    Text(word)
                        .font(.subheadline)
                        .lineLimit(1)
                        .onTapGesture { Haptics.tap(); onTap(word) }
                    Button { Haptics.tap(); onDelete(word) } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.textDim)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Theme.glass, in: Capsule())
                .foregroundStyle(Theme.text)
            }
        }
    }
}


/// Resume-once box for hardTimeout: whichever racer finishes first
/// (the work or the deadline) resumes the continuation; the other
/// resume is dropped.
private final class ResumeBox: @unchecked Sendable {
    private var cont: CheckedContinuation<[VodItem]?, Never>?
    private let lock = NSLock()

    init(_ cont: CheckedContinuation<[VodItem]?, Never>) { self.cont = cont }

    func resume(_ value: [VodItem]?) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
