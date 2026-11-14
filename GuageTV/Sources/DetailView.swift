import SwiftUI

/// What a spider's playerContent resolution produced: either a
/// playable URL, or the reason there is none. The reason is the
/// spider's own msg/errMsg whenever it sent one (drives say things
/// like "还未登录夸克账号，请前往【配置中心】登录") — it must reach
/// the user verbatim; a bare nil used to hide it entirely.
enum ResolveOutcome {
    case ok(url: String, header: [String: String])
    case failed(reason: String)

    /// The spider's stated reason in a playerContent result, if any.
    static func spiderReason(in result: [String: Any]) -> String? {
        for key in ["msg", "errMsg"] {
            if let text = result[key] as? String,
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return text
            }
        }
        return nil
    }
}

/// 详情 (Detail) — Rex-style: ambient backdrop header, meta block, synopsis,
/// play-line chips, episode grid. Tapping an episode hands its URL (plus the
/// site's required headers) to the player; parse-needed sites resolve through
/// the config's parses in a later wiring step.
struct DetailView: View {
    let detail: VodDetail
    var header: [String: String] = [:]
    /// When set (py / JS / jar spiders), episode taps resolve through
    /// this first: episode urls are opaque ids until playerContent
    /// answers. Failures carry the spider's own reason (its msg —
    /// e.g. a drive asking the user to log in) so it can be shown
    /// verbatim instead of vanishing behind a generic note.
    var playerResolver: ((String, String) async -> ResolveOutcome)?
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
    @State private var downloadMode = false
    @State private var synopsisExpanded = false
    /// TMDB enrichment for this title （设置里开启并填了密钥才有）:
    /// backdrop for the hero, a synopsis when the feed has none,
    /// and the TMDB score chip under the title.
    @State private var tmdbInfo: TMDBClient.Info?
    @State private var tmdbCast: [TMDBClient.CastMember] = []
    @State private var tmdbSimilar: [TMDBClient.TMDBTitle] = []
    @State private var similarSeed = ""
    @State private var showSimilarSearch = false
    @ObservedObject private var historyStore = HistoryStore.shared

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                heroHeader
                VStack(alignment: .leading, spacing: 20) {
                    titleBlock
                    actionRow
                    infoLines
                    if !synopsisText.isEmpty { synopsisBlock }
                    if !tmdbCast.isEmpty { castBlock }
                    if !tmdbSimilar.isEmpty { similarBlock }
                    episodeSection
                }
                .padding(.horizontal, 18)
                // Pulled UP over the hero's melt zone: the title
                // sits on the fading edge of the cover instead of
                // below a hard seam (the Rex detail look).
                .padding(.top, -46)
            }
            // Lock the content to the scroll view's own width: a
            // single over-wide child (a long unbroken cast string
            // is enough) used to stretch the whole page past the
            // screen edges, pushing text and the episode grid off
            // both sides.
            .containerRelativeFrame(.horizontal, alignment: .leading)
            // Clear the floating tab bar: the last episode rows
            // must be able to scroll fully out from under it.
            .padding(.bottom, 130)
        }
        .background(AmbientBackground(imageURL: detail.pic, intensity: 0.65))
        .ignoresSafeArea(edges: .top)
        .onAppear {
            if let seed = historySeed {
                isFav = HistoryStore.shared.isFavourite(siteKey: seed.siteKey, vodId: seed.vodId)
                HistoryStore.shared.markUpdateSeen(siteKey: seed.siteKey, vodId: seed.vodId,
                                                   remarks: detail.remarks)
            }
        }
        .fullScreenCover(item: $playSelection) { sel in
            PlayerView(episodes: sel.episodes, startIndex: sel.index,
                       header: sel.playHeader ?? header, title: detail.name,
                       historyID: sel.historyID, resumeAt: sel.resumeAt, pic: detail.pic,
                       lineNames: sel.lineNames, lineIndex: sel.lineIndex,
                       lineEpisodes: sel.lineEpisodes,
                       initialResolved: sel.initialResolved,
                       resolver: sel.resolver,
                       onEpisodeChange: sel.onEpisodeChange)
        }
        .overlay {
            if resolving {
                ProgressView().tint(Theme.text)
                    .padding(16)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            } else if let playNote {
                Text(playNote)
                    .font(.subheadline)
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 30)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .task {
            if TMDBClient.isOn {
                tmdbInfo = await TMDBClient.lookup(name: detail.name, year: detail.year)
                if let info = tmdbInfo, info.tmdbID > 0 {
                    async let cast = TMDBClient.credits(for: info)
                    async let similar = TMDBClient.similar(for: info)
                    tmdbCast = await cast
                    tmdbSimilar = await similar
                }
            }
        }
        .sheet(isPresented: $showSimilarSearch) {
            SearchView(config: ConfigLibrary.loadActive(), initialKeyword: similarSeed)
        }
        .task(id: playNote) {
            guard let note = playNote else { return }
            // Failure reasons (a spider's msg can be a full sentence)
            // stay up long enough to actually read; short status
            // notes keep the quick fade.
            let seconds: UInt64 = note.count > 24 ? 7_000_000_000 : 2_600_000_000
            try? await Task.sleep(nanoseconds: seconds)
            if playNote == note { playNote = nil }
        }
    }

    // MARK: Rex-style header (hero → title → actions)

    /// The hero's artwork: the TMDB backdrop (a true landscape
    /// still) when enrichment found one, else the feed's poster.
    private var heroPic: String {
        if let backdrop = tmdbInfo?.backdrop, !backdrop.isEmpty { return backdrop }
        return detail.pic
    }

    /// Full-bleed poster hero, Rex-style: the cover runs to the
    /// very top of the screen and DISSOLVES into the page — the
    /// image itself carries an alpha fade over its lower half, so
    /// it melts into the ambient-blurred background behind the
    /// page. (v1.35 melted it into flat Theme.bg instead, which
    /// left a visible straight edge where the hero block ended
    /// and the tinted content area began.)
    private var heroHeader: some View {
        ZStack(alignment: .bottom) {
            if !heroPic.isEmpty {
                PosterImage(urlString: heroPic)
                    .frame(height: 500)
                    .clipped()
                    .mask(
                        LinearGradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.50),
                            .init(color: .clear, location: 0.98),
                        ], startPoint: .top, endPoint: .bottom)
                    )
                // Legibility shade at the very top only (status
                // bar / back button zone); transparent elsewhere
                // so it never re-introduces an edge.
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.22), location: 0),
                    .init(color: .clear, location: 0.28),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                    .frame(height: 500)
            } else {
                // No artwork at all: don't open the page with a
                // 500pt void — a short spacer is enough.
                Color.clear.frame(height: 150)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Centred title + one meta line （年份 · 类型 · 地区, whichever
    /// the detail actually carries) + the remarks line.
    private var titleBlock: some View {
        VStack(spacing: 8) {
            Text(detail.name)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            let meta = [detail.year, detail.typeName, detail.area]
                .filter { !$0.isEmpty }
            if !meta.isEmpty {
                Text(meta.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !detail.remarks.isEmpty {
                Text(detail.remarks)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let score = tmdbInfo?.score, !score.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill").font(.caption2)
                    Text("TMDB \(score)").font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Color(red: 0.05, green: 0.45, blue: 0.65), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// White capsule primary action (plays / resumes through the
    /// same tapEpisode path as the grid) + glass round buttons for
    /// favourite (bookmark) and download mode.
    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.tap()
                primaryPlay()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text(hasResume ? "继续播放" : "播放")
                }
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(.white, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            if historySeed != nil {
                Button { toggleFavourite() } label: {
                    Image(systemName: isFav ? "bookmark.fill" : "bookmark")
                        .font(.title3)
                        .foregroundStyle(isFav ? Theme.accent : Theme.text)
                        .frame(width: 48, height: 48)
                        .background(Theme.glass, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.glassStroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Button {
                downloadMode.toggle()
                if downloadMode { playNote = "下载模式：点任意一集就下载，再点一次退出" }
            } label: {
                Image(systemName: downloadMode ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(downloadMode ? Theme.accent : Theme.text)
                    .frame(width: 48, height: 48)
                    .background(Theme.glass, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.glassStroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    /// Director / cast, kept from the old header as quiet lines.
    @ViewBuilder
    private var infoLines: some View {
        if !detail.director.isEmpty || !detail.actor.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                metaLine("导演", detail.director)
                metaLine("主演", detail.actor)
            }
        }
    }

    /// The synopsis on show: the feed's own text first; TMDB's
    /// overview steps in only when the feed carries none.
    private var synopsisText: String {
        if !detail.content.isEmpty { return detail.content }
        return tmdbInfo?.overview ?? ""
    }

    /// Synopsis: three lines by default, 展开/收起 toggles the full
    /// text.
    private var synopsisBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("简介").font(.headline).foregroundStyle(Theme.text)
            Text(synopsisText)
                .font(.subheadline).foregroundStyle(Theme.text.opacity(0.75))
                .lineSpacing(4)
                .lineLimit(synopsisExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button(synopsisExpanded ? "收起" : "展开") {
                    withAnimation(.easeInOut(duration: 0.2)) { synopsisExpanded.toggle() }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
            }
        }
    }

    /// TMDB cast row (v1.41): round profile photos + name/role.
    private var castBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("演职员").font(.headline).foregroundStyle(Theme.text)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(tmdbCast) { person in
                        VStack(spacing: 5) {
                            PosterImage(urlString: person.profile)
                                .frame(width: 58, height: 58)
                                .clipShape(Circle())
                                .background(Circle().fill(Theme.glass))
                            Text(person.name)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            if !person.character.isEmpty {
                                Text(person.character)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textDim)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 64)
                    }
                }
            }
        }
    }

    /// TMDB similar titles (v1.41): tapping one cross-searches it
    /// on the user's own lines — TMDB itself has no streams.
    private var similarBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("相似推荐").font(.headline).foregroundStyle(Theme.text)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(tmdbSimilar) { title in
                        Button {
                            similarSeed = title.title
                            showSimilarSearch = true
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                PosterImage(urlString: title.poster)
                                    .frame(width: 92, height: 138)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.glass))
                                Text(title.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                if !title.score.isEmpty {
                                    Text("TMDB \(title.score)")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textDim)
                                }
                            }
                            .frame(width: 92)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// This vod's history entry, if the loaders seeded one.
    private var historyEntry: HistoryStore.Entry? {
        guard let id = historyEntryID() else { return nil }
        return historyStore.entries.first { $0.id == id }
    }

    private var hasResume: Bool {
        guard let entry = historyEntry else { return false }
        return entry.positionSeconds > 0 && !entry.episodeID.isEmpty
    }

    /// The white button's target: the episode the history entry
    /// points at when it's on the current line, else the line's
    /// first episode.
    private func primaryPlay() {
        let episodes = detail.playGroups.indices.contains(lineIndex) ? detail.playGroups[lineIndex] : []
        guard let first = episodes.first else { return }
        let target = episodes.first { historyEntry?.episodeID == $0.url } ?? first
        tapEpisode(target, in: episodes)
    }

    @State private var isFav = false

    private func toggleFavourite() {
        guard let seed = historySeed else { return }
        let target = !isFav
        let stub = HistoryStore.Entry(
            vodId: seed.vodId, siteKey: seed.siteKey, name: detail.name, pic: detail.pic,
            episodeName: "", episodeURL: "", positionSeconds: 0, durationSeconds: 0,
            watchedSeconds: 0, updatedAt: Date(), isFavourite: target,
            lineID: seed.lineID, siteName: seed.siteName, lastRemarks: detail.remarks)
        HistoryStore.shared.setFavourite(stub: stub, on: target)
        isFav = target
    }

    private func metaLine(_ label: String, _ value: String) -> some View {
        Group {
            if !value.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text(label).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: true, vertical: false)
                    // fixedSize(horizontal: false) is the point:
                    // inside an HStack a Text otherwise claims its
                    // full single-line intrinsic width and shoves
                    // the whole page sideways instead of wrapping.
                    Text(value).foregroundStyle(Theme.text.opacity(0.88)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 选集 header （选集 + the line picker as a Menu capsule, only
    /// when there is more than one line) over the episode grid.
    private var episodeSection: some View {
        let episodes = detail.playGroups.indices.contains(lineIndex) ? detail.playGroups[lineIndex] : []
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("选集").font(.headline).foregroundStyle(Theme.text)
                Spacer()
                if detail.playFrom.count > 1 {
                    Menu {
                        ForEach(detail.playFrom.indices, id: \.self) { i in
                            Button {
                                lineIndex = i
                            } label: {
                                if i == lineIndex {
                                    Label(detail.playFrom[i], systemImage: "checkmark")
                                } else {
                                    Text(detail.playFrom[i])
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(detail.playFrom.indices.contains(lineIndex)
                                 ? detail.playFrom[lineIndex] : "线路")
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.bold))
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Theme.glass, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.glassStroke, lineWidth: 1))
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                ForEach(episodes) { ep in
                    episodeCard(ep, in: episodes)
                }
            }
            if episodes.count > 1 {
                Button {
                    downloadWholeLine(episodes: episodes)
                } label: {
                    Label("下载全集（当前线路 \(episodes.count) 集）", systemImage: "arrow.down.to.line")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Theme.glass, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if episodes.isEmpty {
                Text("该线路暂无选集").font(.footnote).foregroundStyle(Theme.textDim)
            }
        }
    }

    /// One episode: poster thumbnail + name on a glass card; the
    /// episode the history entry sits on (with real progress)
    /// carries the white watched-check badge.
    private func episodeCard(_ ep: VodDetail.Episode, in episodes: [VodDetail.Episode]) -> some View {
        HStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                if !detail.pic.isEmpty {
                    PosterImage(urlString: detail.pic)
                        .frame(width: 58, height: 38)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 58, height: 38)
                }
                if isWatched(ep) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.black)
                        .frame(width: 15, height: 15)
                        .background(.white, in: Circle())
                        .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                        .offset(x: 4, y: -4)
                }
            }
            Text(ep.name)
                .font(.subheadline)
                .foregroundStyle(Theme.text)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap()
            if downloadMode { downloadEpisode(ep) }
            else { tapEpisode(ep, in: episodes) }
        }
        .contextMenu {
            Button { tapEpisode(ep, in: episodes) } label: {
                Label("播放", systemImage: "play.fill")
            }
            Button { downloadEpisode(ep) } label: {
                Label("下载此集", systemImage: "arrow.down.circle")
            }
        }
    }

    /// Watched = the history entry for this vod points at this
    /// episode and holds a real resume position.
    private func isWatched(_ ep: VodDetail.Episode) -> Bool {
        guard let entry = historyEntry else { return false }
        return entry.episodeID == ep.url && entry.positionSeconds > 0
    }

    /// Long-press download: resolves the episode exactly like
    /// playback does (parse interface / spider resolver), then hands
    /// the final media URL to the DownloadManager.
    private func downloadEpisode(_ ep: VodDetail.Episode) {
        let flag = detail.playFrom.indices.contains(lineIndex) ? detail.playFrom[lineIndex] : ""
        if let playerResolver {
            guard !resolving else { return }
            resolving = true
            Task {
                let outcome = await playerResolver(flag, ep.url)
                resolving = false
                switch outcome {
                case .ok(let url, let resolvedHeader):
                    enqueueChecked(url: url, header: resolvedHeader, ep: ep)
                case .failed(let reason):
                    playNote = "下载不了：\(reason)"
                }
            }
            return
        }
        if !parses.isEmpty, !ParseResolver.isMediaURL(ep.url) {
            guard !resolving else { return }
            resolving = true
            Task {
                let parsed = await ParseResolver.resolve(flag: flag, url: ep.url, parses: parses)
                resolving = false
                if let parsed {
                    var finalHeader = header
                    for (k, v) in parsed.header { finalHeader[k] = v }
                    enqueueChecked(url: parsed.url, header: finalHeader, ep: ep)
                } else {
                    playNote = "这一集解析失败，下载不了"
                }
            }
            return
        }
        enqueueChecked(url: ep.url, header: header, ep: ep)
    }

    /// Whole-line download (v1.42): resolve every episode of the
    /// active line through the same resolver playback uses, then
    /// enqueue each downloadable one. Runs sequentially — spider
    /// resolvers are serial anyway — with progress in the note.
    private func downloadWholeLine(episodes: [VodDetail.Episode]) {
        guard !resolving else { return }
        resolving = true
        let resolver = makeEpisodeResolver()
        let line = lineIndex
        Task {
            var added = 0
            var skipped = 0
            for (index, ep) in episodes.enumerated() {
                playNote = "正在加入下载 \(index + 1)/\(episodes.count)…"
                switch await resolver(line, index) {
                case .ok(let url, let resolvedHeader):
                    if await DownloadManager.probeDownloadable(url: url, header: resolvedHeader) {
                        DownloadManager.shared.enqueue(vodName: detail.name, episodeName: ep.name,
                                                       pic: detail.pic, url: url, header: resolvedHeader)
                        added += 1
                    } else {
                        skipped += 1
                    }
                case .failed:
                    skipped += 1
                }
            }
            resolving = false
            playNote = "全集下载已加入 \(added) 集" + (skipped > 0 ? "，\(skipped) 集解析不了跳过" : "")
        }
    }

    /// Every download path funnels through here: probe first (a web
    /// page in disguise is refused with a plain reason), then enqueue.
    private func enqueueChecked(url: String, header: [String: String], ep: VodDetail.Episode) {
        playNote = "正在检测这一集能不能下载…"
        Task {
            if await DownloadManager.probeDownloadable(url: url, header: header) {
                DownloadManager.shared.enqueue(vodName: detail.name, episodeName: ep.name,
                                               pic: detail.pic, url: url, header: header)
                playNote = "已加入下载：\(ep.name)"
            } else {
                playNote = "这个站点给的是网页地址，下载不了"
            }
        }
    }

    /// The resolver the in-player episode/line switching runs on:
    /// exactly the two paths tap-to-play has always taken (spider
    /// playerContent, or CMS parse interfaces / raw URL), packaged
    /// per (line, episode) so the player can resolve on demand.
    /// Before v1.38 a spider line handed the player ONLY the tapped
    /// episode — the next-episode button had nothing to switch to.
    private func makeEpisodeResolver() -> PlayerView.Resolver {
        let resolver = playerResolver
        let parsesCopy = parses
        let baseHeader = header
        let groups = detail.playGroups
        let flags = detail.playFrom
        return { line, epIndex in
            guard groups.indices.contains(line), groups[line].indices.contains(epIndex) else {
                return .failed("集数不存在")
            }
            let ep = groups[line][epIndex]
            let flag = flags.indices.contains(line) ? flags[line] : ""
            if let resolver {
                switch await resolver(flag, ep.url) {
                case .ok(let url, let h): return .ok(url: url, header: h)
                case .failed(let reason): return .failed(reason)
                }
            }
            if !parsesCopy.isEmpty, !ParseResolver.isMediaURL(ep.url) {
                if let parsed = await ParseResolver.resolve(flag: flag, url: ep.url, parses: parsesCopy) {
                    var h = baseHeader
                    for (k, v) in parsed.header { h[k] = v }
                    return .ok(url: parsed.url, header: h)
                }
                return .ok(url: ep.url, header: baseHeader)
            }
            return .ok(url: ep.url, header: baseHeader)
        }
    }

    /// Playback moved inside the player (episode jump / line
    /// switch): file the history entry for the episode now on
    /// screen so resume and 追剧进度 keep pointing at the truth.
    private func episodeChanged(line: Int, index: Int, url: String,
                                header: [String: String]) {
        guard detail.playGroups.indices.contains(line),
              detail.playGroups[line].indices.contains(index) else { return }
        let ep = detail.playGroups[line][index]
        let flag = detail.playFrom.indices.contains(line) ? detail.playFrom[line] : ""
        recordHistory(episode: ep, episodeURL: url, flag: flag, playHeader: header)
    }

    private func tapEpisode(_ ep: VodDetail.Episode, in episodes: [VodDetail.Episode]) {
        guard !resolving else { return }
        resolving = true
        let startLine = lineIndex
        let startIndex = episodes.firstIndex(where: { $0.id == ep.id }) ?? 0
        let resolver = makeEpisodeResolver()
        Task {
            let outcome = await resolver(startLine, startIndex)
            resolving = false
            switch outcome {
            case .ok(let url, let resolvedHeader):
                let flag = detail.playFrom.indices.contains(startLine)
                    ? detail.playFrom[startLine] : ""
                let resume = recordHistory(episode: ep, episodeURL: url,
                                           flag: flag, playHeader: resolvedHeader)
                playSelection = PlaySelection(
                    episodes: episodes.map { PlayerView.EpisodeRef(name: $0.name, url: $0.url) },
                    index: startIndex,
                    playHeader: resolvedHeader,
                    historyID: historyEntryID(), resumeAt: resume,
                    lineNames: detail.playFrom,
                    lineIndex: startLine,
                    lineEpisodes: detail.playGroups.map { group in
                        group.map { PlayerView.EpisodeRef(name: $0.name, url: $0.url) }
                    },
                    initialResolved: (url: url, header: resolvedHeader),
                    resolver: resolver,
                    onEpisodeChange: { line, idx, url, h in
                        episodeChanged(line: line, index: idx, url: url, header: h)
                    })
            case .failed(let reason):
                playNote = reason
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
            playFlag: flag, playHeader: playHeader, lastRemarks: detail.remarks))
        return resume
    }
}

private struct PlaySelection: Identifiable {
    let episodes: [PlayerView.EpisodeRef]
    let index: Int
    var playHeader: [String: String]?
    var historyID: String?
    var resumeAt: Double = 0
    var lineNames: [String] = []
    var lineIndex: Int = 0
    var lineEpisodes: [[PlayerView.EpisodeRef]] = []
    var initialResolved: (url: String, header: [String: String])?
    var resolver: PlayerView.Resolver?
    var onEpisodeChange: ((Int, Int, String, [String: String]) -> Void)?
    var id: String { episodes[index].url + "#\(index)" }
}
