import SwiftUI

/// 记录 (History) — replaces the old Profile tab. Every playback filed
/// by DetailView lands here (newest first); tapping a row resumes the
/// episode directly at the saved position, and the detail button
/// re-opens the show's page on its original line.
struct HistoryView: View {
    @StateObject private var history = HistoryStore.shared
    @StateObject private var downloads = DownloadManager.shared
    /// ONE item-cover only: stacking two .fullScreenCover(item:) on
    /// the same view crashed the tab on open (v1.13 regression).
    private enum PlayRoute: Identifiable {
        case history(HistoryStore.Entry)
        case download(DownloadManager.Item)
        var id: String {
            switch self {
            case .history(let e): return "h|" + e.id
            case .download(let i): return "d|" + i.id
            }
        }
    }
    @State private var playRoute: PlayRoute?
    @State private var confirmClear = false
    @State private var checkingUpdates = false

    @State private var segment = 0

    /// History shows only entries that were actually played (they
    /// carry an episode URL); favourites include detail-page stubs
    /// filed before the first play.
    private var shownEntries: [HistoryStore.Entry] {
        segment == 0
            ? history.entries.filter { !$0.episodeURL.isEmpty }
            : history.favourites
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("分段", selection: $segment) {
                    Text("历史").tag(0)
                    Text("收藏").tag(1)
                    Text("下载").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                if segment == 2 {
                    downloadsView
                } else if shownEntries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: segment == 0 ? "clock.arrow.circlepath" : "heart")
                            .font(.largeTitle).foregroundStyle(Theme.textDim)
                        Text(segment == 0 ? "还没有浏览记录" : "还没有收藏")
                            .font(.headline).foregroundStyle(Theme.text)
                        Text(segment == 0 ? "看过的剧会出现在这里，下次点开直接续播" : "在详情页点爱心，喜欢的剧会收进这里")
                            .font(.subheadline).foregroundStyle(Theme.textDim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(shownEntries) { entry in
                            row(entry)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18))
                        }
                        .onDelete { offsets in
                            let picked = offsets.map { shownEntries[$0] }
                            if segment == 0 {
                                picked.forEach { history.remove(id: $0.id) }
                            } else {
                                picked.forEach { entry in
                                    if entry.episodeURL.isEmpty {
                                        history.remove(id: entry.id)
                                    } else {
                                        history.setFavourite(stub: entry, on: false)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(AmbientBackground(imageURL: shownEntries.first?.pic))
            .navigationTitle("记录")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if segment == 1 && !history.favourites.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(checkingUpdates ? "检测中…" : "检测更新") {
                            checkingUpdates = true
                            Task {
                                await HistoryStore.shared.checkFavouritesForUpdates()
                                checkingUpdates = false
                            }
                        }
                        .disabled(checkingUpdates)
                        .foregroundStyle(Theme.text)
                    }
                }
                if segment == 0 && !history.entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("清空") { confirmClear = true }
                            .foregroundStyle(.red.opacity(0.9))
                    }
                }
            }
            .confirmationDialog("清空全部浏览记录？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) { history.clearAll() }
                Button("取消", role: .cancel) {}
            }
            .onChange(of: segment) { newValue in
                if newValue == 1 && !history.favourites.isEmpty && !checkingUpdates {
                    checkingUpdates = true
                    Task {
                        await HistoryStore.shared.checkFavouritesForUpdates()
                        checkingUpdates = false
                    }
                }
            }
            .fullScreenCover(item: $playRoute) { route in
                switch route {
                case .history(let entry):
                    PlayerView(
                        episodes: [PlayerView.EpisodeRef(name: entry.episodeName, url: entry.episodeURL)],
                        startIndex: 0, header: entry.playHeader, title: entry.name,
                        historyID: entry.id, resumeAt: entry.positionSeconds)
                case .download(let item):
                    if let local = DownloadManager.shared.localURLString(item) {
                        PlayerView(episodes: [PlayerView.EpisodeRef(name: item.episodeName, url: local)],
                                   startIndex: 0, header: [:], title: item.vodName, pic: item.pic)
                    }
                }
            }
        }
    }

    private func row(_ entry: HistoryStore.Entry) -> some View {
        HStack(spacing: 12) {
            PosterImage(urlString: entry.pic)
                .frame(width: 46, height: 69)
                .posterFrame()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text).lineLimit(1)
                    if entry.hasUpdate {
                        Text("有更新").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule())
                    }
                }
                Text(subtitle(entry)).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                if entry.durationSeconds > 0 {
                    ProgressView(value: min(entry.positionSeconds / entry.durationSeconds, 1))
                        .tint(Theme.accent)
                    Text(progressText(entry)).font(.caption2).foregroundStyle(Theme.textDim)
                }
            }
            Spacer()
            Image(systemName: "play.circle.fill")
                .font(.title2).foregroundStyle(Theme.text.opacity(0.9))
            NavigationLink {
                HistoryDetailDestination(entry: entry)
            } label: {
                Text("详情").font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.glass, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
        .onTapGesture {
            if !entry.episodeURL.isEmpty { playRoute = .history(entry) }
        }
    }

    // MARK: downloads segment

    @ViewBuilder
    private var downloadsView: some View {
        if downloads.items.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .font(.largeTitle).foregroundStyle(Theme.textDim)
                Text("还没有下载")
                    .font(.headline).foregroundStyle(Theme.text)
                Text("在详情页长按集数、或播放器里点下载钮，剧会存到这里离线看")
                    .font(.subheadline).foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(downloads.items) { item in
                    downloadRow(item)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18))
                }
                .onDelete { offsets in
                    offsets.map { downloads.items[$0] }.forEach { DownloadManager.shared.remove($0) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func downloadRow(_ item: DownloadManager.Item) -> some View {
        HStack(spacing: 12) {
            PosterImage(urlString: item.pic)
                .frame(width: 46, height: 69)
                .posterFrame()
            VStack(alignment: .leading, spacing: 4) {
                Text(item.vodName).font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text).lineLimit(1)
                Text(item.episodeName).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                switch item.state {
                case "downloading":
                    ProgressView(value: item.progress).tint(Theme.accent)
                    Text("下载中 \(Int(item.progress * 100))%").font(.caption2).foregroundStyle(Theme.textDim)
                case "done":
                    Text("已下载 · \(sizeText(item.totalBytes))").font(.caption2).foregroundStyle(Theme.ok)
                default:
                    Text("下载失败，左滑删除后重试").font(.caption2).foregroundStyle(.red.opacity(0.85))
                }
            }
            Spacer()
            if item.state == "done" {
                Image(systemName: "play.circle.fill")
                    .font(.title2).foregroundStyle(Theme.text.opacity(0.9))
            }
        }
        .padding(10)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
        .onTapGesture {
            if item.state == "done" { playRoute = .download(item) }
        }
    }

    private func sizeText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "大小未知" }
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    private func subtitle(_ entry: HistoryStore.Entry) -> String {
        let parts = [entry.siteName, entry.episodeName].filter { !$0.isEmpty }
        return parts.isEmpty ? "上次观看" : parts.joined(separator: " · ")
    }

    private func progressText(_ entry: HistoryStore.Entry) -> String {
        "看到 \(timeText(entry.positionSeconds)) / \(timeText(entry.durationSeconds))"
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Re-opens a history entry's detail page on its original line,
/// routing to the loader matching the site's runtime.
private struct HistoryDetailDestination: View {
    let entry: HistoryStore.Entry

    var body: some View {
        Group {
            if let resolved {
                let item = VodItem(id: entry.vodId, name: entry.name, pic: entry.pic,
                                   remarks: "", year: "", score: "")
                switch resolved.site.kind {
                case .cmsJSON, .cmsXML:
                    DetailLoaderView(site: resolved.site, item: item, lineID: entry.lineID, parses: resolved.parses)
                case .spiderPY:
                    PyDetailLoaderView(site: resolved.site, item: item, parses: resolved.parses)
                case .spiderJS, .drpyJS:
                    JSDetailLoaderView(site: resolved.site, item: item,
                                       ruleRef: (try? JSSiteBrowseView.resolveRuleRef(resolved.site)) ?? "",
                                       parses: resolved.parses)
                default:
                    message("该站点类型暂不支持直接打开")
                }
            } else {
                message("原线路已删除或站点不存在")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmbientBackground(imageURL: entry.pic))
    }

    private var resolved: (site: TVBoxConfig.Site, parses: [TVBoxConfig.Parse])? {
        let lineID = entry.lineID.isEmpty ? (ConfigLibrary.activeID() ?? "") : entry.lineID
        guard let config = ConfigLibrary.load(id: lineID),
              let site = config.sites.first(where: { $0.key == entry.siteKey })
        else { return nil }
        return (site, config.parses ?? [])
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(Theme.textDim)
    }
}
