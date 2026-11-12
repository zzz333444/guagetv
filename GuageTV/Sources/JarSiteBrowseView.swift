import SwiftUI

/// Client for the user's own JarProxy server (see the jarproxy
/// project): jar spiders cannot run on iOS — no JVM — so csp_ sites
/// are executed on a JVM the user runs (PC / VPS) and this client
/// just forwards the TVBox spider calls over HTTP. Browse, search,
/// detail and playback resolution all go through POST /run and come
/// back as standard TVBox JSON, mapped exactly like py results.
enum JarProxyClient {
    static var baseURL: String {
        (UserDefaults.standard.string(forKey: "jarProxyURL") ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    static var configured: Bool { !baseURL.isEmpty }

    /// Optional shared token (设置 → Jar 代理 → 口令), sent as a
    /// header when the server has JARPROXY_TOKEN switched on.
    static var token: String {
        (UserDefaults.standard.string(forKey: "jarProxyToken") ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The config's spider jar as an absolute URL. The config field
    /// looks like "./jar/spider.jar;md5;<hex>" — keep the path part
    /// and resolve it against the config's own URL.
    static func jarURL(from config: TVBoxConfig?) -> String? {
        jarURL(from: config, base: UserDefaults.standard.string(forKey: "configSourceURL"))
    }

    /// Same, resolving a relative jar path against an explicit
    /// config source URL — cross-line search needs each line's own
    /// base, not the active line's.
    static func jarURL(from config: TVBoxConfig?, base sourceURL: String?) -> String? {
        guard let raw = config?.spider, !raw.isEmpty else { return nil }
        let path = raw.split(separator: ";").first.map(String.init) ?? raw
        if path.hasPrefix("http") { return path }
        if let baseText = sourceURL, let base = URL(string: baseText),
           let resolved = URL(string: path, relativeTo: base)?.absoluteURL {
            return resolved.absoluteString
        }
        return nil
    }

    /// The jar URL of the currently active line, if it ships one.
    static func activeJarURL() -> String? {
        guard let id = ConfigLibrary.activeID(),
              let config = ConfigLibrary.load(id: id) else { return nil }
        return jarURL(from: config)
    }

    /// Drive credentials the user saved under 设置 → 网盘配置. Sent
    /// with every /run call; the proxy files them where jar spiders
    /// read them (its SharedPreferences store + TVBox/*.txt files).
    /// Only non-empty values are sent.
    static func drivePrefs() -> [String: String] {
        let keys = ["quark_cookie", "uc_cookie", "uc_token", "aliyun",
                    "baidu", "bili_cookie", "xunlei"]
        var prefs: [String: String] = [:]
        for key in keys {
            let value = (UserDefaults.standard.string(forKey: "drive." + key) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { prefs[key] = value }
        }
        return prefs
    }

    static func run(jar: String, site: TVBoxConfig.Site, action: String,
                    extra: [String: Any] = [:]) async throws -> [String: Any] {
        do {
            return try await runOnce(jar: jar, site: site, action: action, extra: extra)
        } catch let failure as Failure where failure.message.contains("timeout") {
            // The proxy may be waking from sleep or converting the
            // jar on first use (free-tier cold start) — one retry
            // after a short pause usually lands.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return try await runOnce(jar: jar, site: site, action: action, extra: extra)
        } catch let urlError as URLError where isRetryable(urlError) {
            // A sleeping free-tier instance drops the first
            // connection outright ("network connection was lost")
            // while it boots — wait longer, then retry once; the
            // retry lands on the awake server.
            let pause: UInt64 = urlError.code == .networkConnectionLost
                ? 5_000_000_000 : 2_000_000_000
            try? await Task.sleep(nanoseconds: pause)
            return try await runOnce(jar: jar, site: site, action: action, extra: extra)
        }
    }

    private static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private static func runOnce(jar: String, site: TVBoxConfig.Site, action: String,
                                extra: [String: Any]) async throws -> [String: Any] {
        let base = baseURL
        guard !base.isEmpty, let url = URL(string: base + "/run") else {
            throw Failure(message: "没有填写 Jar 代理地址（设置页 → Jar 代理）")
        }
        var body: [String: Any] = [
            "jarUrl": jar,
            "class": site.api,
            "action": action,
            "ext": site.extJSONString,
        ]
        let prefs = drivePrefs()
        if !prefs.isEmpty { body["prefs"] = prefs }
        for (key, value) in extra { body[key] = value }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 95
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-JarProxy-Token") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Jar 代理返回了无法识别的内容")
        }
        guard (envelope["ok"] as? Bool) == true else {
            throw Failure(message: envelope["error"] as? String ?? "Jar 代理调用失败")
        }
        let resultText = envelope["result"] as? String ?? ""
        if resultText.isEmpty { return [:] }
        guard let parsed = try JSONSerialization.jsonObject(with: Data(resultText.utf8)) as? [String: Any] else {
            throw Failure(message: "爬虫返回的不是标准 JSON")
        }
        return parsed
    }

    static func healthCheck() async -> String {
        let base = baseURL
        guard !base.isEmpty, let url = URL(string: base + "/health") else {
            return "先填 Jar 代理地址"
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-JarProxy-Token") }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (object?["ok"] as? Bool) == true ? "连接成功，代理在线" : "代理有响应，但状态不对"
        } catch {
            return "连不上：\(error.localizedDescription)"
        }
    }
}

/// Browsing for jar (csp_) sites through the proxy. Same shape as
/// the py browser; every call is one POST /run round-trip.
struct JarSiteBrowseView: View {
    let site: TVBoxConfig.Site
    var parses: [TVBoxConfig.Parse] = []
    var jar: String = ""

    @State private var classes: [(String, String)] = []
    @State private var items: [VodItem] = []
    @State private var selectedTid = ""
    @State private var page = 1
    @State private var pageCount = 1
    @State private var loading = true
    @State private var loadingMore = false
    @State private var errorText: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    private var jarURL: String { jar.isEmpty ? (JarProxyClient.activeJarURL() ?? "") : jar }

    var body: some View {
        Group {
            if let errorText {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(errorText)
                            .font(.footnote.monospaced())
                            .foregroundStyle(Theme.textDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            Task { await prepare() }
                        } label: {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 18).padding(.vertical, 9)
                                .background(Theme.card, in: Capsule())
                                .foregroundStyle(Theme.text)
                        }
                    }
                    .padding(18)
                }
            } else if loading {
                ProgressView().tint(Theme.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    if !classes.isEmpty { classChips }
                    grid
                }
            }
        }
        .background(AmbientBackground(imageURL: items.first?.pic))
        .task { await prepare() }
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

    private var grid: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(items) { item in
                    NavigationLink {
                        JarDetailLoaderView(site: site, item: item, parses: parses, jar: jarURL)
                    } label: {
                        PosterCell(item: item)
                    }
                    .buttonStyle(.plain)
                }
                if page < pageCount {
                    Color.clear
                        .frame(height: 1)
                        .onAppear { Task { await loadMore() } }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 110)
            if loadingMore {
                ProgressView().tint(Theme.text).padding(.bottom, 120)
            }
        }
    }

    private func prepare() async {
        loading = true
        errorText = nil
        guard !jarURL.isEmpty else {
            errorText = "这条线路没有带 jar 包地址（配置里的 spider 字段），代理无从加载。"
            loading = false
            return
        }
        do {
            let home = try await JarProxyClient.run(jar: jarURL, site: site, action: "homeContent",
                                                    extra: ["filter": false])
            classes = PySiteBrowseView.mapClasses(home["class"])
            items = PySiteBrowseView.mapItems(home["list"])
            if items.isEmpty {
                if let video = try? await JarProxyClient.run(jar: jarURL, site: site, action: "homeVideoContent") {
                    items = PySiteBrowseView.mapItems(video["list"])
                }
            }
            page = 1
            pageCount = 1
        } catch {
            errorText = "Jar 站点加载失败\n\n\(error.localizedDescription)"
        }
        loading = false
    }

    private func selectClass(_ tid: String) async {
        selectedTid = tid
        page = 1
        loading = true
        do {
            if tid.isEmpty {
                let home = try await JarProxyClient.run(jar: jarURL, site: site, action: "homeContent",
                                                        extra: ["filter": false])
                items = PySiteBrowseView.mapItems(home["list"])
                pageCount = 1
            } else {
                let result = try await JarProxyClient.run(jar: jarURL, site: site, action: "categoryContent",
                                                          extra: ["tid": tid, "pg": "1", "filter": true, "extend": [String: String]()])
                items = PySiteBrowseView.mapItems(result["list"])
                pageCount = PySiteBrowseView.intValue(result["pagecount"]) ?? 1
            }
        } catch {
            errorText = "分类加载失败\n\n\(error.localizedDescription)"
        }
        loading = false
    }

    private func loadMore() async {
        guard page < pageCount, !loadingMore, !selectedTid.isEmpty else { return }
        loadingMore = true
        do {
            let result = try await JarProxyClient.run(jar: jarURL, site: site, action: "categoryContent",
                                                      extra: ["tid": selectedTid, "pg": String(page + 1), "filter": true, "extend": [String: String]()])
            page += 1
            items += PySiteBrowseView.mapItems(result["list"])
            pageCount = PySiteBrowseView.intValue(result["pagecount"]) ?? pageCount
        } catch {
            pageCount = page
        }
        loadingMore = false
    }
}

