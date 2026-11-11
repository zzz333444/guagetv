import SwiftUI

/// 详情 (Detail) — Rex-style: ambient backdrop header, meta block, synopsis,
/// play-line chips, episode grid. Tapping an episode hands its URL (plus the
/// site's required headers) to the player; parse-needed sites resolve through
/// the config's parses in a later wiring step.
struct DetailView: View {
    let detail: VodDetail
    var header: [String: String] = [:]
    /// When set (py spiders), episode taps resolve through this first:
    /// episode urls are opaque ids until playerContent answers. A nil
    /// result means the episode needs a parse interface (later stage).
    var playerResolver: ((String, String) async -> (url: String, header: [String: String])?)?
    /// Set by the loaders so playback lands in the history list with
    /// enough context to resume straight from there.
    var historySeed: HistorySeed?
    /// The active (or home) line's parse interfaces: CMS episodes
    /// whose URL is a page rather than a stream are resolved through
    /// them on tap.
    var parses: [TVBoxConfig.Parse] = []
    @State private var lineIndex = 0
    @State private var playSelection: PlaySelection?
    @State private var resolving = false
    @State private var playNote: String?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                headerBlock
                if detail.playFrom.count > 1 { lineChips }
                episodeGrid
                if !detail.content.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("简介").font(.headline).foregroundStyle(.white)
                        Text(detail.content)
                            .font(.subheadline).foregroundStyle(.white.opacity(0.75))
                            .lineSpacing(4)
                    }
                    .padding(.horizontal, 18)
                }
            }
            .padding(.bottom, 40)
        }
        .background(AmbientBackground(imageURL: detail.pic))
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $playSelection) { sel in
            PlayerView(episodes: sel.episodes, startIndex: sel.index,
                       header: sel.playHeader ?? header, title: detail.name,
                       historyID: sel.historyID, resumeAt: sel.resumeAt)
        }
        .overlay {
            if resolving {
                ProgressView().tint(.white)
                    .padding(16)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            } else if let playNote {
                Text(playNote)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(.bottom, 30)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .task(id: playNote) {
            guard playNote != nil else { return }
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            playNote = nil
        }
    }

    private var headerBlock: some View {
        HStack(alignment: .top, spacing: 14) {
            if !detail.pic.isEmpty {
                PosterImage(urlString: detail.pic)
                    .frame(width: 110, height: 165)
                    .posterFrame()
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(detail.name).font(.title3.bold()).foregroundStyle(.white)
                if !detail.remarks.isEmpty {
                    Text(detail.remarks).font(.subheadline).foregroundStyle(Theme.accent)
                }
                metaLine("类型", detail.typeName)
                metaLine("年份", detail.year)
                metaLine("地区", detail.area)
                metaLine("导演", detail.director)
                metaLine("主演", detail.actor)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private func metaLine(_ label: String, _ value: String) -> some View {
        Group {
            if !value.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text(label).foregroundStyle(Theme.textDim)
                    Text(value).foregroundStyle(.white.opacity(0.88)).lineLimit(2)
                }
                .font(.footnote)
            }
        }
    }

    private var lineChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(detail.playFrom.indices, id: \.self) { i in
                    Text(detail.playFrom[i])
                        .font(.subheadline.weight(lineIndex == i ? .semibold : .regular))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(lineIndex == i ? Color.white : Color.white.opacity(0.10), in: Capsule())
                        .foregroundStyle(lineIndex == i ? .black : .white.opacity(0.85))
                        .onTapGesture { lineIndex = i }
                }
            }
            .padding(.horizontal, 18)
        }
    }

    private var episodeGrid: some View {
        let episodes = detail.playGroups.indices.contains(lineIndex) ? detail.playGroups[lineIndex] : []
        return VStack(alignment: .leading, spacing: 12) {
            Text("选集").font(.headline).foregroundStyle(.white).padding(.horizontal, 18)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                      spacing: 10) {
                ForEach(episodes) { ep in
                    Text(ep.name)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10))
                        .onTapGesture { tapEpisode(ep, in: episodes) }
                }
            }
            .padding(.horizontal, 18)
            if episodes.isEmpty {
                Text("该线路暂无选集").font(.footnote).foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 18)
            }
        }
    }

    private func tapEpisode(_ ep: VodDetail.Episode, in episodes: [VodDetail.Episode]) {
        guard let playerResolver else {
            let flag = detail.playFrom.indices.contains(lineIndex) ? detail.playFrom[lineIndex] : ""
            // CMS episode that is a web page, not a stream: run it
            // through the line's parse interfaces first.
            if !parses.isEmpty, !ParseResolver.isMediaURL(ep.url) {
                guard !resolving else { return }
                resolving = true
                Task {
                    let parsed = await ParseResolver.resolve(flag: flag, url: ep.url, parses: parses)
                    resolving = false
                    let finalURL = parsed?.url ?? ep.url
                    var finalHeader = header
                    if let parsed { for (k, v) in parsed.header { finalHeader[k] = v } }
                    let resume = recordHistory(episode: ep, episodeURL: finalURL, flag: flag, playHeader: finalHeader)
                    playSelection = PlaySelection(
                        episodes: episodes.map {
                            PlayerView.EpisodeRef(name: $0.name, url: $0.id == ep.id ? finalURL : $0.url)
                        },
                        index: episodes.firstIndex(where: { $0.id == ep.id }) ?? 0,
                        playHeader: parsed != nil ? finalHeader : nil,
                        historyID: historyEntryID(), resumeAt: resume)
                }
                return
            }
            let resume = recordHistory(episode: ep, episodeURL: ep.url, flag: "", playHeader: header)
            playSelection = PlaySelection(
                episodes: episodes.map { PlayerView.EpisodeRef(name: $0.name, url: $0.url) },
                index: episodes.firstIndex(where: { $0.id == ep.id }) ?? 0,
                historyID: historyEntryID(), resumeAt: resume)
            return
        }
        guard !resolving else { return }
        resolving = true
        let flag = detail.playFrom.indices.contains(lineIndex) ? detail.playFrom[lineIndex] : ""
        Task {
            let resolved = await playerResolver(flag, ep.url)
            resolving = false
            if let resolved {
                let resume = recordHistory(episode: ep, episodeURL: resolved.url, flag: flag, playHeader: resolved.header)
                playSelection = PlaySelection(
                    episodes: [PlayerView.EpisodeRef(name: ep.name, url: resolved.url)],
                    index: 0, playHeader: resolved.header,
                    historyID: historyEntryID(), resumeAt: resume)
            } else {
                playNote = "这一集需要解析接口，下一阶段接入"
            }
        }
    }

    // MARK: history

    private func historyEntryID() -> String? {
        guard let seed = historySeed else { return nil }
        return seed.siteKey + "|" + seed.vodId
    }

    /// File (or refresh) the history entry for this episode and return
    /// the resume point when the SAME episode was watched before.
    @discardableResult
    private func recordHistory(episode: VodDetail.Episode, episodeURL: String,
                               flag: String, playHeader: [String: String]) -> Double {
        guard let seed = historySeed, let id = historyEntryID() else { return 0 }
        let existing = HistoryStore.shared.entries.first { $0.id == id }
        let resume = (existing?.episodeID == episode.url) ? (existing?.positionSeconds ?? 0) : 0
        HistoryStore.shared.record(HistoryStore.Entry(
            vodId: seed.vodId, siteKey: seed.siteKey, name: detail.name, pic: detail.pic,
            episodeName: episode.name, episodeURL: episodeURL,
            positionSeconds: resume,
            durationSeconds: existing?.durationSeconds ?? 0,
            watchedSeconds: 0, updatedAt: Date(),
            lineID: seed.lineID, siteName: seed.siteName, episodeID: episode.url,
            playFlag: flag, playHeader: playHeader))
        return resume
    }
}

private struct PlaySelection: Identifiable {
    let episodes: [PlayerView.EpisodeRef]
    let index: Int
    var playHeader: [String: String]?
    var historyID: String?
    var resumeAt: Double = 0
    var id: String { episodes[index].url + "#\(index)" }
}
