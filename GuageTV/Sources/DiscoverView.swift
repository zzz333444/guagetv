import SwiftUI

/// 发现 (Discover) — Rex's home page, rebuilt wholesale (v1.74, user
/// order "把发现页面全部砍掉，直接搬 Rex 的整个页面"): a full-bleed
/// TMDB hero carousel — backdrop, official title artwork, meta line,
/// ratings row, two-line synopsis, dot indicators — over titled
/// poster rows with chevron "more" entries. The old dual-mode page
/// (line feed + arrangeable HomeLayout modules + class chips) is
/// gone. Tapping a poster hands the title to the cross-line search;
/// the hero and long-press open the TMDB detail sheet first.
struct DiscoverView: View {
    var config: TVBoxConfig?
    @State private var trending: [TMDBClient.TMDBTitle] = []
    @State private var week: [TMDBClient.TMDBTitle] = []
    @State private var movies: [TMDBClient.TMDBTitle] = []
    @State private var shows: [TMDBClient.TMDBTitle] = []
    @State private var top: [TMDBClient.TMDBTitle] = []
    @State private var nowPlaying: [TMDBClient.TMDBTitle] = []
    @State private var loading = true
    @State private var heroIndex = 0
    @State private var logos: [Int: String] = [:]
    @State private var lastHeroTouch = Date()
    @State private var searchSeed = ""
    @State private var showSearch = false
    @State private var detailItem: TMDBClient.TMDBTitle?