/// Detail for a jar site: detailContent through the proxy, then
/// DetailView with a playerContent resolver (same contract as py).
struct JarDetailLoaderView: View {
    let site: TVBoxConfig.Site
    let item: VodItem
    var parses: [TVBoxConfig.Parse] = []
    var jar: String = ""
    @State private var detail: VodDetail?
    @State private var errorText: String?

    private var jarURL: String { jar.isEmpty ? (JarProxyClient.activeJarURL() ?? "") : jar }

    var body: some View {
        Group {
            if let detail {
                DetailView(detail: detail, header: site.header ?? [:],
                           playerResolver: resolve,
                           historySeed: HistorySeed(
                               lineID: ConfigLibrary.activeID() ?? "",
                               siteKey: site.key, siteName: site.name, vodId: item.id))
            } else if let errorText {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(errorText)
                            .font(.footnote.monospaced())
                            .foregroundStyle(Theme.textDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            Task { await load() }
                        } label: {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 18).padding(.vertical, 9)
                                .background(Theme.card, in: Capsule())
                                .foregroundStyle(Theme.text)
                        }
                    }
                    .padding(18)
                }
            } else {
                ProgressView().tint(Theme.text)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmbientBackground(imageURL: item.pic))
        .task { await load() }
    }

    private func load() async {
        errorText = nil
        detail = nil
        do {
            guard !jarURL.isEmpty else {
                errorText = "这条线路没有带 jar 包地址，代理无从加载。"
                return
            }
            let result = try await JarProxyClient.run(jar: jarURL, site: site, action: "detailContent",
                                                      extra: ["ids": [item.id]])
            guard let first = (result["list"] as? [[String: Any]])?.first else {
                errorText = "详情为空"
                return
            }
            detail = CMSClient.mapDetail(first, fallbackID: item.id)
        } catch {
            errorText = "详情加载失败\n\n\(error.localizedDescription)"
        }
    }

    private func resolve(flag: String, episodeID: String) async -> ResolveOutcome {
        let vipFlags = ConfigLibrary.activeID().flatMap { ConfigLibrary.load(id: $0) }?.flags ?? []
        let result: [String: Any]
        do {
            result = try await JarProxyClient.run(jar: jarURL, site: site, action: "playerContent",
                                                  extra: ["flag": flag, "id": episodeID, "vipFlags": vipFlags])
        } catch {
            return .failed(reason: "Jar 代理调用失败：\(error.localizedDescription)")
        }
        let parse = PySiteBrowseView.intValue(result["parse"]) ?? 0
        let jx = PySiteBrowseView.intValue(result["jx"]) ?? 0
        let url = result["url"] as? String ?? ""
        guard !url.isEmpty else {
            return .failed(reason: ResolveOutcome.spiderReason(in: result) ?? "蜘蛛没有返回播放地址")
        }
        var header = site.header ?? [:]
        if let extra = result["header"] as? [String: Any] {
            for (key, value) in extra { header[key] = String(describing: value) }
        }
        if parse == 0 && jx == 0 { return .ok(url: url, header: header) }
        guard let resolved = await ParseResolver.resolve(flag: flag, url: url, parses: parses)
        else { return .failed(reason: "解析接口没能解析出播放地址") }
        for (key, value) in resolved.header { header[key] = value }
        return .ok(url: resolved.url, header: header)
    }
}
