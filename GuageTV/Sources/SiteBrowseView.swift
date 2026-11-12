import SwiftUI

/// Grid poster cell shared by site browsing and search results.
struct PosterCell: View {
    let item: VodItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                // The bare Rectangle owns the cell's size (2:3 from the
                // column width — fully deterministic); the poster rides
                // in an overlay, so a loaded image's intrinsic size can
                // never feed back into grid layout.
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay {
                        if !item.pic.isEmpty {
                            PosterImage(urlString: item.pic)
                        }
                    }
                    .posterFrame()
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
                .lineLimit(1)
            if !item.year.isEmpty {
                Text(item.year).font(.caption).foregroundStyle(Theme.textDim)
            }
        }
    }
}

/// Loads a CMS detail page, then hands off to DetailView. Non-CMS sites
/// reach here only after their runtimes land; until then it fails soft.
struct DetailLoaderView: View {
    let site: TVBoxConfig.Site
    let item: VodItem
    /// The line this site belongs to (defaults to the active line);
    /// the Discover home-line passes its own line here.
    var lineID: String? = nil
    var parses: [TVBoxConfig.Parse] = []
    @State private var detail: VodDetail?
    @State private var failed = false

    var body: some View {
        Group {
            if let detail {
                DetailView(detail: detail, header: site.header ?? [:],
                           historySeed: HistorySeed(
                               lineID: lineID ?? ConfigLibrary.activeID() ?? "",
                               siteKey: site.key, siteName: site.name, vodId: item.id),
                           parses: parses)
            } else if failed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.title3)
                    Text("详情加载失败，稍后重试").font(.subheadline)
                }
                .foregroundStyle(Theme.textDim)
            } else {
                ProgressView().tint(Theme.text)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmbientBackground(imageURL: item.pic))
        .task {
            guard site.kind == .cmsJSON || site.kind == .cmsXML else { failed = true; return }
            detail = try? await CMSClient(site: site).detail(id: item.id)
            if detail == nil { failed = true }
        }
    }
}

/// Site browsing: tap a source card in 资源库 → class chips + poster grid
/// → detail → player. CMS sites (the overwhelming majority) work natively;
/// py/JS sites show a holding page until their runtime wires in.
struct SiteBrowseView: View {
    let site: TVBoxConfig.Site
    var parses: [TVBoxConfig.Parse] = []

    @State private var classes: [(String, String)] = []
    @State private var items: [VodItem] = []
    @State private var selectedTid = ""
    @State private var allFilters: [String: [CMSFilterGroup]] = [:]
    @State private var selectedFilters: [String: String] = [:]

    private var currentFilterGroups: [CMSFilterGroup] {
        allFilters[selectedTid] ?? []
    }
    @State private var page = 1
    @State private var loading = true
    @State private var loadingMore = false
    @State private var canLoadMore = false
    @State private var errorText: String?

