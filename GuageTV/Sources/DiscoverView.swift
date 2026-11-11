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

    /// First CMS site feeds the Discover page natively (no runtime needed).
    private var activeSite: TVBoxConfig.Site? {
        config?.sites.first { $0.kind == .cmsJSON || $0.kind == .cmsXML }
    }
    private var displayHero: [VodItem] { liveHero.isEmpty ? heroItems : liveHero }
    private var displaySections: [DiscoverSection] { liveSections.isEmpty ? sections : liveSections }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    hero
                    ForEach(displaySections) { section in
                        posterRow(title: section.title, items: section.items)
                    }
                    categoryBrowse
                }
                .padding(.bottom, 110)   // clear the floating tab bar
            }
            .background(AmbientBackground(imageURL: displayHero.first?.pic))
            .preferredColorScheme(.dark)
        }
        .task(id: activeSite?.id ?? "") { await loadFeed() }
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
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if !item.remarks.isEmpty { Text(item.remarks) }
                    if !item.year.isEmpty { Text(item.year) }
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                if !item.score.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                        Text(item.score).fontWeight(.semibold)
                        Text("评分").foregroundStyle(.white.opacity(0.6))
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white)
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
                Text(title).font(.title3.bold()).foregroundStyle(.white)
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
                                DetailLoaderView(site: site, item: item)
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
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            Text(item.name)
                .font(.footnote).foregroundStyle(.white.opacity(0.92))
                .lineLimit(1).frame(width: 112, alignment: .leading)
            if !item.year.isEmpty {
                Text(item.year).font(.caption).foregroundStyle(Theme.textDim)
            }
        }
    }

    private var posterPlaceholder: some View {
        Rectangle().fill(Color.white.opacity(0.08))
            .overlay(Image(systemName: "film").foregroundStyle(.white.opacity(0.3)))
    }

    // MARK: Category browse

    private var categoryBrowse: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("分类浏览").font(.title3.bold()).foregroundStyle(.white)
                .padding(.horizontal, 18)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      spacing: 12) {
                ForEach(config?.sites ?? []) { site in
                    NavigationLink {
                        SiteBrowseView(site: site)
                    } label: {
                        GlassCard(padding: 14) {
                            HStack {
                                Image(systemName: "rectangle.stack")
                                    .foregroundStyle(Theme.accent)
                                Text(site.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.white)
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
