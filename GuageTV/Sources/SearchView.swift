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
    @State private var finalNote = ""
    /// Parse interfaces per site key, filled at search start: results
    /// from imported single-file lines need their own line's parses.
    @State private var parsesByKey: [String: [TVBoxConfig.Parse]] = [:]

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
                statusRow
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

    /// 最近搜索 — stored locally, newest first, capped at 10.
    @State private var recentsList: [String] =
        UserDefaults.standard.stringArray(forKey: "searchRecents.v1") ?? []

    private var recents: [String] { recentsList }

    private func saveRecent(_ kw: String) {
        var list = recents.filter { $0 != kw }
        list.insert(kw, at: 0)
        recentsList = Array(list.prefix(10))
        UserDefaults.standard.set(recentsList, forKey: "searchRecents.v1")
    }

    @ViewBuilder
    private var recentsView: some View {
        if recents.isEmpty {
            hint("跨已导入的 CMS / py / JS 站点一起搜")
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("最近搜索").font(.headline).foregroundStyle(Theme.text)
                        Spacer()
                        Button("清空") {
                            recentsList = []
                            UserDefaults.standard.removeObject(forKey: "searchRecents.v1")
                        }
                        .font(.caption).foregroundStyle(Theme.textDim)
                    }
                    FlowChips(words: recents) { word in
                        keyword = word
                        Task { await run() }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
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
    private var statusRow: some View {
        if searching {
            HStack(spacing: 8) {
                ProgressView().tint(Theme.text)
                Text(progressText.isEmpty ? "搜索中…" : progressText)
                    .font(.footnote).foregroundStyle(Theme.textDim)
                Spacer()
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
            hint("先在设置里导入一个配置，搜索才能开工")
        } else if searching && results.isEmpty {
            Spacer()
            ProgressView().tint(Theme.text)
            Spacer()
        } else if searched && results.isEmpty {
            hint(failureNote.isEmpty ? "没有搜到结果" : "没有搜到结果\n\(failureNote)")
        } else if !searched {
            recentsView
        } else if false {
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
        let parses = parsesByKey[site.key] ?? config?.parses ?? []
        switch site.kind {
        case .spiderPY:
            PyDetailLoaderView(site: site, item: item, parses: parses)
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

    private func run() async {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty, !searching else { return }
        saveRecent(kw)
        searching = true
        searched = false
        results = []
        failureNote = ""
        finalNote = ""
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
        parsesByKey = parseMap
        let total = cmsSites.count + pyPool.count + jsPool.count
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
        var errorSamples: [String] = []
        await withTaskGroup(of: (TVBoxConfig.Site, Result<[VodItem], Error>?).self) { group in
            for site in cms {
                group.addTask {
                    let raced = await withTimeoutError(12) {
                        do { return .success(try await CMSClient(site: site).search(keyword: kw)) }
                        catch { return .failure(error) }
                    }
                    return (site, raced)
                }
            }
            for await (site, raced) in group {
                switch raced {
                case .success(let items):
                    responded += 1
                    if !items.isEmpty {
                        out.append((site, items))
                        results = out
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
        }
        // The py and JS bridges each hold ONE loaded site, so their
        // searches run serially under a HARD deadline (see hardTimeout).
        for site in pyPool {
            progressText = "正在搜 py 站：\(site.name)…"
            let items = await hardTimeout(15) { await searchPy(site, keyword: kw) }
            if let items {
                responded += 1
                if !items.isEmpty { out.append((site, items)); results = out }
            }
            tick()
        }
        for site in jsPool {
            progressText = "正在搜 JS 站：\(site.name)…"
            let items = await hardTimeout(15) { await searchJS(site, keyword: kw) }
            if let items {
                responded += 1
                if !items.isEmpty { out.append((site, items)); results = out }
            }
            tick()
        }
        if out.isEmpty {
            failureNote = "共搜了 \(total) 个站，\(responded) 个有响应、\(total - responded) 个超时或失败；换个片名或换条线路试试"
            if !errorSamples.isEmpty {
                failureNote += "\n" + errorSamples.joined(separator: "\n")
            }
        }
        finalNote = "搜完 \(total) 个站 · \(responded) 个有响应 · 命中 \(out.reduce(0) { $0 + $1.items.count }) 条"
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
                    .onTapGesture { onTap(word) }
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
