import SwiftUI

/// Browsing for drpy/JS sites (stage 2). Mirrors PySiteBrowseView —
/// class chips + poster grid + paging — with every list produced by
/// the JavaScriptCore drpy2 runtime. The bundled engine loads the
/// site's rule (the config's ext, or its api when ext is empty);
/// JS errors surface verbatim so a broken rule can be diagnosed
/// from a screenshot.
struct JSSiteBrowseView: View {
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
    @State private var ruleRef = ""

    private let bridge = JSBridge.shared
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
                        JSDetailLoaderView(site: site, item: item, ruleRef: ruleRef, parses: parses)
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
            ruleRef = try Self.resolveRuleRef(site)
            try await bridge.loadRule(reference: ruleRef)
            let home = try await bridge.home()
            classes = PySiteBrowseView.mapClasses(home["class"])
            items = PySiteBrowseView.mapItems(home["list"])
            if items.isEmpty, let video = try? await bridge.homeVod() {
                items = PySiteBrowseView.mapItems(video["list"])
            }
            page = 1
            pageCount = 1
        } catch {
            errorText = "JS 站点加载失败\n\n\(error.localizedDescription)"
        }
        loading = false
    }

    private func selectClass(_ tid: String) async {
        selectedTid = tid
        page = 1
        loading = true
        do {
            if tid.isEmpty {
                let home = try await bridge.home()
                items = PySiteBrowseView.mapItems(home["list"])
                if items.isEmpty, let video = try? await bridge.homeVod() {
                    items = PySiteBrowseView.mapItems(video["list"])
                }
                pageCount = 1
            } else {
                let result = try await bridge.category(tid: tid, pg: 1)
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
            let result = try await bridge.category(tid: selectedTid, pg: page + 1)
            page += 1
            items += PySiteBrowseView.mapItems(result["list"])
            pageCount = PySiteBrowseView.intValue(result["pagecount"]) ?? pageCount
        } catch {
            pageCount = page
        }
        loadingMore = false
    }

    /// The rule reference handed to the engine's init: the site's ext
    /// (a rule path for drpy sites) or its api when ext is empty,
    /// resolved against the active config's URL. Locally imported
    /// rules arrive as local-rule://<filename> in Application
    /// Support/jsrules and load through a file:// URL.
    static func resolveRuleRef(_ site: TVBoxConfig.Site) throws -> String {
        let raw = site.ext?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? site.api
        if raw.hasPrefix("local-rule://") {
            let name = String(raw.dropFirst("local-rule://".count))
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("jsrules")
            return "file://" + dir.appendingPathComponent(name).path
        }
        if let direct = URL(string: raw), direct.scheme?.hasPrefix("http") == true {
            return raw
        }
        if let baseText = UserDefaults.standard.string(forKey: "configSourceURL"),
           let base = URL(string: baseText),
           let absolute = URL(string: raw, relativeTo: base)?.absoluteURL {
            return absolute.absoluteString
        }
        throw JSBridge.BridgeFailure(message: "无法解析 JS 规则地址：\(raw)")
    }
}

/// Detail for a JS site: reloads the rule (the runtime holds one
/// active rule), then detail() → shared VodDetail mapping →
/// DetailView with a play() resolver.
struct JSDetailLoaderView: View {
    let site: TVBoxConfig.Site
    let item: VodItem
    let ruleRef: String
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
                try await JSBridge.shared.loadRule(reference: ruleRef)
                let result = try await JSBridge.shared.detail(id: item.id)
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

    /// play(flag, id) → playable URL. drpy may return url as a
    /// single string or an array of candidates; parse=1 hands the
    /// page URL to the line's parse interfaces.
    private func resolve(flag: String, episodeID: String) async -> (url: String, header: [String: String])? {
        guard let result = try? await JSBridge.shared.play(flag: flag, id: episodeID)
        else { return nil }
        let parse = PySiteBrowseView.intValue(result["parse"]) ?? 0
        let url: String
        if let single = result["url"] as? String {
            url = single
        } else if let candidates = result["url"] as? [Any] {
            url = candidates.compactMap { $0 as? String }.first ?? ""
        } else {
            url = ""
        }
        guard !url.isEmpty else { return nil }
        var header = site.header ?? [:]
        if let extra = result["header"] as? [String: Any] {
            for (key, value) in extra { header[key] = String(describing: value) }
        }
        if parse == 0 { return (url, header) }
        guard let resolved = await ParseResolver.resolve(flag: flag, url: url, parses: parses)
        else { return nil }
        for (key, value) in resolved.header { header[key] = value }
        return (resolved.url, header)
    }
}
