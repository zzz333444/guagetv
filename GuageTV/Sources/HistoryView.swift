import SwiftUI

/// 记录 (History) — replaces the old Profile tab. Every playback filed
/// by DetailView lands here (newest first); tapping a row resumes the
/// episode directly at the saved position, and the detail button
/// re-opens the show's page on its original line.
struct HistoryView: View {
    @StateObject private var history = HistoryStore.shared
    @StateObject private var downloads = DownloadManager.shared
    /// v2.15 startup: this view is mounted at launch (hidden tab),
    /// so the storage-size walk in refreshStorage() used to run
    /// before the first frame. It now waits until the tab is
    /// actually opened (ContentView passes isActive).
    var isActive: Bool = false
    @State private var storageWalkStarted = false
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

    /// Downloads storage accounting (R7): refreshed when the
    /// downloads segment appears and when the item list changes.
    @State private var downloadedBytes: Int64 = 0
    @State private var posterBytes: Int64 = 0
    @State private var storageLoaded = false
    @State private var clearingCache = false

    /// R8 (v1.95): multi-episode shows fold into one group row.
    /// Groups start folded; the set holds the keys currently open.
    @State private var expandedDownloadGroups: Set<String> = []

    /// v2.10: downloads batch management — multi-select + batch
    /// delete / batch retry. Selection holds item ids; stale ids
    /// (swipe-deleted rows) are harmless.
    @State private var isSelectingDownloads = false
    @State private var selectedDownloadIDs: Set<String> = []

    /// v2.11: history batch cleanup — multi-select delete +
    /// one-tap clear of finished (≥95% watched) entries.
    @State private var isSelectingHistory = false
    @State private var selectedHistoryIDs: Set<String> = []
    @State private var confirmFinishedClear = false
    @State private var confirmHistoryBatchDelete = false

