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
                    VStack(spacing: 10) {
                        ForEach(section.items) { entry in
                            lineRow(entry)
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
        }
    }

    private func refreshLibrary() {
        entries = ConfigLibrary.entries()
        activeID = ConfigLibrary.activeID()
        groups = ConfigLibrary.groups()
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

    /// One saved config = one group of its own. Tapping a line makes
    /// it the active config everywhere (发现/搜索 follow); its sites
    /// are stored separately and load instantly, no re-download.
    private func lineRow(_ entry: ConfigLibrary.Entry) -> some View {
        let isActive = entry.id == activeID
        return GlassCard(padding: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.25)).frame(width: 38, height: 38)
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.subheadline).foregroundStyle(Theme.text)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text).lineLimit(1)
                    Text("\(entry.siteCount) 个站点 · \(URL(string: entry.sourceURL)?.host ?? "")")
                        .font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                }
                Spacer()
                if isActive {
                    Text("使用中")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.ok)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.ok.opacity(0.15), in: Capsule())
                } else {
                    Text("点按启用")
                        .font(.caption).foregroundStyle(Theme.textDim)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isActive ? Theme.accent.opacity(0.55) : Color.clear, lineWidth: 1))
        .onTapGesture {
            guard !isActive else { return }
            config = ConfigLibrary.activate(id: entry.id)
            refreshLibrary()
        }
        .contextMenu {
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
        }
    }

    private func sourceCard(_ site: TVBoxConfig.Site) -> some View {
        GlassCard(padding: 14) {
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
        site.kind == .spiderJAR ? "主线路 · 本平台不支持" : "主线路"
    }

    private func kindText(_ kind: TVBoxConfig.Site.Kind) -> String {
        switch kind {
        case .cmsXML, .cmsJSON: return "CMS 接口"
        case .spiderPY: return "Python 源"
        case .spiderJS: return "JS 源"
        case .drpyJS: return "drpy 源"
        case .spiderJAR: return "Jar 源 · iOS 无 JVM"
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
                                    Text(entry.name).font(.subheadline.weight(.semibold))
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
