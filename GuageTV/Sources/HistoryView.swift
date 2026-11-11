import SwiftUI

/// 记录 (History) — replaces the old Profile tab. Every playback filed
/// by DetailView lands here (newest first); tapping a row resumes the
/// episode directly at the saved position, and the detail button
/// re-opens the show's page on its original line.
struct HistoryView: View {
    @StateObject private var history = HistoryStore.shared
    @State private var playEntry: HistoryStore.Entry?
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Group {
                if history.entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.largeTitle).foregroundStyle(Theme.textDim)
                        Text("还没有浏览记录")
                            .font(.headline).foregroundStyle(Theme.text)
                        Text("看过的剧会出现在这里，下次点开直接续播")
                            .font(.subheadline).foregroundStyle(Theme.textDim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(history.entries) { entry in
                            row(entry)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18))
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { history.entries[$0].id }
                            ids.forEach { history.remove(id: $0) }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(AmbientBackground(imageURL: history.entries.first?.pic))
            .navigationTitle("浏览记录")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if !history.entries.isEmpty {
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
            .fullScreenCover(item: $playEntry) { entry in
                PlayerView(
                    episodes: [PlayerView.EpisodeRef(name: entry.episodeName, url: entry.episodeURL)],
                    startIndex: 0, header: entry.playHeader, title: entry.name,
                    historyID: entry.id, resumeAt: entry.positionSeconds)
            }
        }
    }

    private func row(_ entry: HistoryStore.Entry) -> some View {
        HStack(spacing: 12) {
            PosterImage(urlString: entry.pic)
                .frame(width: 46, height: 69)
                .posterFrame()
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name).font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text).lineLimit(1)
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
            if !entry.episodeURL.isEmpty { playEntry = entry }
        }
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
