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
    /// v2.16 direction-aware prefetch: the index of the last row
    /// seen, plus the two cancellable prefetch batches (rows and
    /// hero art travel on separate handles so the 6.5 s hero
    /// auto-advance never cancels a row prefetch mid-scroll).
    @State private var lastRowSeen = -1
    @State private var rowPrefetchTask: Task<Void, Never>?
    @State private var heroPrefetchTask: Task<Void, Never>?
    @State private var searchSeed = ""
    @State private var showSearch = false
    @State private var detailItem: TMDBClient.TMDBTitle?
    /// v2.45: per-row failure set (TMDB list keys 0–5) — a
    /// failed row keeps its header and offers a retry instead
    /// of the whole page going blank.
    @State private var failedRows: Set<Int> = []
    /// v2.45: paging-scroll position for the hero carousel
    /// (replaces the page TabView — see hero).
    @State private var heroScrollID: Int?

    private var heroItems: [TMDBClient.TMDBTitle] { Array(trending.prefix(8)) }
    private var heroArt: String? {
        guard heroItems.indices.contains(heroIndex) else { return nil }
        let item = heroItems[heroIndex]
        return item.backdrop.isEmpty ? item.poster : item.backdrop
    }

    /// v2.45: the whole-page empty state only fires when every
    /// list failed or came back empty — one failed list used to
    /// blank the page even when five rows had painted.
    private var allListsEmpty: Bool {
        trending.isEmpty && week.isEmpty && nowPlaying.isEmpty
            && movies.isEmpty && shows.isEmpty && top.isEmpty
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
                        // v2.21: skeleton fades out instead of
                        // vanishing the instant the feed lands.
                        SkeletonHero().transition(.opacity)
                        SkeletonPosterGrid().padding(.horizontal, 18).transition(.opacity)
                    } else if allListsEmpty {
                        EmptyStateCopy.loadFailed(
                            message: "检查密钥与网络后重试",
                            retry: { Task { await load() } })
                            .padding(.horizontal, 18)
                            .padding(.top, 90)
                    } else {
                        if !trending.isEmpty { hero }
                        posterRow("本周热门", week, rowIndex: 0)
                        posterRow("正在热映", nowPlaying, rowIndex: 1)
                        posterRow("热门电影", movies, rowIndex: 2)
                        posterRow("热门剧集", shows, rowIndex: 3)
                        posterRow("高分佳作", top, rowIndex: 4)
                    }
                }
                .padding(.bottom, 110)   // clear the floating tab bar
                .animation(Theme.animStandard, value: loading)
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
        .onDisappear {
            rowPrefetchTask?.cancel()
            heroPrefetchTask?.cancel()
        }
    }

    // MARK: Data

    /// v2.03 staged load: a cached feed paints instantly —
    /// no skeleton, no waiting on the network — and the refresh
    /// swaps in behind it. Only a first-ever launch with no cache
    /// still shows the skeleton while the six lists load.
    /// v2.15: the cache read + JSON decode used to run on the main
    /// actor (.task is main-isolated), blocking the first frame on
    /// a cold disk read. It now runs detached; the paint still
    /// lands on the main actor.
    private func load() async {
        guard TMDBClient.isOn else { loading = false; return }
        let cache = await Task.detached(priority: .userInitiated) {
            TMDBClient.loadDiscoverCache()
        }.value
        if let cache {
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
        syncHeroPosition()
    }

    /// v2.50: trending 落定后把分页位置钉在合法页上（见 hero）——
    /// 首到即指到第一页，刷新后越界的 heroIndex 夹回 0。
    private func syncHeroPosition() {
        if heroScrollID == nil { heroScrollID = trending.first?.id }
        if heroIndex >= trending.count { heroIndex = 0 }
    }

    /// v2.15 incremental refresh: the old version awaited all six
    /// TMDB lists before applying any of them, so one slow endpoint
    /// held the whole page (and the hero carousel) hostage. Each
    /// list now paints the moment it lands; a failed list leaves
    /// the painted cache/row untouched. The cache write (encode +
    /// disk) moved off the main actor, and the hero title-artwork
    /// fetches run concurrently instead of eight serial awaits.
    @State private var refreshGeneration = 0

    private func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        await withTaskGroup(of: (Int, [TMDBClient.TMDBTitle]?).self) { group in
            for key in 0...5 {
                group.addTask { (key, await TMDBClient.discoverList(key)) }
            }
            for await (key, titles) in group {
                // A newer refresh supersedes this one — stop painting.
                guard generation == refreshGeneration else { continue }
                // v2.45: nil = this list's fetch failed — keep any
                // painted rows and mark the row failed so it
                // offers its own retry. [] = genuinely empty.
                guard let titles else {
                    failedRows.insert(key)
                    continue
                }
                failedRows.remove(key)
                guard !titles.isEmpty else { continue }
                applyList(key, titles)
            }
        }
        guard generation == refreshGeneration, !trending.isEmpty else { return }
        let fresh = TMDBClient.DiscoverCache(
            savedAt: Date().timeIntervalSince1970,
            trending: trending, week: week, movies: movies,
            shows: shows, top: top, nowPlaying: nowPlaying)
        Task.detached(priority: .utility) { TMDBClient.saveDiscoverCache(fresh) }
        // v2.03 prefetch throttling: hero art + the first row only,
        // 10 URLs max — the old 14-URL fan-out fired on every load
        // including cache repaints.
        prefetchPosters(heroItems.map { $0.backdrop.isEmpty ? $0.poster : $0.backdrop }
            + week.prefix(4).map(\.poster))
        // Title artwork for the hero pages, fetched once per title.
        let missing = heroItems.filter { logos[$0.id] == nil }
        guard !missing.isEmpty else { return }
        await withTaskGroup(of: (Int, String).self) { group in
            for item in missing {
                group.addTask { (item.id, await TMDBClient.logo(for: item)) }
            }
            for await (id, url) in group {
                guard generation == refreshGeneration else { continue }
                logos[id] = url
            }
        }
    }

    /// v2.45: re-fetch one failed list — the row retry button
    /// and the pull-to-refresh path both land here. A retry that
    /// still fails leaves the row marked failed, so the button
    /// stays; a retry that returns an empty list clears the
    /// failure and the row simply stays hidden.
    private func retryRow(_ key: Int) async {
        guard let titles = await TMDBClient.discoverList(key) else { return }
        failedRows.remove(key)
        guard !titles.isEmpty else { return }
        applyList(key, titles)
    }

    /// One list arriving early paints its row immediately instead
    /// of waiting for the other five (see refresh()).
    private func applyList(_ key: Int, _ titles: [TMDBClient.TMDBTitle]) {
        switch key {
        case 0:
            trending = titles
            syncHeroPosition()
        case 1: week = titles
        case 2: nowPlaying = titles
        case 3: movies = titles
        case 4: shows = titles
        case 5: top = titles
        default: break
        }
    }

    /// Warm the poster cache for the art the user is about to
    /// scroll past, so rows and hero pages don't flash in.
    /// v2.16: routed through the cancellable PosterCache.prefetch
    /// batch — a newer batch supersedes the old one, so art for
    /// rows the user already scrolled past stops downloading.
    private func prefetchPosters(_ urls: [String]) {
        let targets = Array(Set(urls.filter { !$0.isEmpty })).prefix(10)
        guard !targets.isEmpty else { return }
        heroPrefetchTask?.cancel()
        heroPrefetchTask = PosterCache.shared.prefetch(Array(targets))
    }

    /// v2.16 direction-aware row prefetch: a row appearing means
    /// the user scrolled to it, so warm the *next* row in the same
    /// direction — the row below when scrolling down, the row above
    /// when scrolling back up. Replacing the previous batch cancels
    /// art for rows that scrolled off-screen.
    private func rowAppeared(_ index: Int) {
        defer { lastRowSeen = index }
        guard index != lastRowSeen else { return }
        let rows = [week, nowPlaying, movies, shows, top]
        let target = index > lastRowSeen ? index + 1 : index - 1
        guard rows.indices.contains(target) else { return }
        rowPrefetchTask?.cancel()
        rowPrefetchTask = PosterCache.shared.prefetch(
            Array(rows[target].prefix(8).map(\.poster)))
    }

    /// v2.16: warm the next hero page's art (900 px) when the
    /// carousel moves, so the auto-advance never lands on a blank.
    private func prefetchNextHeroArt() {
        guard !heroItems.isEmpty else { return }
        let next = heroItems[(heroIndex + 1) % heroItems.count]
        let art = next.backdrop.isEmpty ? next.poster : next.backdrop
        guard !art.isEmpty else { return }
        heroPrefetchTask?.cancel()
        heroPrefetchTask = PosterCache.shared.prefetch([art], maxPixelSize: 900)
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

    /// v2.45: the hero carousel is a horizontal paging
    /// ScrollView driven by scrollPosition, not a page TabView.
    /// The TabView's own pager swallowed vertical drags that
    /// started on the hero, so a pull-down meant to scroll the
    /// page could flip hero pages — or trip pull-to-refresh
    /// mid-page. The inner scroll view now only ever scrolls
    /// horizontally; vertical drags go straight to the outer
    /// ScrollView, so refresh only engages at the true top with
    /// the system threshold. Auto-advance and the dots still
    /// drive heroIndex; heroIndex drives the scroll position
    /// back the other way (each direction guarded so the two
    /// bindings never ping-pong).
    /// v2.50: paging-misalignment root fix (user screenshot:
    /// neighbour page's art + half a synopsis peeking in from
    /// the left, whole page shifted right). The v2.45 pages
    /// sized themselves with `.containerRelativeFrame(.horizontal)`
    /// — inside a nested ScrollView under ignoresSafeArea(top)
    /// that measurement can come back including the safe area
    /// on the first frame, so each page was wider than the
    /// visible area and every paging stop landed shifted right;
    /// with scrollPosition starting nil there was no alignment
    /// anchor at all. Pages now take an explicit width from a
    /// GeometryReader at the hero level (the real laid-out
    /// width), carry an explicit .id, scroll with anchor
    /// .leading, and syncHeroPosition() pins the position to
    /// the first page the moment trending lands — so a paging
    /// stop can only be an exact multiple of the page width.
    private var hero: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(heroItems) { item in
                            heroPage(item)
                                .frame(width: geo.size.width)
                                .id(item.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $heroScrollID, anchor: .leading)
                .frame(height: 540)
                .onChange(of: heroScrollID) { _, newID in
                    guard let newID,
                          let idx = heroItems.firstIndex(where: { $0.id == newID }),
                          idx != heroIndex else { return }
                    heroIndex = idx
                    lastHeroTouch = Date()
                    prefetchNextHeroArt()
                }
                .onChange(of: heroIndex) { _, _ in
                    guard heroItems.indices.contains(heroIndex) else { return }
                    let id = heroItems[heroIndex].id
                    guard heroScrollID != id else { return }
                    heroScrollID = id
                }

                // Dot indicators (Rex: small dots under the synopsis;
                // v2.20: the active page stretches into a pill, the
                // rest stay dots — a row of equal circles gave no
                // sense of position at a glance).
                HStack(spacing: 6) {
                    ForEach(heroItems.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == heroIndex ? Color.white : Color.white.opacity(0.35))
                            .frame(width: i == heroIndex ? 18 : 7, height: 7)
                    }
                }
                .padding(.bottom, 14)
            }
            .frame(height: 540)
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
                    TMDBScoreBadge(score: item.score)
                }
                if !item.overview.isEmpty {
                    Text(item.overview)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(2)
                }
                // v2.50: the white play capsule (v2.32) is gone —
                // the user asked the cover to only present. Tap
                // still opens the TMDB detail sheet; the context
                // menu still offers cross-line search.
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
    private func posterRow(_ title: String, _ items: [TMDBClient.TMDBTitle], rowIndex: Int) -> some View {
        // Row keys in refresh() are 0 trending / 1 week / 2 now
        // playing / 3 movies / 4 shows / 5 top — the hero owns
        // key 0, so a poster's list key is its row index + 1.
        let listKey = rowIndex + 1
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
                    .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
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
            .onAppear { rowAppeared(rowIndex) }
        } else if failedRows.contains(listKey) {
            // v2.45: this list's fetch failed — the row keeps its
            // header and offers a retry instead of the page
            // going blank or the row silently vanishing.
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.title3.bold()).foregroundStyle(Theme.text)
                    Spacer()
                }
                .padding(.horizontal, 18)
                Button {
                    Haptics.tap()
                    Task { await retryRow(listKey) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("这一行没拉到数据")
                        Text("重新加载").font(.subheadline.weight(.semibold))
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.glass, in: RoundedRectangle(cornerRadius: Theme.posterRadius))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18)
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
        .onTapGesture { Haptics.tap(); openSearch(for: item.title) }
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

