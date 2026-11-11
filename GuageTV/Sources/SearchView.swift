import SwiftUI

/// Search across all imported sites: CMS natively, py spiders via
/// the embedded Python runtime, drpy sites via the JS engine.
struct SearchView: View {
    var config: TVBoxConfig?
    @Environment(\.dismiss) private var dismiss

    @State private var keyword = ""
    @State private var results: [(site: TVBoxConfig.Site, items: [VodItem])] = []
    @State private var searching = false
    @State private var searched = false
    @State private var progressText = ""
    @State private var failureNote = ""

    private var cmsSites: [TVBoxConfig.Site] {
        (config?.sites ?? []).filter { $0.kind == .cmsJSON || $0.kind == .cmsXML }
    }
    private var pySites: [TVBoxConfig.Site] {
        (config?.sites ?? []).filter { $0.kind == .spiderPY && $0.searchable != 0 }
    }
    private var jsSites: [TVBoxConfig.Site] {
        (config?.sites ?? []).filter { ($0.kind == .spiderJS || $0.kind == .drpyJS) && $0.searchable != 0 }
    }
    private var hasSites: Bool { !cmsSites.isEmpty || !pySites.isEmpty || !jsSites.isEmpty }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                content
            }
            .background(AmbientBackground(imageURL: nil))
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }.foregroundStyle(Theme.text)
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textDim)
                TextField("搜片名", text: $keyword)
                    .foregroundStyle(Theme.text)
                    .submitLabel(.search)
                    .onSubmit { Task { await run() } }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Theme.glass, in: Capsule())
            Button("搜索") { Task { await run() } }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(.white, in: Capsule())
                .foregroundStyle(.black)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if !hasSites {
            hint("先在设置里导入一个配置，搜索才能开工")
        } else if searching && results.isEmpty {
            Spacer()
            ProgressView().tint(Theme.text)
            Spacer()
        } else if searched && results.isEmpty {
            hint(failureNote.isEmpty ? "没有搜到结果" : "没有搜到结果\n\(failureNote)")
        } else if !searched {
            hint("跨已导入的 CMS / py / JS 站点一起搜")
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(results, id: \.site.id) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(group.site.name)
                                .font(.headline).foregroundStyle(Theme.text)
                                .padding(.horizontal, 18)
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(group.items) { item in
                                    NavigationLink {
                                        destination(for: group.site, item: item)
                                    } label: {
                                        PosterCell(item: item)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 18)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 40)
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
        }
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
        switch site.kind {
        case .spiderPY:
            PyDetailLoaderView(site: site, item: item, parses: config?.parses ?? [])
        case .spiderJS, .drpyJS:
            JSDetailLoaderView(site: site, item: item,
                               ruleRef: (try? JSSiteBrowseView.resolveRuleRef(site)) ?? "",
                               parses: config?.parses ?? [])
        default:
            DetailLoaderView(site: site, item: item, parses: config?.parses ?? [])
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

    private func run() async {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty, !searching else { return }
        searching = true
        searched = false
        results = []
        failureNote = ""
        let total = cmsSites.count + pySites.count + jsSites.count
        var done = 0
        var responded = 0
        var out: [(site: TVBoxConfig.Site, items: [VodItem])] = []

        func tick() {
            done += 1
            progressText = "已搜 \(done)/\(total) 个站点 · 命中 \(out.reduce(0) { $0 + $1.items.count }) 条"
        }

        // CMS sites are independent HTTP calls: search them all at
        // once instead of one by one.
        let cms = cmsSites
        await withTaskGroup(of: (TVBoxConfig.Site, [VodItem]?).self) { group in
            for site in cms {
                group.addTask {
                    let items = await withTimeout(12) {
                        try? await CMSClient(site: site).search(keyword: kw)
                    }
                    return (site, items)
                }
            }
            for await (site, items) in group {
                if let items {
                    responded += 1
                    if !items.isEmpty {
                        out.append((site, items))
                        results = out
                    }
                }
                tick()
            }
        }
        // The py and JS bridges each hold ONE loaded site, so their
        // searches still run serially — but each has a deadline.
        for site in pySites {
            let items = await withTimeout(15) { await searchPy(site, keyword: kw) } ?? nil
            if let items {
                responded += 1
                if !items.isEmpty { out.append((site, items)); results = out }
            }
            tick()
        }
        for site in jsSites {
            let items = await withTimeout(15) { await searchJS(site, keyword: kw) } ?? nil
            if let items {
                responded += 1
                if !items.isEmpty { out.append((site, items)); results = out }
            }
            tick()
        }
        if out.isEmpty {
            failureNote = "共搜了 \(total) 个站，\(responded) 个有响应、\(total - responded) 个超时或失败；换个片名或换条线路试试"
        }
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