    private var isCMS: Bool { site.kind == .cmsJSON || site.kind == .cmsXML }
    private var client: CMSClient { CMSClient(site: site) }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        Group {
            if isCMS { cmsBody }
            else if site.kind == .spiderPY { PySiteBrowseView(site: site, parses: parses) }
            else if site.kind == .spiderJS || site.kind == .drpyJS { JSSiteBrowseView(site: site, parses: parses) }
            else if site.kind == .spiderJAR && JarProxyClient.configured { JarSiteBrowseView(site: site, parses: parses) }
            else { pendingBody }
        }
        .navigationTitle(site.name)
        .navigationBarTitleDisplayMode(.inline)
        .background(AmbientBackground(imageURL: items.first?.pic))
        .task { if isCMS { await loadHome() } }
    }

    // MARK: CMS browsing

    private var cmsBody: some View {
        VStack(spacing: 0) {
            if !classes.isEmpty { classChips }
            if !currentFilterGroups.isEmpty { filterRows }
            content
        }
    }

    /// One chip row per filter group the site declares for this
    /// category （年份 / 地区 / 语言 / 排序）. Picking a value reloads
    /// page 1 with it as a query parameter.
    private var filterRows: some View {
        VStack(spacing: 2) {
            ForEach(currentFilterGroups) { group in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text(group.name)
                            .font(.caption.weight(.semibold)).foregroundStyle(Theme.section)
                            .frame(width: 34, alignment: .leading)
                        ForEach(group.options, id: \.value) { option in
                            let active = (selectedFilters[group.key] ?? "") == option.value
                            Text(option.name)
                                .font(.caption.weight(active ? .semibold : .regular))
                                .padding(.horizontal, 11).padding(.vertical, 5)
                                .background(active ? Color.white : Theme.glass, in: Capsule())
                                .foregroundStyle(active ? .black : Theme.text.opacity(0.85))
                                .onTapGesture {
                                    selectedFilters[group.key] = option.value
                                    Task { await reloadWithFilters() }
                                }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func reloadWithFilters() async {
        page = 1
        loading = true
        errorText = nil
        do {
            items = try await client.list(tid: selectedTid.isEmpty ? nil : selectedTid,
                                          page: 1, filters: selectedFilters)
            canLoadMore = items.count >= 10
            Task { await backfillPosters() }
        } catch {
            errorText = "加载失败：\(error.localizedDescription)"
        }
        loading = false
    }

    private var classChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "推荐", tid: "")
                ForEach(classes, id: \.0) { cls in
                    chip(title: cls.1, tid: cls.0)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }

    private func chip(title: String, tid: String) -> some View {
        Text(title)
            .font(.subheadline.weight(selectedTid == tid ? .semibold : .regular))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(selectedTid == tid ? Color.white : Theme.glass, in: Capsule())
            .foregroundStyle(selectedTid == tid ? .black : Theme.text.opacity(0.85))
            .onTapGesture { Task { await selectClass(tid) } }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            Spacer()
            ProgressView().tint(Theme.text)
            Spacer()
        } else if let errorText {
            Spacer()
            VStack(spacing: 12) {
                Text(errorText).font(.subheadline).foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
                Button("重试") { Task { await loadHome() } }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(.white, in: Capsule()).foregroundStyle(.black)
            }
            Spacer()
        } else {
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(items) { item in
                        NavigationLink {
                            DetailLoaderView(site: site, item: item, parses: parses)
                        } label: {
                            PosterCell(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                if canLoadMore {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        if loadingMore {
                            ProgressView().tint(Theme.text)
                        } else {
                            Text("加载更多").font(.subheadline.weight(.medium))
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Theme.glass, in: Capsule())
                    .foregroundStyle(Theme.text)
                    .padding(.vertical, 18)
                }
                Color.clear.frame(height: 96)
            }
        }
    }

    // MARK: Non-CMS holding page

    private var pendingBody: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: site.kind == .spiderJAR ? "nosign" : "hourglass")
                .font(.largeTitle).foregroundStyle(Theme.textDim)
            Text(site.name).font(.headline).foregroundStyle(Theme.text)
            Text(pendingText)
                .font(.subheadline).foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var pendingText: String {
        switch site.kind {
        case .spiderJAR: return "Jar 源要在你自己的 JarProxy 服务器上跑：先在设置页填入代理地址，这类站就能打开。"
        case .spiderPY: return "Python 源：内嵌 Python 运行时在阶段 1 接入中，接入后此站可直接浏览。"
        case .spiderJS, .drpyJS: return "JS 源：JavaScriptCore 运行时在阶段 2 接入中，接入后此站可直接浏览。"
        default: return "此站类型待识别。"
        }
    }

    // MARK: Loading

    private func loadHome() async {
        loading = true
        errorText = nil
        do {
            let home = try await client.home()
            classes = home.classes
            items = home.list
            allFilters = home.filters
            selectedTid = ""
            page = 1
            canLoadMore = home.list.count >= 10
            Task { await backfillPosters() }
        } catch {
            errorText = "加载失败：\(error.localizedDescription)"
        }
        loading = false
    }

    private func selectClass(_ tid: String) async {
        selectedTid = tid
        selectedFilters = [:]
        page = 1
        loading = true
        errorText = nil
        do {
            items = try await client.list(tid: tid.isEmpty ? nil : tid, page: 1, filters: selectedFilters)
            canLoadMore = items.count >= 10
            Task { await backfillPosters() }
        } catch {
            errorText = "加载失败：\(error.localizedDescription)"
        }
        loading = false
    }

    /// Fill posters for pic-less list items with one batched detail call.
    private func backfillPosters() async {
        let missing = items.filter { $0.pic.isEmpty }.map(\.id)
        guard !missing.isEmpty else { return }
        let map = await client.fetchPosterMap(ids: missing)
        guard !map.isEmpty else { return }
        for i in items.indices where items[i].pic.isEmpty {
            if let pic = map[items[i].id] { items[i].pic = pic }
        }
    }

    private func loadMore() async {
        guard canLoadMore, !loadingMore else { return }
        loadingMore = true
        do {
            let next = try await client.list(tid: selectedTid.isEmpty ? nil : selectedTid, page: page + 1, filters: selectedFilters)
            page += 1
            items += next
            canLoadMore = next.count >= 10
            Task { await backfillPosters() }
        } catch {
            canLoadMore = false
        }
        loadingMore = false
    }
}
