import SwiftUI

/// A titled horizontal poster row on the Discover page.
struct DiscoverSection: Identifiable {
    var title: String
    var items: [VodItem]
    var id: String { title }
}

/// 发现 (Discover) — Rex's home layout:
/// full-bleed hero carousel (backdrop, title, meta, synopsis, ratings),
/// then one horizontal poster row per section （正在热映 / 电影 / 电视剧 /
/// 综艺 / 动漫…), then a 分类浏览 strip. Content is fed by the active
/// site's homeContent once the runtimes land; structure is final.
struct DiscoverView: View {
    var config: TVBoxConfig?
    var heroItems: [VodItem] = []
    var sections: [DiscoverSection] = []
    @State private var heroIndex = 0
    @State private var liveHero: [VodItem] = []
    @State private var liveSections: [DiscoverSection] = []
    @State private var feedLineID = ""
    @State private var feedConfig: TVBoxConfig?
    @State private var showLinePicker = false
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var layout = HomeLayout.shared
    @State private var cwPlayEntry: HistoryStore.Entry?

    /// First CMS site of the HOME line feeds the Discover page (the
    /// home line is chosen with the 编辑 button and may differ from
    /// the active line).
    private var activeSite: TVBoxConfig.Site? {
        (feedConfig ?? config)?.sites.first { $0.kind == .cmsJSON || $0.kind == .cmsXML }
    }
    private var displayHero: [VodItem] { liveHero.isEmpty ? heroItems : liveHero }
    private var displaySections: [DiscoverSection] { liveSections.isEmpty ? sections : liveSections }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(layout.visibleModules) { module in
                        switch module {
                        case .hero: hero
                        case .continueWatching: continueWatchingRow
                        case .updates: updatesRow
                        case .sections: sectionsGroup
                        case .categories: categoryBrowse
                        }
                    }
                }
                // The scroll view bleeds to the top edge for the
                // hero; when the hero is hidden or not first, keep
                // the first module clear of the status bar instead.
                .padding(.top, layout.visibleModules.first == .hero ? 0 : 54)
                .padding(.bottom, 110)   // clear the floating tab bar
            }
            .ignoresSafeArea(edges: .top)   // hero bleeds under the status bar (Rex look)
            .background(AmbientBackground(imageURL: displayHero.first?.pic))
            .overlay(alignment: .bottomLeading) { editButton }
            .sheet(isPresented: $showLinePicker) { linePicker }
            .fullScreenCover(item: $cwPlayEntry) { entry in
                PlayerView(
                    episodes: [PlayerView.EpisodeRef(name: entry.episodeName, url: entry.episodeURL)],
                    startIndex: 0, header: entry.playHeader, title: entry.name,
                    historyID: entry.id, resumeAt: entry.positionSeconds)
            }
            .onAppear {
                if feedLineID.isEmpty {
                    feedLineID = ConfigLibrary.homeLineID()
                    feedConfig = ConfigLibrary.load(id: feedLineID)
                }
            }
        }
        .task(id: activeSite?.id ?? "") { await loadFeed() }
    }

    /// 继续观看 — straight from HistoryStore: unfinished episodes,
    /// newest first, tap resumes in place.
    @ViewBuilder
    private var continueWatchingRow: some View {
        if !history.continueWatching.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("继续观看").font(.title3.bold()).foregroundStyle(Theme.text)
                    .padding(.horizontal, 18)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(history.continueWatching) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                PosterImage(urlString: entry.pic)
                                    .frame(width: 92, height: 138)
                                    .posterFrame()
                                Text(entry.name).font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.text).lineLimit(1)
                                Text(entry.episodeName).font(.caption2)
                                    .foregroundStyle(Theme.textDim).lineLimit(1)
                                if entry.durationSeconds > 0 {
                                    ProgressView(value: min(entry.positionSeconds / entry.durationSeconds, 1))
                                        .tint(Theme.accent)
                                }
                            }
                            .frame(width: 92)
                            .contentShape(Rectangle())
                            .onTapGesture { cwPlayEntry = entry }
                        }
                    }
                    .padding(.horizontal, 18)
                }
            }
        }
    }

    /// The feed's poster rows, as one arrangeable module.
    @ViewBuilder
    private var sectionsGroup: some View {
        ForEach(displaySections) { section in
            posterRow(title: section.title, items: section.items)
        }
    }

    /// 追剧更新 — favourited series, updated ones first; the header
    /// opens the full 追剧 page. Hidden entirely with no favourites.
    @ViewBuilder
    private var updatesRow: some View {
        let favs = history.favourites.sorted { a, b in
            if a.hasUpdate != b.hasUpdate { return a.hasUpdate }
            return a.updatedAt > b.updatedAt
        }
        if !favs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("追剧更新").font(.title3.bold()).foregroundStyle(Theme.text)
                    let count = favs.filter(\.hasUpdate).count
                    if count > 0 {
                        Text("\(count) 部有更新")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    NavigationLink {
                        WatchlistView()
                    } label: {
                        HStack(spacing: 2) {
                            Text("全部").font(.subheadline)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(Theme.textDim)
                    }
                }
                .padding(.horizontal, 18)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(favs.prefix(12)) { entry in
                            NavigationLink {
                                EntryDetailDestination(entry: entry)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    ZStack(alignment: .topTrailing) {
                                        PosterImage(urlString: entry.pic)
                                            .frame(width: 92, height: 138)
                                            .posterFrame()
                                        if entry.hasUpdate {
                                            Circle().fill(Theme.accent)
                                                .frame(width: 10, height: 10)
                                                .padding(6)
                                        }
                                    }
                                    Text(entry.name).font(.caption.weight(.semibold))
                                        .foregroundStyle(Theme.text).lineLimit(1)
                                    Text(entry.lastRemarks.isEmpty ? entry.siteName : entry.lastRemarks)
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textDim).lineLimit(1)
                                }
                                .frame(width: 92)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18)
                }
            }
        }
    }

    private var editButton: some View {
        Button { showLinePicker = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "pencil").font(.footnote.weight(.semibold))
                Text("编辑").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.glassStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        }
        .padding(.leading, 18)
        .padding(.bottom, 108)
    }

    private var linePicker: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ConfigLibrary.entries()) { entry in
                        Button {
                            ConfigLibrary.setHomeLineID(entry.id)
                            feedLineID = entry.id
                            feedConfig = ConfigLibrary.load(id: entry.id)
                            liveHero = []
                            liveSections = []
                            showLinePicker = false
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).foregroundStyle(Theme.text)
                                    Text("\(entry.siteCount) 个站点")
                                        .font(.caption).foregroundStyle(Theme.textDim)
                                }
                                Spacer()
                                if entry.id == feedLineID {
                                    Text("首页").font(.caption.weight(.semibold)).foregroundStyle(Theme.ok)
                                    Image(systemName: "checkmark").foregroundStyle(Theme.ok)
                                }
                            }
                        }
                        .listRowBackground(Color.white.opacity(0.06))
                    }
                } header: {
                    Text("首页线路")
                }
                Section {
                    ForEach(layout.order) { module in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(Theme.textDim)
                            Text(module.title).foregroundStyle(Theme.text)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { layout.isVisible(module) },
                                set: { layout.setVisible(module, $0) }))
                                .labelsHidden()
                        }
                        .listRowBackground(Color.white.opacity(0.06))
                    }
                    .onMove { source, destination in
                        layout.move(from: source, to: destination)
                    }
                } header: {
                    Text("首页模块")
                } footer: {
                    Text("拖动调整模块在首页的顺序，关掉的模块不在首页显示。")
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("首页设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showLinePicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func loadFeed() async {
        guard let site = activeSite else { return }
        let client = CMSClient(site: site)
        guard let home = try? await client.home() else { return }
        liveHero = Array(home.list.prefix(5))
        var secs: [DiscoverSection] = []
        if !home.list.isEmpty {
            secs.append(DiscoverSection(title: "最新更新 · \(site.name)", items: home.list))
        }
        for cls in home.classes.prefix(6) {
            if let items = try? await client.category(tid: cls.0, page: 1), !items.isEmpty {
                secs.append(DiscoverSection(title: cls.1, items: items))
            }
        }
        liveSections = secs
        // Poster backfill: many采集站 lists carry no vod_pic at all.
        let missing = (liveHero + secs.flatMap(\.items))
            .filter { $0.pic.isEmpty }.map(\.id)
        if !missing.isEmpty {
            let map = await client.fetchPosterMap(ids: missing)
            if !map.isEmpty {
                func fill(_ list: [VodItem]) -> [VodItem] {
                    list.map { item in
                        guard item.pic.isEmpty, let pic = map[item.id] else { return item }
                        var copy = item
                        copy.pic = pic
                        return copy
                    }
                }
                liveHero = fill(liveHero)
                liveSections = liveSections.map {
                    DiscoverSection(title: $0.title, items: fill($0.items))
                }
            }
        }
    }

    // MARK: Hero carousel

    private var hero: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $heroIndex) {
                ForEach(displayHero.indices, id: \.self) { idx in
                    heroPage(displayHero[idx]).tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 520)

            if displayHero.count > 1 {
                HStack(spacing: 6) {
                    ForEach(displayHero.indices, id: \.self) { i in
                        Circle()
                            .fill(i == heroIndex ? Color.white : Color.white.opacity(0.35))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .task(id: displayHero.count) {
            // Gentle auto-advance; a manual swipe just moves the
            // starting point, the loop keeps going from there.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if Task.isCancelled { break }
                if displayHero.count > 1 {
                    withAnimation { heroIndex = (heroIndex + 1) % displayHero.count }
                }
            }
        }
    }

    /// Rex's hero: full-bleed art, everything centred — big title,
    /// a meta line, and rating badges as coloured chips.
    private func heroPage(_ item: VodItem) -> some View {
        ZStack {
            if !item.pic.isEmpty {
                PosterImage(urlString: item.pic)
                    .frame(height: 520).clipped()
            } else {
                heroPlaceholder.frame(height: 520)
            }
            LinearGradient(colors: [.black.opacity(0.30), .clear, .black.opacity(0.45), Theme.bg],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 9) {
                Spacer()
                Text(item.name)
                    .font(.system(size: 34, weight: .heavy))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.text)
                    .shadow(color: .black.opacity(0.65), radius: 10, y: 2)
                    .lineLimit(2)
                    .padding(.horizontal, 28)
                HStack(spacing: 8) {
                    if !item.remarks.isEmpty { Text(item.remarks) }
                    if !item.year.isEmpty { Text(item.year) }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.text.opacity(0.85))
                .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
                if !item.score.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "star.fill").font(.caption2)
                        Text("豆瓣 \(item.score)").font(.caption.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color(red: 0.02, green: 0.55, blue: 0.27), in: Capsule())
                }
                Spacer().frame(height: 30)
            }
        }
    }

    private var heroPlaceholder: some View {
        LinearGradient(colors: [Color(red: 0.20, green: 0.14, blue: 0.34),
                                Color(red: 0.05, green: 0.05, blue: 0.09)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Poster rows

    private func posterRow(title: String, items: [VodItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let site = activeSite {
                NavigationLink {
                    SiteBrowseView(site: site, parses: (feedConfig ?? config)?.parses ?? [])
                } label: {
                    HStack {
                        Text(title).font(.title3.bold()).foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textDim)
                    }
                    .padding(.horizontal, 18)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                HStack {
                    Text(title).font(.title3.bold()).foregroundStyle(Theme.text)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textDim)
                }
                .padding(.horizontal, 18)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        if let site = activeSite {
                            NavigationLink {
                                DetailLoaderView(site: site, item: item, lineID: feedLineID, parses: (feedConfig ?? config)?.parses ?? [])
                            } label: {
                                posterCard(item)
                            }
                            .buttonStyle(.plain)
                        } else {
                            posterCard(item)
                        }
                    }
                }
                .padding(.horizontal, 18)
            }
        }
    }

    private func posterCard(_ item: VodItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                if !item.pic.isEmpty {
                    PosterImage(urlString: item.pic)
                        .frame(width: 112, height: 168)
                        .posterFrame()
                } else {
                    posterPlaceholder.frame(width: 112, height: 168).posterFrame()
                }
                if !item.remarks.isEmpty {
                    Text(item.remarks)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(Theme.text)
                        .padding(6)
                }
            }
            Text(item.name)
                .font(.footnote).foregroundStyle(Theme.text.opacity(0.92))
                .lineLimit(1).frame(width: 112, alignment: .leading)
            if !item.year.isEmpty {
                Text(item.year).font(.caption).foregroundStyle(Theme.textDim)
            }
        }
    }

    private var posterPlaceholder: some View {
        Rectangle().fill(Color.white.opacity(0.08))
            .overlay(Image(systemName: "film").foregroundStyle(Theme.text.opacity(0.3)))
    }

    // MARK: Category browse

    /// Feed sections that are real classes (everything except the
    /// "最新更新" recommendation row).
    private var classSections: [DiscoverSection] {
        displaySections.filter { !$0.title.hasPrefix("最新更新") }
    }

    /// Poster wall source: score-sorted when the feed carries
    /// scores, else the feed order; deduped, capped.
    private var wallItems: [VodItem] {
        let all = displaySections.flatMap(\.items)
        let scored = all.filter { !$0.score.isEmpty }
            .sorted { (Double($0.score) ?? 0) > (Double($1.score) ?? 0) }
        let base = scored.count >= 6 ? scored : all
        var seen = Set<String>()
        return Array(base.filter { seen.insert($0.id).inserted }.prefix(12))
    }

    private var categoryBrowse: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("分类浏览").font(.title3.bold()).foregroundStyle(Theme.text)
                .padding(.horizontal, 18)
            if classSections.isEmpty {
                siteCardGrid
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                          spacing: 12) {
                    ForEach(classSections) { section in
                        if let site = activeSite {
                            NavigationLink {
                                SiteBrowseView(site: site, parses: (feedConfig ?? config)?.parses ?? [])
                            } label: {
                                categoryTile(section)
                            }
                            .buttonStyle(.plain)
                        } else {
                            categoryTile(section)
                        }
                    }
                }
                .padding(.horizontal, 18)
                posterWall
            }
        }
    }

    /// Rex-style category tile: the class name over a fan of its
    /// own posters.
    private func categoryTile(_ section: DiscoverSection) -> some View {
        let pics = Array(section.items.map(\.pic).filter { !$0.isEmpty }.prefix(3))
        return ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.glass)
            HStack {
                Spacer()
                ZStack {
                    ForEach(pics.indices, id: \.self) { i in
                        PosterImage(urlString: pics[i])
                            .frame(width: 46, height: 68)
                            .posterFrame()
                            .shadow(color: .black.opacity(0.45), radius: 5, y: 2)
                            .rotationEffect(.degrees(Double(i - (pics.count - 1) / 2) * 11))
                            .offset(x: CGFloat(i - (pics.count - 1) / 2) * 27)
                    }
                }
                .padding(.trailing, 34)
            }
            Text(section.title)
                .font(.headline)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .padding(12)
        }
        .frame(height: 92)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Theme.glassStroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The poster wall under the category tiles （高分精选 when the
    /// feed carries scores, plain 海报墙 otherwise).
    @ViewBuilder
    private var posterWall: some View {
        if wallItems.count >= 6, let site = activeSite {
            VStack(alignment: .leading, spacing: 12) {
                Text(wallItems.filter { !$0.score.isEmpty }.count >= 6 ? "高分精选" : "海报墙")
                    .font(.title3.bold()).foregroundStyle(Theme.text)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)],
                          spacing: 10) {
                    ForEach(wallItems) { item in
                        NavigationLink {
                            DetailLoaderView(site: site, item: item, lineID: feedLineID,
                                             parses: (feedConfig ?? config)?.parses ?? [])
                        } label: {
                            PosterImage(urlString: item.pic)
                                .frame(height: 158)
                                .frame(maxWidth: .infinity)
                                .posterFrame()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
            }
        }
    }

    /// Fallback while the feed has not landed: the config's sites
    /// as plain cards (the pre-v1.27 behaviour).
    private var siteCardGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                  spacing: 12) {
            ForEach(config?.sites ?? []) { site in
                NavigationLink {
                    SiteBrowseView(site: site, parses: (feedConfig ?? config)?.parses ?? [])
                } label: {
                    GlassCard(padding: 14) {
                        HStack {
                            Image(systemName: "rectangle.stack")
                                .foregroundStyle(Theme.accent)
                            Text(site.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
    }
}
