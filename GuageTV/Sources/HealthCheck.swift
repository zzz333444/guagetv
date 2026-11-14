import Foundation
import SwiftUI

/// 配置体检 (v1.41): walk every library entry and actually call
/// a capped sample of its sites the same way browsing does —
/// CMS home, py load+home, JS load+home, jar home via JarProxy —
/// recording per-site success + latency. Dead sites stand out
/// instead of being discovered one tap at a time.
struct HealthCheckView: View {
    struct Row: Identifiable {
        var entryName: String
        var siteName: String
        var kind: String
        var ok: Bool?
        var ms: Int = 0
        var note: String = ""
        var id: String { entryName + "|" + siteName + "|" + kind }
    }

    @State private var rows: [Row] = []
    @State private var running = false
    @State private var progressText = ""
    @State private var runTask: Task<Void, Never>?

    var body: some View {
        SettingsPage(title: "配置体检") {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("一键测全部线路的站点连通（每类抽测几个，py/JS 是串行跑，会花一点时间）。红的就是打不开的死站。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                    HStack {
                        Button {
                            run()
                        } label: {
                            Text(running ? "体检中…" : "开始体检")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 18).padding(.vertical, 8)
                                .background(Color.white, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(running)
                        if running {
                            Button("停止") {
                                runTask?.cancel()
                                running = false
                            }
                            .font(.subheadline)
                            .foregroundStyle(Theme.textDim)
                        }
                        Spacer()
                        if !progressText.isEmpty {
                            Text(progressText).font(.footnote).foregroundStyle(Theme.textDim)
                        }
                    }
                    if !rows.isEmpty {
                        let okCount = rows.filter { $0.ok == true }.count
                        let failCount = rows.filter { $0.ok == false }.count
                        Text("已测 \(rows.count) 个：正常 \(okCount) · 失败 \(failCount)")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Theme.text)
                    }
                }
            }
            if !rows.isEmpty {
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(rows) { row in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(row.ok == nil ? Color.gray : (row.ok! ? Color.green : Color.red))
                                    .frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.siteName)
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                    Text("\(row.entryName) · \(row.kind)")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textDim)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if row.ok != nil {
                                    Text("\(row.ms) ms")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(Theme.textDim)
                                }
                            }
                            if row.ok == false, !row.note.isEmpty {
                                Text(row.note)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textDim)
                                    .lineLimit(2)
                                    .padding(.leading, 19)
                            }
                        }
                    }
                }
            }
        }
    }

    private func run() {
        guard !running else { return }
        rows = []
        running = true
        runTask = Task {
            let entries = ConfigLibrary.entries()
            for entry in entries {
                if Task.isCancelled { break }
                let name = ConfigLibrary.shownName(entry)
                progressText = "正在测：\(name)"
                guard let config = ConfigLibrary.load(id: entry.id) else {
                    append(Row(entryName: name, siteName: "(整条线路)", kind: "配置",
                               ok: false, note: "配置解析失败"))
                    continue
                }
                await checkSites(of: config, entryName: name)
            }
            progressText = ""
            running = false
        }
    }

    private func append(_ row: Row) {
        rows.append(row)
    }

    private func measure(_ body: () async throws -> Void) async -> (ok: Bool, ms: Int, note: String) {
        let start = Date()
        do {
            try await body()
            return (true, Int(Date().timeIntervalSince(start) * 1000), "")
        } catch {
            return (false, Int(Date().timeIntervalSince(start) * 1000),
                    String(error.localizedDescription.prefix(90)))
        }
    }

    private func checkSites(of config: TVBoxConfig, entryName: String) async {
        // CMS: fast HTTP, test up to 6.
        for site in config.sites.filter({ $0.kind == .cmsXML || $0.kind == .cmsJSON }).prefix(6) {
            if Task.isCancelled { return }
            let result = await measure { _ = try await CMSClient(site: site).home() }
            append(Row(entryName: entryName, siteName: site.name,
                       kind: "CMS", ok: result.ok, ms: result.ms, note: result.note))
        }
        // py: serial interpreter — up to 3.
        for site in config.sites.filter({ $0.kind == .spiderPY }).prefix(3) {
            if Task.isCancelled { return }
            let result = await measure {
                let path = try await PySiteBrowseView.downloadSpider(for: site)
                _ = try await SpiderBridge.shared.loadSpider(path: path, extend: site.extJSONString)
                _ = try await SpiderBridge.shared.homeContent()
            }
            append(Row(entryName: entryName, siteName: site.name,
                       kind: "py", ok: result.ok, ms: result.ms, note: result.note))
        }
        // JS/drpy: up to 3.
        for site in config.sites.filter({ $0.kind == .spiderJS || $0.kind == .drpyJS }).prefix(3) {
            if Task.isCancelled { return }
            let result = await measure {
                let ref = try JSSiteBrowseView.resolveRuleRef(site)
                try await JSBridge.shared.loadRule(reference: ref)
                _ = try await JSBridge.shared.home()
            }
            append(Row(entryName: entryName, siteName: site.name,
                       kind: "JS", ok: result.ok, ms: result.ms, note: result.note))
        }
        // jar via JarProxy: up to 4 (patient=false — a sleepy
        // instance shouldn't stretch the whole check).
        for site in config.sites.filter({ $0.kind == .spiderJAR }).prefix(4) {
            if Task.isCancelled { return }
            let jar = config.spider ?? ""
            let result = await measure {
                if jar.isEmpty {
                    throw NSError(domain: "Health", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "这条线路没配 jar 地址"])
                }
                _ = try await JarProxyClient.run(jar: jar, site: site,
                                                 action: "homeContent")
            }
            append(Row(entryName: entryName, siteName: site.name,
                       kind: "jar", ok: result.ok, ms: result.ms, note: result.note))
        }
    }
}
