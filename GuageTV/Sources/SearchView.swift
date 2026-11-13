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
    /// The running search, kept so the 停止 button can cancel it
    /// (entry points used to fire untracked Tasks nobody could stop).
    @State private var searchTask: Task<Void, Never>?
    /// Kinds sniffed for .unknown subscription sites during this
    /// search (key: site.key) — results from such a site must open
    /// in the probed runtime's detail loader, not the CMS default.
    @State private var probedKinds: [String: TVBoxConfig.Site.Kind] = [:]
    /// Parse interfaces per site key, filled at search start: results
    /// from imported single-file lines need their own line's parses.
    @State private var parsesByKey: [String: [TVBoxConfig.Parse]] = [:]
    /// Site filter for the results browser (nil = 全部）: the left
    /// rail lists every site that produced results, tapping one
    /// narrows the poster grid to just that site.
    @State private var selectedSiteKey: String?
    /// The left rail can be hidden from the header's filter button.
    @State private var showSiteFilter = true
    /// Progress counters for the rail's 全部 (done/total) label,
    /// mirrored out of run()'s local tallies as sites answer.
    @State private var searchDoneCount = 0
    @State private var searchTotalCount = 0
    /// The active line's jar URL when the Jar proxy is configured;
    /// jar sites join the search only then.
    @State private var searchJarURL = ""
    /// Per-site jar URLs: cross-line search pulls jar sites from
    /// every library line, and each line ships its own spider jar.
    @State private var jarURLByKey: [String: String] = [:]

    private var cmsSites: [TVBoxConfig.Site] {
        (config?.sites ?? []).filter { $0.kind == .cmsJSON || $0.kind == .cmsXML }
    }
    private var pySites: [TVBoxConfig.Site] {
        (config?.sites ?? []).filter { $0.kind == .spiderPY && $0.searchable != 0 }
    }
    private var jsSites: [TVBoxConfig.Site] {
        (config?.sites ?? []).filter { ($0.kind == .spiderJS || $0.kind == .drpyJS) && $0.searchable != 0 }
    }
    /// Type-3 sites whose api carries no classifiable extension
    /// (tokenised subscription URLs): they land in NO kind pool, so
    /// search used to skip them entirely. run() sniffs them (the
    /// SiteBrowseView probe) and deals them into the py/JS pools.
    private var probeableSites: [TVBoxConfig.Site] {
        (config?.sites ?? []).filter { $0.kind == .unknown && $0.type == 3 && $0.searchable != 0 }
    }
    private var hasSites: Bool {
        !cmsSites.isEmpty || !pySites.isEmpty || !jsSites.isEmpty || !probeableSites.isEmpty
    }
    /// Two poster columns beside the site rail (the rail takes the
    /// rest of the width budget, like the reference layout).
    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 2)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                statusRow
                content
            }
            .background(AmbientBackground(imageURL: nil))
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// Reference-layout header: round back button, the search
    /// field as a full-width pill, and a round filter button that
    /// shows/hides the site rail.
    private var headerBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 42, height: 42)
                    .glassCircle()
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textDim)
                TextField("搜片名", text: $keyword)
                    .foregroundStyle(Theme.text)
                    .submitLabel(.search)
                    .onSubmit { beginSearch() }
                if !keyword.isEmpty {
                    Button { keyword = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textDim)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .glassCapsule()
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showSiteFilter.toggle() }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(showSiteFilter ? Theme.accent : Theme.text)
                    .frame(width: 42, height: 42)
                    .glassCircle()
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
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
                        beginSearch()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if searching {
            HStack(spacing: 8) {
                ProgressView().tint(Theme.text)
                Text(progressText.isEmpty ? "搜索中…" : progressText)
                    .font(.footnote).foregroundStyle(Theme.textDim)
                Spacer()
                Button("停止") { stopSearch() }
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Theme.glass, in: Capsule())
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
        } else if !results.isEmpty {
            // Results branch MUST outrank the !searched branch below:
            // `searched` stays false for the whole run, so ordering
            // the recents branch first hid every in-flight result
            // behind the recents list until the run ended — the
            // "results only appear when the search finishes" bug.
            resultsBrowser
            if searching {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.text)
                    Text(progressText.isEmpty ? "还在搜其他站点…" : progressText)
                        .font(.footnote).foregroundStyle(Theme.textDim)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
        } else if searched {
            hint(failureNote.isEmpty ? "没有搜到结果" : "没有搜到结果\n\(failureNote)")
        } else {
            recentsView
        }
    }

    /// The groups the poster grid shows: everything, or just the
    /// site picked on the rail.
    private var visibleGroups: [(site: TVBoxConfig.Site, items: [VodItem])] {
        guard let key = selectedSiteKey else { return results }
        return results.filter { $0.site.key == key }
    }

    /// Results browser (reference layout): a site rail on the
    /// left — 全部 with the (done/total) progress, then one row
    /// per site that found something, with an orange count badge —
    /// and a two-column poster grid on the right. In 全部 mode
    /// each poster carries its site name as an orange badge; in
    /// single-site mode the badge falls back to the item's remarks.
    private var resultsBrowser: some View {
        HStack(alignment: .top, spacing: 0) {
            if showSiteFilter { siteRail }
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: gridColumns, spacing: 14) {
                    ForEach(visibleGroups, id: \.site.id) { group in
                        ForEach(group.items) { item in
                            NavigationLink {
                                destination(for: group.site, item: item)
                            } label: {
                                SearchPosterCell(
                                    item: item,
                                    badge: selectedSiteKey == nil ? group.site.name : item.remarks)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
    }

    private var siteRail: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 2) {
                railRow(title: "全部",
                        badge: nil,
                        countText: "(\(searchDoneCount)/\(searchTotalCount))",
                        selected: selectedSiteKey == nil) {
                    selectedSiteKey = nil
                }
                ForEach(results, id: \.site.id) { group in
                    railRow(title: group.site.name,
                            badge: "\(group.items.count)",
                            countText: nil,
                            selected: selectedSiteKey == group.site.key) {
                        selectedSiteKey = group.site.key
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .frame(width: 118)
    }

    private func railRow(title: String, badge: String?, countText: String?,
                         selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                if let countText {
                    Text(countText).font(.caption2).monospacedDigit()
                }
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange, in: Capsule())
                }
            }
            .foregroundStyle(selected ? .white : Theme.text.opacity(0.85))
            .padding(.horizontal, 8).padding(.vertical, 9)
            .background(selected ? Color.blue : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        switch probedKinds[site.key] ?? site.kind {
        case .spiderPY:
            PyDetailLoaderView(site: site, item: item, parses: parses)
        case .spiderJAR:
            JarDetailLoaderView(site: site, item: item, parses: parses,
                                jar: jarURLByKey[site.key] ?? searchJarURL)
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

    /// All search entry points funnel here so the run is tracked
    /// and the 停止 button can actually cancel it.
    private func beginSearch() {
        searchTask?.cancel()
        searchTask = Task { await run() }
    }

    private func stopSearch() {
        searchTask?.cancel()
        if searching { progressText = "正在停止…" }
    }

    /// Main-actor isolated on purpose: every @State write below
    /// (results, progressText, probedKinds…) then lands on the main
    /// actor the moment a site answers, so each site's section
    /// paints immediately instead of waiting for a later redraw.
    /// The bridge/HTTP calls it awaits are nonisolated and still
    /// run off the main actor.
    @MainActor
    private func run() async {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty, !searching else { return }
        saveRecent(kw)
        searching = true
        searched = false
        results = []
        failureNote = ""
        finalNote = ""
        probedKinds = [:]
        selectedSiteKey = nil
        searchDoneCount = 0
        searchTotalCount = 0
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
        // Jar sites join in when a proxy is set: the active line
        // first, then every other full config line in the library —
        // each line resolves its OWN spider jar, and results keep a
        // per-site jar map so details open against the right jar.
        var jarPool: [TVBoxConfig.Site] = []
        var jarMap: [String: String] = [:]
        var activeJar = ""
        if JarProxyClient.configured {
            if let resolved = JarProxyClient.jarURL(from: config) {
                activeJar = resolved
                for site in (config?.sites ?? []) where site.kind == .spiderJAR && site.searchable != 0 {
                    jarMap[site.key] = resolved
                    jarPool.append(site)
                }
            }
            for entry in ConfigLibrary.entries() where entry.id != activeID
                && !entry.sourceURL.hasPrefix("py-import://") && !entry.sourceURL.hasPrefix("js-import://") {
                if jarPool.count >= 130 { break }
                guard let cfg = ConfigLibrary.load(id: entry.id),
                      let resolved = JarProxyClient.jarURL(from: cfg, base: entry.sourceURL) else { continue }
                for site in cfg.sites where site.kind == .spiderJAR && site.searchable != 0 {
                    if jarMap[site.key] == nil {
                        jarMap[site.key] = resolved
                        jarPool.append(site)
                        if parseMap[site.key] == nil { parseMap[site.key] = cfg.parses }
                    }
                }
            }
        }
        searchJarURL = activeJar
        jarURLByKey = jarMap
        parsesByKey = parseMap
        // .unknown type-3 sites (tokenised subscription apis) sit in
        // no kind pool; they are sniffed after the CMS phase and join
        // the py/JS pools with their probed kind.
        let unknownPool = probeableSites.filter { site in
            !pyPool.contains { $0.key == site.key } && !jsPool.contains { $0.key == site.key }
        }
        let total = cmsSites.count + pyPool.count + jsPool.count + jarPool.count + unknownPool.count
        searchTotalCount = total
        var done = 0
        var responded = 0
        var out: [(site: TVBoxConfig.Site, items: [VodItem])] = []
        // Per-category tallies: a whole category failing must be
        // sayable in the final note, not hidden in the global count.
        var catTried: [String: Int] = [:]
        var catResponded: [String: Int] = [:]
        var poolNotes: [String] = []

        func foundCount() -> Int { out.reduce(0) { $0 + $1.items.count } }
        func statusLine(_ prefix: String) -> String {
            "\(prefix) · 已找到 \(foundCount()) 部 · 已搜 \(done)/\(total) 站"
        }
        func tick() {
            done += 1
            searchDoneCount = done
            progressText = "已找到 \(foundCount()) 部 · 已搜 \(done)/\(total) 站"
        }

        // CMS sites are independent HTTP calls: search them all at
        // once instead of one by one.
        let cms = cmsSites
        catTried["CMS"] = cms.count
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
                    catResponded["CMS", default: 0] += 1
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
        // Sniff the .unknown subscription sites (same probe the
        // browse page uses, same cache): CMS results are already on
        // screen by now, so this never delays the fast category.
        if !Task.isCancelled {
            for (index, site) in unknownPool.enumerated() {
                if Task.isCancelled { break }
                progressText = "正在识别站点类型 \(index + 1)/\(unknownPool.count)：\(site.name)…"
                let kind = await withTimeout(6) { await SiteBrowseView.sniffKind(for: site) } ?? nil
                if let kind {
                    probedKinds[site.key] = kind
                    if kind == .spiderPY { pyPool.append(site) }
                    else if kind == .spiderJS { jsPool.append(site) }
                }
                tick()
            }
        }
        // The py and JS bridges each hold ONE loaded site on ONE
        // serial queue, so their searches run serially under a HARD
        // deadline (see hardTimeout). Circuit breaker: if one spider
        // wedges the bridge's serial queue synchronously, EVERY
        // later site on that bridge can only ever time out — after
        // 3 misses in a row, skip the rest of that pool instead of
        // burning 15 s per site on a dead queue.
        var pyMisses = 0
        for (index, site) in pyPool.enumerated() {
            if Task.isCancelled { break }
            if pyMisses >= 3 {
                poolNotes.append("py 站连续 3 个超时或失败，疑似 Python 运行时被某个站点卡住，已跳过剩余 \(pyPool.count - index) 个 py 站（逐站打开不受影响）")
                done += pyPool.count - index
                break
            }
            catTried["py", default: 0] += 1
            progressText = statusLine("正在搜 py 站：\(site.name)")
            let items = await hardTimeout(15) { await searchPy(site, keyword: kw) }
            if let items {
                pyMisses = 0
                responded += 1
                catResponded["py", default: 0] += 1
                if !items.isEmpty { out.append((site, items)); results = out }
            } else {
                pyMisses += 1
            }
            tick()
        }
        var jsMisses = 0
        for (index, site) in jsPool.enumerated() {
            if Task.isCancelled { break }
            if jsMisses >= 3 {
                poolNotes.append("JS 站连续 3 个超时或失败，疑似 JS 运行时被某个站点卡住，已跳过剩余 \(jsPool.count - index) 个 JS 站（逐站打开不受影响）")
                done += jsPool.count - index
                break
            }
            catTried["JS", default: 0] += 1
            progressText = statusLine("正在搜 JS 站：\(site.name)")
            let items = await hardTimeout(15) { await searchJS(site, keyword: kw) }
            if let items {
                jsMisses = 0
                responded += 1
                catResponded["JS", default: 0] += 1
                if !items.isEmpty { out.append((site, items)); results = out }
            } else {
                jsMisses += 1
            }
            tick()
        }
        for site in jarPool {
            if Task.isCancelled { break }
            catTried["Jar", default: 0] += 1
            progressText = statusLine("正在搜 Jar 站：\(site.name)")
            let items = await hardTimeout(25) { await searchJar(site, jar: jarMap[site.key] ?? activeJar, keyword: kw) }
            if let items {
                responded += 1
                catResponded["Jar", default: 0] += 1
                if !items.isEmpty { out.append((site, items)); results = out }
            }
            tick()
        }
        var catNotes: [String] = []
        for (label, key) in [("CMS", "CMS"), ("py", "py"), ("JS", "JS"), ("Jar", "Jar")] {
            let tried = catTried[key] ?? 0
            if tried > 0 && (catResponded[key] ?? 0) == 0 {
                catNotes.append("\(label) 类 \(tried) 个站全部无响应")
            }
        }
        catNotes += poolNotes
        if out.isEmpty {
            failureNote = "共搜了 \(total) 个站，\(responded) 个有响应、\(total - responded) 个超时或失败；换个片名或换条线路试试"
            if !errorSamples.isEmpty {
                failureNote += "\n" + errorSamples.joined(separator: "\n")
            }
        }
        finalNote = (Task.isCancelled ? "已停止 · " : "")
            + "搜完 \(total) 个站 · \(responded) 个有响应 · 命中 \(out.reduce(0) { $0 + $1.items.count }) 条"
        if !catNotes.isEmpty {
            finalNote += "（" + catNotes.joined(separator: "；") + "）"
        }
        searchDoneCount = done
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

    private func searchJar(_ site: TVBoxConfig.Site, jar: String, keyword: String) async -> [VodItem]? {
        do {
            let result = try await JarProxyClient.run(jar: jar, site: site, action: "searchContent",
                                                      extra: ["key": keyword, "quick": false, "searchPg": "1"])
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


/// Poster cell for the search grid: PosterCell's layout, but the
/// corner badge is an orange capsule (site name in 全部 mode, the
/// item's remarks in single-site mode), matching the reference
/// search page.
private struct SearchPosterCell: View {
    let item: VodItem
    let badge: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay {
                        if !item.pic.isEmpty {
                            PosterImage(urlString: item.pic)
                        }
                    }
                    .posterFrame()
                if !badge.isEmpty {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.orange, in: Capsule())
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