    /// Finished, not favourited — the same set "清已看完" removes.
    private var finishedCount: Int {
        history.entries.filter { HistoryStore.isFinished($0) && !$0.isFavourite }.count
    }

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
                    // R8 (v1.85): hand-rolled empty VStack → shared
                    // EmptyStateView, same copy, one glass language.
                    VStack {
                        Spacer()
                        EmptyStateView(
                            icon: segment == 0 ? "clock.arrow.circlepath" : "heart",
                            title: segment == 0 ? "还没有浏览记录" : "还没有收藏",
                            message: segment == 0 ? "看过的剧会出现在这里，下次点开直接续播" : "在详情页点爱心，喜欢的剧会收进这里")
                            .padding(.horizontal, 18)
                        Spacer()
                    }
                } else {
                    List {
                        if segment == 1 {
                            NavigationLink {
                                WatchlistView()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "calendar.badge.clock")
                                        .foregroundStyle(Theme.accent)
                                    Text("追剧总览")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.text)
                                    Spacer()
                                    let count = history.favourites.filter(\.hasUpdate).count
                                    if count > 0 {
                                        // v2.11: 更新红点与计数并列。
                                        Circle().fill(Color.red).frame(width: 8, height: 8)
                                        Text("\(count) 部有更新")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Theme.accent)
                                    }
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Theme.textDim)
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18))
                        }
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
                // v2.11: 历史批量清理条（仅管理模式）：全选 / 清已看完 / 批量删除。
                if isSelectingHistory && segment == 0 && !shownEntries.isEmpty {
                    historyBatchBar
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
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
                                // v2.23: 手动检测绕过 6 小时节流。
                                await HistoryStore.shared.checkFavouritesForUpdates(force: true)
                                checkingUpdates = false
                            }
                        }
                        .disabled(checkingUpdates)
                        .foregroundStyle(Theme.text)
                    }
                }
                // v2.11: 历史页批量管理入口；管理模式下「清空」让给「完成」。
                if segment == 0 && !history.entries.isEmpty {
                    if isSelectingHistory {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") {
                                Haptics.tap()
                                selectedHistoryIDs.removeAll()
                                isSelectingHistory = false
                            }
                            .foregroundStyle(Theme.text)
                        }
                    } else {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("管理") {
                                Haptics.tap()
                                isSelectingHistory = true
                            }
                            .foregroundStyle(Theme.text)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("清空") { confirmClear = true }
                                .foregroundStyle(.red.opacity(0.9))
                        }
                    }
                }
                // v2.10: 下载页批量管理入口。
                if segment == 2 && !downloads.items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(isSelectingDownloads ? "完成" : "管理") {
                            Haptics.tap()
                            if isSelectingDownloads { selectedDownloadIDs.removeAll() }
                            isSelectingDownloads.toggle()
                        }
                        .foregroundStyle(Theme.text)
                    }
                }
            }
            .confirmationDialog("清空全部浏览记录？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) { history.clearAll() }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("清理 \(finishedCount) 条已看完的记录？", isPresented: $confirmFinishedClear, titleVisibility: .visible) {
                Button("清理", role: .destructive) {
                    history.removeFinished()
                    if history.entries.isEmpty { isSelectingHistory = false }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只清理看到 95% 以上的记录，已收藏的剧不受影响。")
            }
            .confirmationDialog("删除选中的 \(selectedHistoryIDs.count) 条记录？", isPresented: $confirmHistoryBatchDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    history.remove(ids: selectedHistoryIDs)
                    selectedHistoryIDs.removeAll()
                    if history.entries.isEmpty { isSelectingHistory = false }
                }
                Button("取消", role: .cancel) {}
            }
            .onChange(of: segment) { newValue in
                // 离开历史分段即退出管理模式，选中态不带到别的分段。
                if newValue != 0 {
                    isSelectingHistory = false
                    selectedHistoryIDs.removeAll()
                }
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
            // v2.11: 管理模式下行首勾选圈，点按只改选中态。
            if isSelectingHistory && segment == 0 {
                Image(systemName: selectedHistoryIDs.contains(entry.id)
                      ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectedHistoryIDs.contains(entry.id)
                                     ? Theme.accent : Theme.textDim)
            }
            PosterImage(urlString: entry.pic, pixelSize: 240)
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
            if isSelectingHistory && segment == 0 {
                Haptics.tap()
                if selectedHistoryIDs.contains(entry.id) { selectedHistoryIDs.remove(entry.id) }
                else { selectedHistoryIDs.insert(entry.id) }
                return
            }
            if !entry.episodeURL.isEmpty { Haptics.medium(); playRoute = .history(entry) }
        }
    }

    /// v2.11: 历史批量操作条（仅管理模式）：全选 / 清已看完 / 批量删除。
    private var historyBatchBar: some View {
        HStack(spacing: 10) {
            Button(selectedHistoryIDs.count == shownEntries.count ? "取消全选" : "全选") {
                Haptics.tap()
                if selectedHistoryIDs.count == shownEntries.count {
                    selectedHistoryIDs.removeAll()
                } else {
                    selectedHistoryIDs = Set(shownEntries.map(\.id))
                }
            }
            Spacer()
            Button("清已看完\(finishedCount == 0 ? "" : " (\(finishedCount))")") {
                Haptics.tap()
                confirmFinishedClear = true
            }
            .disabled(finishedCount == 0)
            Button("删除\(selectedHistoryIDs.isEmpty ? "" : " (\(selectedHistoryIDs.count))")") {
                Haptics.tap()
                confirmHistoryBatchDelete = true
            }
            .disabled(selectedHistoryIDs.isEmpty)
            .foregroundStyle(.red.opacity(0.9))
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: downloads segment

    @ViewBuilder
    private var downloadsView: some View {
        VStack(spacing: 0) {
            storageCard
                .padding(.horizontal, 18)
                .padding(.top, 10)
            if downloads.items.isEmpty {
                // R8 (v1.85): same shared empty state as above.
                VStack {
                    Spacer()
                    EmptyStateView(
                        icon: "arrow.down.circle",
                        title: "还没有下载",
                        message: "在详情页长按集数、或播放器里点下载钮，剧会存到这里离线看")
                        .padding(.horizontal, 18)
                    Spacer()
                }
            } else {
                List {
                    ForEach(downloadGroups, id: \.key) { group in
                        if group.items.count == 1 {
                            ForEach(group.items) { item in
                                downloadRow(item)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18))
                            }
                            .onDelete { offsets in
                                offsets.map { group.items[$0] }.forEach { DownloadManager.shared.remove($0) }
                            }
                        } else {
                            downloadGroupHeader(group)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18))
                            if expandedDownloadGroups.contains(group.key) {
                                ForEach(group.items) { item in
                                    downloadRow(item)
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets(top: 2, leading: 18, bottom: 2, trailing: 18))
                                }
                                .onDelete { offsets in
                                    offsets.map { group.items[$0] }.forEach { DownloadManager.shared.remove($0) }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            // v2.10: 批量操作条（仅管理模式）：全选 / 批量重试 / 批量删除。
            if isSelectingDownloads && !downloads.items.isEmpty {
                batchBar
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
        }
    }

    private var batchBar: some View {
        let retryable = selectedDownloadIDs.intersection(
            Set(downloads.items.filter { $0.state == "failed" || $0.state == "paused" }.map(\.id)))
        return HStack(spacing: 10) {
            Button(selectedDownloadIDs.count == downloads.items.count ? "取消全选" : "全选") {
                Haptics.tap()
                if selectedDownloadIDs.count == downloads.items.count {
                    selectedDownloadIDs.removeAll()
                } else {
                    selectedDownloadIDs = Set(downloads.items.map(\.id))
                }
            }
            Spacer()
            Button("批量重试\(retryable.isEmpty ? "" : " (\(retryable.count))")") {
                Haptics.tap()
                DownloadManager.shared.retry(ids: retryable)
                selectedDownloadIDs.subtract(retryable)
            }
            .disabled(retryable.isEmpty)
            Button("删除\(selectedDownloadIDs.isEmpty ? "" : " (\(selectedDownloadIDs.count))")") {
                Haptics.tap()
                DownloadManager.shared.remove(ids: selectedDownloadIDs)
                selectedDownloadIDs.removeAll()
                if downloads.items.isEmpty { isSelectingDownloads = false }
            }
            .disabled(selectedDownloadIDs.isEmpty)
            .foregroundStyle(.red.opacity(0.9))
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Storage usage card: downloaded videos on disk + poster
    /// cache, with one-tap poster-cache cleanup. Clearing never
    /// touches downloaded videos.
    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "internaldrive").foregroundStyle(Theme.textDim)
                Text("存储用量").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button(clearingCache ? "清理中…" : "清理缓存") {
                    Task { await clearPosterCache() }
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.glass, in: Capsule())
                .foregroundStyle(Theme.text)
                .disabled(clearingCache || !storageLoaded || posterBytes == 0)
            }
            HStack {
                Text("已下载").foregroundStyle(Theme.textDim)
                Spacer()
                Text(storageLoaded ? storageText(downloadedBytes) : "计算中…")
                    .foregroundStyle(Theme.text).monospacedDigit()
            }
            .font(.subheadline)
            HStack {
                Text("海报缓存").foregroundStyle(Theme.textDim)
                Spacer()
                Text(storageLoaded ? storageText(posterBytes) : "计算中…")
                    .foregroundStyle(Theme.text).monospacedDigit()
            }
            .font(.subheadline)
            Text("清理缓存只清海报图片与内存缓存，已下载的视频不受影响。")
                .font(.caption).foregroundStyle(Theme.textDim)
        }
        .padding(14)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 16))
        .onChange(of: isActive) { active in
            // v2.15: start the disk walk only on first open of the
            // tab, not at cold start when this view is mounted hidden.
            if active, !storageWalkStarted {
                storageWalkStarted = true
                Task { await refreshStorage() }
            }
        }
        .onChange(of: downloads.items.count) { _ in Task { await refreshStorage() } }
    }

    private func refreshStorage() async {
        async let dl = DownloadManager.shared.downloadedSize()
        async let posters = CacheManager.posterCacheSize()
        downloadedBytes = await dl
        posterBytes = await posters
        storageLoaded = true
    }

    private func clearPosterCache() async {
        clearingCache = true
        await CacheManager.clearPosterCache()
        await refreshStorage()
        clearingCache = false
    }

    private func storageText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 MB" }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1_024)
    }

    /// R8 (v1.95): downloads grouped by show name (vodName), in
    /// first-seen order; episodes inside a group sort by creation.
    private struct DownloadGroup {
        let key: String
        let items: [DownloadManager.Item]
    }

    private var downloadGroups: [DownloadGroup] {
        var order: [String] = []
        var buckets: [String: [DownloadManager.Item]] = [:]
        for item in downloads.items {
            let name = item.vodName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.isEmpty ? "未命名" : name
            if buckets[key] == nil { order.append(key); buckets[key] = [] }
            buckets[key]?.append(item)
        }
        return order.map { DownloadGroup(key: $0, items: (buckets[$0] ?? []).sorted { $0.createdAt < $1.createdAt }) }
    }

    /// Folded group header: poster + show name + episode counts,
    /// chevron flips the group open / closed. In batch mode the
    /// tap toggles the whole group's selection instead (v2.10).
    private func downloadGroupHeader(_ group: DownloadGroup) -> some View {
        let done = group.items.filter { $0.state == "done" }.count
        let busy = group.items.filter { $0.state == "downloading" }.count
        let expanded = expandedDownloadGroups.contains(group.key)
        var subtitle = "共 \(group.items.count) 集 · 已下载 \(done) 集"
        if busy > 0 { subtitle += " · 下载中 \(busy)" }
        let groupIDs = Set(group.items.map(\.id))
        let groupSelected = !groupIDs.isEmpty && groupIDs.isSubset(of: selectedDownloadIDs)
        return Button {
            if isSelectingDownloads {
                Haptics.tap()
                if groupSelected { selectedDownloadIDs.subtract(groupIDs) }
                else { selectedDownloadIDs.formUnion(groupIDs) }
                return
            }
            Haptics.tap()
            if expanded { expandedDownloadGroups.remove(group.key) }
            else { expandedDownloadGroups.insert(group.key) }
        } label: {
            HStack(spacing: 12) {
                PosterImage(urlString: group.items.first?.pic ?? "", pixelSize: 240)
                    .frame(width: 46, height: 69)
                    .posterFrame()
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.key).font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                }
                Spacer()
                if isSelectingDownloads {
                    Image(systemName: groupSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(groupSelected ? Theme.accent : Theme.textDim)
                } else {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.textDim)
                }
            }
            .padding(10)
            .background(Theme.glass, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func downloadRow(_ item: DownloadManager.Item) -> some View {
        HStack(spacing: 12) {
            // v2.10: 管理模式下行首勾选圈，点按只改选中态。
            if isSelectingDownloads {
                Image(systemName: selectedDownloadIDs.contains(item.id)
                      ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectedDownloadIDs.contains(item.id)
                                     ? Theme.accent : Theme.textDim)
            }
            PosterImage(urlString: item.pic, pixelSize: 240)
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
                case "paused":
                    Text("已暂停在 \(Int(item.progress * 100))%，点按断点续传").font(.caption2).foregroundStyle(Theme.textDim)
                default:
                    Text("下载失败，点按重试").font(.caption2).foregroundStyle(.red.opacity(0.85))
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
            if isSelectingDownloads {
                Haptics.tap()
                if selectedDownloadIDs.contains(item.id) { selectedDownloadIDs.remove(item.id) }
                else { selectedDownloadIDs.insert(item.id) }
                return
            }
            if item.state == "done" {
                Haptics.medium()
                playRoute = .download(item)
            } else if item.state == "failed" || item.state == "paused" {
                Haptics.tap()
                DownloadManager.shared.retry(item)
            }
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
