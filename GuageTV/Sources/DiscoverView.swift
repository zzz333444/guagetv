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
                    hero
                    continueWatchingRow
                    ForEach(displaySections) { section in
                        posterRow(title: section.title, items: section.items)
                    }
                    categoryBrowse
                }
                .padding(.bottom, 110)   // clear the floating tab bar
            }
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
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("选择首页线路")
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
        for cls in home.classes.prefix(3) {
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
        VStack(spacing: 10) {
            TabView(selection: $heroIndex) {
                ForEach(displayHero.indices, id: \.self) { idx in
                    heroPage(displayHero[idx]).tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 430)

            if displayHero.count > 1 {
                HStack(spacing: 6) {
                    ForEach(displayHero.indices, id: \.self) { i in
                        Circle()
                            .fill(i == heroIndex ? Color.white : Color.white.opacity(0.35))
                            .frame(width: 6, height: 6)
                    }
                }
            }
        }
    }

    private func heroPage(_ item: VodItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            if !item.pic.isEmpty {
                PosterImage(urlString: item.pic)
                    .frame(height: 430).clipped()
            } else {
                heroPlaceholder.frame(height: 430)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.55), Theme.bg],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Text(item.name)
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if !item.remarks.isEmpty { Text(item.remarks) }
                    if !item.year.isEmpty { Text(item.year) }
                }
                .font(.subheadline)
                .foregroundStyle(Theme.text.opacity(0.8))
                if !item.score.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                        Text(item.score).fontWeight(.semibold)
                        Text("评分").foregroundStyle(Theme.text.opacity(0.6))
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.text)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
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
            HStack {
                Text(title).font(.title3.bold()).foregroundStyle(Theme.text)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 18)

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

    private var categoryBrowse: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("分类浏览").font(.title3.bold()).foregroundStyle(Theme.text)
                .padding(.horizontal, 18)
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
}
