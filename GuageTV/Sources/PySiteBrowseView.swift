import CryptoKit
import SwiftUI

/// Browsing for Python spider sites (stage 1). Same shape as the CMS
/// browser — class chips + poster grid + paging — but every list comes
/// from the embedded Python runtime: the site's .py file is downloaded
/// into Application Support/spiders, loaded through SpiderBridge, and
/// home/category calls drive the grid. Python exceptions surface as
/// the page's error text, verbatim (traceback tail included), so a
/// broken spider can be diagnosed from a screenshot.
struct PySiteBrowseView: View {
    let site: TVBoxConfig.Site
    var parses: [TVBoxConfig.Parse] = []

    @State private var classes: [(String, String)] = []
    @State private var items: [VodItem] = []
    @State private var selectedTid = ""
    @State private var page = 1
    @State private var pageCount = 1
    @State private var loading = true
    @State private var loadingMore = false
    @State private var errorText: String?

    private let bridge = SpiderBridge.shared
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        Group {
            if let errorText {
                ScrollView {
                    Text(errorText)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                        PyDetailLoaderView(site: site, item: item, parses: parses)
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

    // MARK: runtime plumbing

    private func prepare() async {
        loading = true
        errorText = nil
        do {
            let path = try await downloadSpider()
            _ = try await bridge.loadSpider(path: path, extend: site.extJSONString)
            let home = try await bridge.homeContent()
            classes = Self.mapClasses(home["class"])
            items = Self.mapItems(home["list"])
            if items.isEmpty, let video = try? await bridge.homeVideoContent() {
                items = Self.mapItems(video["list"])
            }
            page = 1
            pageCount = 1
        } catch {
            errorText = "py 站点加载失败\n\n\(error.localizedDescription)"
        }
        loading = false
    }

    private func selectClass(_ tid: String) async {
        selectedTid = tid
        page = 1
        loading = true
        do {
            if tid.isEmpty {
                let home = try await bridge.homeContent()
                items = Self.mapItems(home["list"])
                pageCount = 1
            } else {
                let result = try await bridge.categoryContent(tid: tid, pg: 1)
                items = Self.mapItems(result["list"])
                pageCount = Self.intValue(result["pagecount"]) ?? 1
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
            let result = try await bridge.categoryContent(tid: selectedTid, pg: page + 1)
            page += 1
            items += Self.mapItems(result["list"])
            pageCount = Self.intValue(result["pagecount"]) ?? pageCount
        } catch {
            pageCount = page
        }
        loadingMore = false
    }

    /// Resolve the site's .py address (relative entries like ./py/x.py
    /// resolve against the config's own URL) and cache the file in
    /// Application Support/spiders for the interpreter to load.
    private func downloadSpider() async throws -> String {
        try await Self.downloadSpider(for: site)
    }

    /// Download (or locate, for imported files) a site's .py and
    /// return its local path. Shared with search and standalone
    /// detail loads, which run outside this browse view.
    static func downloadSpider(for site: TVBoxConfig.Site) async throws -> String {
        // Locally imported .py files already live in the spiders dir.
        if site.api.hasPrefix("local-spider://") {
            let name = String(site.api.dropFirst("local-spider://".count))
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("spiders")
            return dir.appendingPathComponent(name).path
        }
        let url: URL?
        if let direct = URL(string: site.api), direct.scheme?.hasPrefix("http") == true {
            url = direct
        } else if let baseText = UserDefaults.standard.string(forKey: "configSourceURL"),
                  let base = URL(string: baseText) {
            url = URL(string: site.api, relativeTo: base)?.absoluteURL
        } else {
            url = nil
        }
        guard let url else {
            throw SpiderBridge.BridgeFailure(message: "无法解析 py 文件地址：\(site.api)")
        }
        return try await cachedSpiderFile(for: url)
    }

    /// Remote spider code is cached by URL: spiders/<sha1(url)>.py
    /// plus a <sha1(url)>.meta sidecar stamping fetchedAt. Inside a
    /// 12 h TTL the cached file is used as-is (entering a py site no
    /// longer re-downloads its code every time); past the TTL the
    /// file is re-downloaded, and if that download fails the stale
    /// copy is still better than an error page. Locally imported
    /// files never reach here — they take the local-spider:// branch
    /// above and load in place.
    private static func cachedSpiderFile(for url: URL) async throws -> String {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("spiders")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let digest = Insecure.SHA1.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let file = dir.appendingPathComponent(hex + ".py")
        let meta = dir.appendingPathComponent(hex + ".meta")
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path),
           let fetchedAt = readFetchedAt(meta),
           Date().timeIntervalSince(fetchedAt) < 12 * 3600 {
            return file.path
        }
        do {
            let data = try await NetFetch.data(from: url)
            try data.write(to: file, options: .atomic)
            let stamp: [String: Any] = ["fetchedAt": Date().timeIntervalSince1970]
            if let metaData = try? JSONSerialization.data(withJSONObject: stamp) {
                try? metaData.write(to: meta, options: .atomic)
            }
            return file.path
        } catch {
            if fm.fileExists(atPath: file.path) { return file.path }
            throw error
        }
    }

    private static func readFetchedAt(_ meta: URL) -> Date? {
        guard let data = try? Data(contentsOf: meta),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = dict["fetchedAt"] as? Double else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    // MARK: result mapping (same shapes as CMSClient.mapList)

    static func mapClasses(_ raw: Any?) -> [(String, String)] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let name = row["type_name"] as? String else { return nil }
            return (String(describing: row["type_id"] ?? ""), name)
        }
    }

    static func mapItems(_ raw: Any?) -> [VodItem] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.map { row in
            VodItem(
                id: String(describing: row["vod_id"] ?? ""),
                name: row["vod_name"] as? String ?? "",
                pic: row["vod_pic"] as? String ?? "",
                remarks: row["vod_remarks"] as? String ?? "",
                year: row["vod_year"] as? String ?? "",
                score: String(describing: row["vod_score"] ?? ""))
        }
    }

    /// Spider play headers arrive either as a JSON object or as a
    /// JSON *string* (catvod's JSONObject.toString form — Wogg/Quark
    /// returns {"Cookie":…,"Referer":…,"User-Agent":…} as a string).
    /// Dropping the string form loses the drive Cookie + Referer and
    /// the CDN answers 412, so accept both shapes.
    static func headerDict(from raw: Any?) -> [String: String] {
        if let dict = raw as? [String: Any] {
            var out: [String: String] = [:]
            for (key, value) in dict { out[key] = String(describing: value) }
            return out
        }
        if let string = raw as? String, let data = string.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var out: [String: String] = [:]
            for (key, value) in dict { out[key] = String(describing: value) }
            return out
        }
        return [:]
    }