/// TMDB score chip (v2.08): a glass capsule, not the old solid blue
/// block — the Rex glass spec allows no solid colour blocks on photo
/// surfaces. The score is TMDB vote_average only; a zero vote hides
/// the chip at the source (TMDBClient), never a fabricated number.
private struct TMDBScoreBadge: View {
    var score: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill").font(.caption2)
            Text("TMDB \(score)").font(.caption.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .glassCapsule()
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
                    .onTapGesture { Haptics.tap(); onSearch(item) }
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
    /// v2.21: the sheet itself slides in from the system; the
    /// content fades in behind it so text/art doesn't hard-pop.
    @State private var appeared = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                ZStack(alignment: .bottomLeading) {
                    let art = item.backdrop.isEmpty ? item.poster : item.backdrop
                    if !art.isEmpty {
                        PosterImage(urlString: art, pixelSize: 900)
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
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))

                HStack(spacing: 8) {
                    Text(item.mediaType == "tv" ? "剧集" : "电影")
                    if !item.year.isEmpty { Text(item.year) }
                    if !item.genres.isEmpty { Text(item.genres.joined(separator: " / ")) }
                    if !item.score.isEmpty {
                        TMDBScoreBadge(score: item.score)
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
            .opacity(appeared ? 1 : 0)
            .onAppear { withAnimation(Theme.animStandard) { appeared = true } }
        }
        .background(Theme.bg)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