    private var heroItems: [TMDBClient.TMDBTitle] { Array(trending.prefix(8)) }
    private var heroArt: String? {
        guard heroItems.indices.contains(heroIndex) else { return nil }
        let item = heroItems[heroIndex]
        return item.backdrop.isEmpty ? item.poster : item.backdrop
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if !TMDBClient.isOn {
                        EmptyStateView(
                            icon: "sparkles.tv",
                            title: "发现页由 TMDB 驱动",
                            message: "在「设置 → TMDB 增强」里填入你的 TMDB API 密钥后，这里就是 Rex 同款的热门榜单页",
                            actionTitle: "先去搜索",
                            action: { searchSeed = ""; showSearch = true })
                            .padding(.horizontal, 18)
                            .padding(.top, 90)
                    } else if loading {
                        SkeletonHero()
                        SkeletonPosterGrid().padding(.horizontal, 18)
                    } else if trending.isEmpty {
                        EmptyStateView(
                            icon: "wifi.exclamationmark",
                            title: "TMDB 没拉到数据",
                            message: "检查密钥与网络后重试",
                            actionTitle: "重新加载",
                            action: { Task { await load() } })
                            .padding(.horizontal, 18)
                            .padding(.top, 90)
                    } else {
                        hero
                        posterRow("本周热门", week)
                        posterRow("正在热映", nowPlaying)
                        posterRow("热门电影", movies)
                        posterRow("热门剧集", shows)
                        posterRow("高分佳作", top)
                    }
                }
                .padding(.bottom, 110)   // clear the floating tab bar
            }
            .ignoresSafeArea(edges: .top)   // hero bleeds under the status bar (Rex look)
            .background(AmbientBackground(imageURL: heroArt))
            .refreshable { await load() }
            .sheet(isPresented: $showSearch) {
                SearchView(config: config, initialKeyword: searchSeed)
            }
            .sheet(item: $detailItem) { item in
                TMDBDetailSheet(item: item) { openSearch(for: item.title) }
            }
        }
        .task { await load() }
        .task { await heroAutoAdvance() }
    }

    // MARK: Data

    /// v2.03 staged load: a cached feed (12h) paints instantly —
    /// no skeleton, no waiting on the network — and the refresh
    /// swaps in behind it. Only a first-ever launch with no cache
    /// still shows the skeleton while the six lists load.
    private func load() async {
        guard TMDBClient.isOn else { loading = false; return }
        if let cache = TMDBClient.loadDiscoverCache() {
            apply(cache)
            loading = false
            await refresh()
        } else {
            loading = true
            await refresh()
            loading = false
        }
    }

    private func apply(_ cache: TMDBClient.DiscoverCache) {
        trending = cache.trending
        week = cache.week
        nowPlaying = cache.nowPlaying
        movies = cache.movies
        shows = cache.shows
        top = cache.top
    }

    private func refresh() async {
        async let t = TMDBClient.trending()
        async let w = TMDBClient.trendingWeek()
        async let np = TMDBClient.nowPlaying()
        async let m = TMDBClient.popularMovies()
        async let s = TMDBClient.popularTV()
        async let tp = TMDBClient.topRated()
        let fresh = TMDBClient.DiscoverCache(
            savedAt: Date().timeIntervalSince1970,
            trending: await t, week: await w, movies: await m,
            shows: await s, top: await tp, nowPlaying: await np)
        // A failed refresh leaves the painted cache untouched —
        // never blank a good screen for a bad network.
        guard !fresh.trending.isEmpty else { return }
        apply(fresh)
        TMDBClient.saveDiscoverCache(fresh)
        // v2.03 prefetch throttling: hero art + the first row only,
        // 10 URLs max — the old 14-URL fan-out fired on every load
        // including cache repaints.
        prefetchPosters(heroItems.map { $0.backdrop.isEmpty ? $0.poster : $0.backdrop }
            + week.prefix(4).map(\.poster))
        // Title artwork for the hero pages, fetched once per title.
        for item in heroItems where logos[item.id] == nil {
            logos[item.id] = await TMDBClient.logo(for: item)
        }
    }

    /// Warm the poster cache for the art the user is about to
    /// scroll past, so rows and hero pages don't flash in.
    private func prefetchPosters(_ urls: [String]) {
        let targets = Array(Set(urls.filter { !$0.isEmpty })).prefix(10)
        guard !targets.isEmpty else { return }
        Task.detached(priority: .utility) {
            for url in targets {
                _ = await PosterCache.shared.load(url)
            }
        }
    }

    /// A title tap: seed the search sheet and let SearchView
    /// auto-run the cross-line search.
    private func openSearch(for title: String) {
        Haptics.tap()
        searchSeed = title
        showSearch = true
    }

    // MARK: Hero

    private func heroAutoAdvance() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !heroItems.isEmpty,
                  Date().timeIntervalSince(lastHeroTouch) > 6.5 else { continue }
            withAnimation(.easeInOut(duration: 0.45)) {
                heroIndex = (heroIndex + 1) % heroItems.count
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $heroIndex) {
                ForEach(Array(heroItems.enumerated()), id: \.element.id) { pair in
                    heroPage(pair.element)
                        .tag(pair.offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 540)
            .onChange(of: heroIndex) { _, _ in lastHeroTouch = Date() }

            // Dot indicators (Rex: small dots under the synopsis).
            HStack(spacing: 5) {
                ForEach(heroItems.indices, id: \.self) { i in
                    Circle()
                        .fill(i == heroIndex ? Color.white : Color.white.opacity(0.35))
                        .frame(width: i == heroIndex ? 7 : 5, height: i == heroIndex ? 7 : 5)
                }
            }
            .padding(.bottom, 14)
        }
        .frame(height: 540)
    }

    private func heroPage(_ item: TMDBClient.TMDBTitle) -> some View {
        ZStack(alignment: .bottomLeading) {
            let art = item.backdrop.isEmpty ? item.poster : item.backdrop
            if !art.isEmpty {
                PosterImage(urlString: art, pixelSize: 900)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Rectangle().fill(Theme.glass)
            }
            // Legibility gradients: status bar at the top, the
            // title block at the bottom melting into the page.
            LinearGradient(colors: [.black.opacity(0.35), .clear],
                           startPoint: .top, endPoint: .center)
            LinearGradient(colors: [.clear, .black.opacity(0.55), Theme.bg],
                           startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 9) {
                if let logo = logos[item.id], !logo.isEmpty {
                    PosterImage(urlString: logo, fit: true)
                        .frame(maxWidth: 250, maxHeight: 64, alignment: .leading)
                        .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
                } else {
                    Text(item.title)
                        .font(.system(size: 30, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
                }
                HStack(spacing: 7) {
                    Text(item.mediaType == "tv" ? "剧集" : "电影")
                    if !item.year.isEmpty { Text("·"); Text(item.year) }
                    if !item.genres.isEmpty {
                        Text("·")
                        Text(item.genres.joined(separator: " / "))
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))

                if !item.score.isEmpty {
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill").font(.caption2)
                            Text("TMDB \(item.score)").font(.caption.weight(.bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Color(red: 0.05, green: 0.45, blue: 0.65), in: Capsule())
                    }
                }
                if !item.overview.isEmpty {
                    Text(item.overview)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 34)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap()
            detailItem = item
        }
        .contextMenu {
            Button {
                openSearch(for: item.title)
            } label: {
                Label("跨线搜索", systemImage: "magnifyingglass")
            }
            Button {
                Haptics.tap()
                detailItem = item
            } label: {
                Label("TMDB 详情", systemImage: "info.circle")
            }
        }
    }

    // MARK: Poster rows

    @ViewBuilder
    private func posterRow(_ title: String, _ items: [TMDBClient.TMDBTitle]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.title3.bold()).foregroundStyle(Theme.text)
                    Spacer()
                    NavigationLink {
                        TMDBGridView(title: title, items: items,
                                     onSearch: { openSearch(for: $0.title) },
                                     onDetail: { detailItem = $0 })
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.text.opacity(0.85))
                            .frame(width: 26, height: 26)
                            .glassCircle()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(items) { item in
                            posterCard(item)
                        }
                    }
                    .padding(.horizontal, 18)
                }
            }
        }
    }

    private func posterCard(_ item: TMDBClient.TMDBTitle) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            PosterImage(urlString: item.poster)
                .frame(width: 112, height: 168)
                .posterFrame()
            Text(item.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            HStack(spacing: 5) {
                if !item.year.isEmpty { Text(item.year) }
                if !item.score.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill").font(.system(size: 8))
                        Text(item.score)
                    }
                    .foregroundStyle(Color(red: 0.35, green: 0.75, blue: 0.95))
                }
            }
            .font(.caption2)
            .foregroundStyle(Theme.textDim)
        }
        .frame(width: 112)
        .contentShape(Rectangle())
        .onTapGesture { openSearch(for: item.title) }
        .contextMenu {
            Button {
                openSearch(for: item.title)
            } label: {
                Label("跨线搜索", systemImage: "magnifyingglass")
            }
            Button {
                Haptics.tap()
                detailItem = item
            } label: {
                Label("TMDB 详情", systemImage: "info.circle")
            }
        }
    }
}

