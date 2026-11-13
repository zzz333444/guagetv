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
    @State private var renamingEntry: ConfigLibrary.Entry?
    @State private var renameText = ""
    /// Which line card currently has its swipe-delete revealed.
    @State private var swipeOpenID: String?
    /// Direct-open route for single-file (py / JS) lines: tapping
    /// the card pushes its one site's browse page immediately.
    @State private var directRoute: FileSiteRoute?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("资源库").font(.largeTitle.bold()).foregroundStyle(Theme.text)
                    Spacer()
                    Button("编辑") { showGroupEditor = true }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Theme.glass, in: Capsule())
                        .foregroundStyle(Theme.text)
                        .sheet(isPresented: $showGroupEditor, onDismiss: refreshLibrary) {
                            GroupEditorView()
                        }
                }

                ForEach(lineSections(), id: \.title) { section in
                    Text(section.title).font(.headline).foregroundStyle(Theme.section)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(section.items) { entry in
                            SwipeRevealDelete(id: entry.id, openID: $swipeOpenID, onDelete: {
                                config = ConfigLibrary.remove(id: entry.id)
                                swipeOpenID = nil
                                refreshLibrary()
                            }) {
                                lineCard(entry)
                            }
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
                        }
                    }
                } else {
                    GlassCard {
                        VStack(spacing: 10) {
                            Image(systemName: "tray.and.arrow.down")
                                .font(.title2).foregroundStyle(Theme.textDim)
                            Text("还没有资源").foregroundStyle(Theme.text)
                            Text("导入一个 TVBox 配置或猫源，站点会出现在这里")
                                .font(.footnote).foregroundStyle(Theme.textDim)
                                .multilineTextAlignment(.center)
                            Button("去导入", action: onImportTap)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 18).padding(.vertical, 8)
                                .background(.white, in: Capsule())
                                .foregroundStyle(.black)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                if let lives = config?.lives, !lives.isEmpty {
                    Text("直播源").font(.headline).foregroundStyle(Theme.section)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(lives, id: \.name) { live in
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
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .background(AmbientBackground(imageURL: nil))
        .onAppear { refreshLibrary() }
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

    /// Cached per-line kind summaries. Parsing every stored config
    /// on the main thread made the library scroll stutter, so:
    /// appear paints the UserDefaults cache instantly, then a
    /// detached task recomputes off-main and rewrites the cache
    /// (rebuilt from the live entry list, so imports/deletes
    /// invalidate stale rows automatically).
    private static let kindSummaryCacheKey = "libraryKindSummary.v2"

    private func refreshLibrary() {
        entries = ConfigLibrary.entries()
        activeID = ConfigLibrary.activeID()
        groups = ConfigLibrary.groups()
        let liveIDs = Set(entries.map(\.id))
        if let cached = UserDefaults.standard.dictionary(forKey: Self.kindSummaryCacheKey) as? [String: String] {
            kindSummary = cached.filter { liveIDs.contains($0.key) }
        }
        let snapshot = entries
        Task.detached(priority: .utility) {
            let summary = Self.computeKindSummary(for: snapshot)
            UserDefaults.standard.set(summary, forKey: Self.kindSummaryCacheKey)
            await MainActor.run { kindSummary = summary }
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
    private func relativeDay(_ ts: TimeInterval) -> String {
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

    /// Section order: custom groups (creation order) → the automatic
    /// Python 文件 group → ungrouped lines.
    private func lineSections() -> [(title: String, items: [ConfigLibrary.Entry])] {
        guard !entries.isEmpty else { return [] }
        var sections: [(title: String, items: [ConfigLibrary.Entry])] = []
        for group in groups {
            let items = entries.filter { ConfigLibrary.effectiveGroupID(for: $0) == group.id }
            if !items.isEmpty { sections.append((group.name, items)) }
        }
        let pyItems = entries.filter { ConfigLibrary.effectiveGroupID(for: $0) == ConfigLibrary.pyAutoGroupID }
        if !pyItems.isEmpty { sections.append(("Python 文件", pyItems)) }
        let loose = entries.filter { ConfigLibrary.effectiveGroupID(for: $0) == nil }
        if !loose.isEmpty {
            sections.append((sections.isEmpty ? "我的线路" : "未分组", loose))
        }
        return sections
    }

    /// One line = one big card (Rex's 资源库 layout): icon, freshness
    /// + status dot, name, route role, content mix. Tapping a card
    /// makes it the active config everywhere (发现/搜索 follow); its
    /// sites are stored separately and load instantly, no
    /// re-download. Long-press: rename （备注名）, set home line,
    /// move to a group, or delete.
    private func lineCard(_ entry: ConfigLibrary.Entry) -> some View {
        let isActive = entry.id == activeID
        let isHome = entry.id == ConfigLibrary.homeLineID()
        let isFile = ConfigLibrary.isPyFileEntry(entry) || entry.sourceURL.hasPrefix("js-import://")
        let shown = ConfigLibrary.shownName(entry)
        return LightGlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top) {
                    ZStack {
                        Circle().fill(Theme.accent.opacity(0.25)).frame(width: 38, height: 38)
                        Text(String(shown.prefix(1)))
                            .font(.headline).foregroundStyle(Theme.text)
                    }
                    Spacer()
                    HStack(spacing: 5) {
                        Text(relativeDay(entry.addedAt))
                            .font(.caption2).foregroundStyle(Theme.textDim)
                        Circle().fill(isActive ? Theme.ok : Color.gray.opacity(0.55))
                            .frame(width: 7, height: 7)
                    }
                }
                Text(shown)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text).lineLimit(2)
                Text(isActive ? "主线路" : (isHome ? "首页线路" : (isFile ? "点按打开" : "点按启用")))
                    .font(.caption)
                    .foregroundStyle(isActive ? Theme.ok : (isHome ? Theme.accent : Theme.textDim))
                Text(kindSummary[entry.id] ?? "\(entry.siteCount) 个站点")
                    .font(.caption2).foregroundStyle(Theme.textDim).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isActive ? Theme.accent.opacity(0.55) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            // A tap while any card's delete is revealed just closes
            // it (the usual swipe-list behaviour).
            if swipeOpenID != nil {
                withAnimation(.easeOut(duration: 0.18)) { swipeOpenID = nil }
                return
            }
            Haptics.tap()
            // Single-file lines (py / JS imports) open their one
            // site directly — no activate-and-hunt in the grid below.
            if let route = fileRoute(for: entry) {
                directRoute = route
                return
            }
            guard !isActive else { return }
            config = ConfigLibrary.activate(id: entry.id)
            JarProxyClient.warmLine(id: entry.id)
            refreshLibrary()
        }
        .contextMenu {
            Button {
                renameText = ConfigLibrary.alias(for: entry.id) ?? ""
                renamingEntry = entry
            } label: {
                Label("改备注名", systemImage: "pencil")
            }
            if !isHome {
                Button {
                    ConfigLibrary.setHomeLineID(entry.id)
                    refreshLibrary()
                } label: {
                    Label("设为首页线路", systemImage: "house")
                }
            }
            Menu("移动到分组") {
                Button("未分组") {
                    ConfigLibrary.setGroup(entryID: entry.id, groupID: ConfigLibrary.noGroupID)
                    refreshLibrary()
                }
                if ConfigLibrary.isPyFileEntry(entry) {
                    Button("Python 文件（自动）") {
                        ConfigLibrary.setGroup(entryID: entry.id, groupID: ConfigLibrary.pyAutoGroupID)
                        refreshLibrary()
                    }
                }
                ForEach(groups) { group in
                    Button(group.name) {
                        ConfigLibrary.setGroup(entryID: entry.id, groupID: group.id)
                        refreshLibrary()
                    }
                }
            }
            Button(role: .destructive) {
                config = ConfigLibrary.remove(id: entry.id)
                refreshLibrary()
            } label: {
                Label("删除线路", systemImage: "trash")
            }
        }
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

/// Left-swipe delete reveal for grid cards (the library is a
/// grid, not a List, so the reveal is hand-rolled): the card
/// slides over a red delete panel; the drag runs simultaneously
/// with the page scroll and only bites on horizontal drags.
private struct SwipeRevealDelete<Content: View>: View {
    let id: String
    @Binding var openID: String?
    let onDelete: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var dragX: CGFloat = 0

    private let reveal: CGFloat = 78
    private var base: CGFloat { openID == id ? -reveal : 0 }
    private var offset: CGFloat { min(0, max(-reveal - 14, base + dragX)) }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                onDelete()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash")
                    Text("删除").font(.caption2)
                }
                .foregroundStyle(.white)
                .frame(width: reveal)
                .frame(maxHeight: .infinity)
                .background(Color.red.opacity(0.85),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .opacity(offset < -8 ? 1 : 0)

            content()
                .offset(x: offset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 14, coordinateSpace: .local)
                        .onChanged { v in
                            guard abs(v.translation.width) > abs(v.translation.height) else { return }
                            dragX = v.translation.width
                        }
                        .onEnded { v in
                            withAnimation(.easeOut(duration: 0.18)) {
                                if base + v.translation.width < -reveal / 2 {
                                    openID = id
                                } else if openID == id, v.translation.width > 12 {
                                    openID = nil
                                }
                                dragX = 0
                            }
                        }
                )
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
                        Text("还没有自建分组。导入的 py 文件会自动收进「Python 文件」组。")
                            .font(.footnote).foregroundStyle(Theme.textDim)
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

/// GlassCard's flat-glass sibling for long scrolling grids: a
/// translucent fill + stroke instead of a live blur material per
/// card (stacked .ultraThinMaterial was the scroll-stutter source).
private struct LightGlassCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Theme.glass, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.glassStroke, lineWidth: 1))
    }
}