    static func intValue(_ raw: Any?) -> Int? {
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String { return Int(text) }
        return nil
    }
}

/// Detail for a py site: detailContent → shared VodDetail mapping →
/// DetailView with a playerContent resolver (episode ids are not URLs
/// for spiders; playerContent turns them into playable URLs).
struct PyDetailLoaderView: View {
    let site: TVBoxConfig.Site
    let item: VodItem
    var parses: [TVBoxConfig.Parse] = []
    @State private var detail: VodDetail?
    @State private var errorText: String?

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
                    Text(errorText)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                }
            } else {
                ProgressView().tint(Theme.text)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmbientBackground(imageURL: item.pic))
        .task {
            do {
                // The bridge holds ONE spider at a time; make sure it
                // is this site's before asking for detail (search and
                // history open this loader without browsing first).
                let path = try await PySiteBrowseView.downloadSpider(for: site)
                _ = try await SpiderBridge.shared.loadSpider(path: path, extend: site.extJSONString)
                let result = try await SpiderBridge.shared.detailContent(ids: [item.id])
                guard let first = (result["list"] as? [[String: Any]])?.first else {
                    errorText = "详情为空"
                    return
                }
                detail = CMSClient.mapDetail(first, fallbackID: item.id)
            } catch {
                errorText = "详情加载失败\n\n\(error.localizedDescription)"
            }
        }
    }

    /// playerContent(flag, id) → playable URL. parse=0 answers go
    /// straight to the player; parse=1 hands the page URL to the
    /// line's parse interfaces.
    private func resolve(flag: String, episodeID: String) async -> ResolveOutcome {
        let result: [String: Any]
        do {
            result = try await SpiderBridge.shared.playerContent(flag: flag, id: episodeID)
        } catch {
            return .failed(reason: "py 蜘蛛调用失败：\(error.localizedDescription)")
        }
        let parse = PySiteBrowseView.intValue(result["parse"]) ?? 0
        let url = result["url"] as? String ?? ""
        guard !url.isEmpty else {
            return .failed(reason: ResolveOutcome.spiderReason(in: result) ?? "蜘蛛没有返回播放地址")
        }
        var header = site.header ?? [:]
        for (key, value) in PySiteBrowseView.headerDict(from: result["header"]) { header[key] = value }
        if parse == 0 { return .ok(url: url, header: header) }
        guard let resolved = await ParseResolver.resolve(flag: flag, url: url, parses: parses)
        else { return .failed(reason: "解析接口没能解析出播放地址") }
        for (key, value) in resolved.header { header[key] = value }
        return .ok(url: resolved.url, header: header)
    }
}