/// The "more" page behind a row's chevron: the row's full list as
/// a three-column poster grid (Rex's HomeMoreScreen shape).
private struct TMDBGridView: View {
    var title: String
    var items: [TMDBClient.TMDBTitle]
    var onSearch: (TMDBClient.TMDBTitle) -> Void
    var onDetail: (TMDBClient.TMDBTitle) -> Void

    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        PosterImage(urlString: item.poster)
                            .frame(height: 168)
                            .posterFrame()
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            if !item.year.isEmpty { Text(item.year) }
                            if !item.score.isEmpty { Text("★ \(item.score)") }
                        }
                        .font(.caption2)
                        .foregroundStyle(Theme.textDim)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onSearch(item) }
                    .contextMenu {
                        Button {
                            onSearch(item)
                        } label: {
                            Label("跨线搜索", systemImage: "magnifyingglass")
                        }
                        Button {
                            Haptics.tap()
                            onDetail(item)
                        } label: {
                            Label("TMDB 详情", systemImage: "info.circle")
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 110)
        }
        .background(AmbientBackground(imageURL: items.first?.backdrop))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// TMDB catalogue detail sheet (v1.71): backdrop, meta, synopsis,
/// and the one action this catalogue supports — cross-line search.
private struct TMDBDetailSheet: View {
    var item: TMDBClient.TMDBTitle
    var onSearch: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                ZStack(alignment: .bottomLeading) {
                    let art = item.backdrop.isEmpty ? item.poster : item.backdrop
                    if !art.isEmpty {
                        PosterImage(urlString: art)
                            .frame(height: 260).clipped()
                    } else {
                        Rectangle().fill(Theme.glass).frame(height: 260)
                    }
                    LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                    Text(item.title)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
                        .padding(18)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20))

                HStack(spacing: 8) {
                    Text(item.mediaType == "tv" ? "剧集" : "电影")
                    if !item.year.isEmpty { Text(item.year) }
                    if !item.genres.isEmpty { Text(item.genres.joined(separator: " / ")) }
                    if !item.score.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill").font(.caption2)
                            Text("TMDB \(item.score)").font(.caption.weight(.bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Color(red: 0.05, green: 0.45, blue: 0.65), in: Capsule())
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.text.opacity(0.92))
                .padding(.horizontal, 4)

                if !item.overview.isEmpty {
                    Text(item.overview)
                        .font(.body)
                        .foregroundStyle(Theme.text.opacity(0.9))
                        .padding(.horizontal, 4)
                } else {
                    Text("暂无简介")
                        .font(.body)
                        .foregroundStyle(Theme.textDim)
                        .padding(.horizontal, 4)
                }

                Button {
                    Haptics.tap()
                    dismiss()
                    Task {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        onSearch()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                        Text("跨线搜索「\(item.title)」")
                    }
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.white, in: Capsule())
                }
                .padding(.horizontal, 4)
            }
            .padding(18)
            .padding(.bottom, 20)
        }
        .background(Theme.bg)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
