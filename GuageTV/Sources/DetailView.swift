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

/// Splits a raw episode name into (marker, title): the leading
/// episode marker （第N集 / N / EP01 / S1E1…) and the title text
/// after it, e.g. "第1集 归来" → ("第1集", "归来"),
/// "01.归来" → ("01", "归来"). Title is nil when the name carries
/// no title — pure marker ("第1集", "01", "EP01"), a whole label
/// ("正片", "12集全") — so the card shows just the episode name,
/// matching the Rex card rule. (v1.97)
func guageEpisodeNameParts(_ rawName: String) -> (marker: String, title: String?) {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    let markers = [
        #"^第\s*[0-9一二三四五六七八九十百千]+\s*集"#,
        #"^(?:S[0-9]+\s*)?E(?:P)?[0-9]+"#,
        #"^[0-9]+"#,
    ]
    for pattern in markers {
        if let range = name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            let marker = String(name[..<range.upperBound])
            var tail = String(name[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // "12集全" — digits followed by 集… is a whole label, not a title.
            if tail.hasPrefix("集") { return (name, nil) }
            tail = tail.trimmingCharacters(in: CharacterSet(charactersIn: "·-–—_.:：、 "))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (marker, tail.isEmpty ? nil : tail)
        }
    }
    return (name, nil)
}

/// Quality token carried by a source string — a line name like
/// "高清1080P线" or a remarks field like "HD1280高清中字".
/// Only surfaced, never invented: nil when the source sent no
/// such token, so cards without one show nothing extra. (v2.09)
func guageQualityToken(in text: String) -> String? {
    let upper = text.uppercased()
    for token in ["2160P", "4K", "1080P", "720P", "480P", "蓝光", "超清", "高清", "标清", "HD"] {
        if upper.contains(token) { return token }
    }
    return nil
}

/// Episode names from sources are often bare numbers ("1",
/// "01") or codes ("EP01"). The user wants them read as episodes:
/// those become 「第N集」; names that already say something
/// （第3集 / 正片 / 加长版…） stay untouched. Shared by the detail
/// grid, the in-player episode sheet and the player title line.
func guageEpisodeDisplayName(_ rawName: String, index: Int) -> String {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { return "第\(index + 1)集" }
    if name.allSatisfy(\.isNumber), let n = Int(name) { return "第\(n)集" }
    let upper = name.uppercased()
    if (upper.hasPrefix("EP") || upper.hasPrefix("E")), name.count <= 6 {
        let digits = upper.drop(while: { !$0.isNumber })
        if !digits.isEmpty, digits.allSatisfy(\.isNumber), let n = Int(digits) {
            return "第\(n)集"
        }
    }
    return name
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
    @State private var episodesReversed = false
    @State private var episodeSegment = 0
    @State private var playSelection: PlaySelection?
    @State private var resolving = false
    @State private var playNote: String?
    @State private var downloadMode = false
    @State private var synopsisExpanded = false
    /// Bottom 媒体信息 expandable (v1.78): source site / line /
    /// type / remarks — only fields the detail already carries.
    @State private var mediaInfoExpanded = false
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
                    mediaInfoSection
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
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: Theme.posterRadius))
            } else if let playNote {
                Text(playNote)
                    .font(.subheadline)
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.posterRadius))
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
                PosterImage(urlString: heroPic, pixelSize: 900)
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
            if let score = tmdbInfo?.score, !score.isEmpty, let value = Double(score) {
                // TMDB score as a 5-star bar (v1.78): 10-point score
                // mapped to 5 stars, partial fill on the last star.
                HStack(spacing: 6) {
                    StarBarView(value: value)
                    Text(score).font(.subheadline.weight(.bold))
                    Text("TMDB").font(.caption).foregroundStyle(Theme.textDim)
                }
                .foregroundStyle(Theme.text)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The episode the white button will play (resume target or
    /// the line's first), as a Rex-style sub-line: 第N集 · 原名.
    private var primarySubline: String {
        let episodes = detail.playGroups.indices.contains(lineIndex)
            ? detail.playGroups[lineIndex] : []
        guard !episodes.isEmpty else { return "" }
        let idx = episodes.firstIndex { historyEntry?.episodeID == $0.url } ?? 0
        let ep = episodes[idx]
        let display = guageEpisodeDisplayName(ep.name, index: idx)
        return ep.name == display ? display : "\(display) · \(ep.name)"
    }

    /// White capsule primary action (two lines, Rex-style: 播放 /
    /// 第N集） + ONE glass capsule holding the three labeled
    /// actions 收藏 / 追剧 / 下载. In this app 收藏 and 追剧 are
    /// the same list — a favourite lands on the 追剧 page and
    /// gets update checks — so both buttons reflect and toggle
    /// the same state.
    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.medium()
                primaryPlay()
            } label: {
                VStack(spacing: 1) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text(hasResume ? "继续播放" : "播放")
                    }
                    .font(.headline)
                    if !primarySubline.isEmpty {
                        Text(primarySubline)
                            .font(.caption.weight(.medium))
                            .opacity(0.65)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.white, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            HStack(spacing: 2) {
                if historySeed != nil {
                    actionCapsuleItem(
                        icon: isFav ? "bookmark.fill" : "bookmark",
                        label: "收藏", active: isFav) { toggleFavourite() }
                    actionCapsuleItem(
                        icon: isFav ? "bell.fill" : "bell",
                        label: "追剧", active: isFav) {
                        let turningOn = !isFav
                        toggleFavourite()
                        if turningOn { playNote = "已加入追剧，更新会在追剧页提醒" }
                    }
                }
                actionCapsuleItem(
                    icon: downloadMode ? "arrow.down.circle.fill" : "arrow.down.circle",
                    label: "下载", active: downloadMode) {
                    Haptics.tap()
                    downloadMode.toggle()
                    if downloadMode { playNote = "下载模式：点任意一集就下载，再点一次退出" }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Theme.glass, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.glassStroke, lineWidth: 1))
        }
    }

    /// One labeled mini-action inside the glass capsule.
    private func actionCapsuleItem(icon: String, label: String, active: Bool,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 17))
                Text(label).font(.caption2.weight(.medium))
            }
            .foregroundStyle(active ? Theme.accent : Theme.text)
            .frame(width: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    withAnimation(Theme.animQuick) { synopsisExpanded.toggle() }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
            }
        }
    }

    /// TMDB cast row (v1.41): round profile photos + name/role.
    /// v1.90: tapping a person cross-searches their name on the
    /// user's own lines (same sheet as similar titles).
    private var castBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("演职员").font(.headline).foregroundStyle(Theme.text)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(tmdbCast) { person in
                        Button {
                            Haptics.tap()
                            similarSeed = person.name
                            showSimilarSearch = true
                        } label: {
                            VStack(spacing: 5) {
                                PosterImage(urlString: person.profile, pixelSize: 240)
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
                        .buttonStyle(.plain)
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
                            Haptics.tap()
                            similarSeed = title.title
                            showSimilarSearch = true
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                PosterImage(urlString: title.poster)
                                    .frame(width: 92, height: 138)
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.smallRadius))
                                    .background(RoundedRectangle(cornerRadius: Theme.smallRadius).fill(Theme.glass))
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

    /// Bottom 媒体信息 (v1.78): a glass card listing only what
    /// the detail already carries — source site, current line,
    /// type, year, area, update status, episode counts. Empty
    /// fields are dropped, never invented; when nothing survives
    /// the whole section stays hidden.
    private var mediaInfoRows: [(label: String, value: String)] {
        let episodes = detail.playGroups.indices.contains(lineIndex)
            ? detail.playGroups[lineIndex] : []
        let line = detail.playFrom.indices.contains(lineIndex)
            ? detail.playFrom[lineIndex] : ""
        let lineValue = line.isEmpty ? "" : (episodes.isEmpty ? line : "\(line)（共 \(episodes.count) 集）")
        return [
            ("来源站点", historySeed?.siteName ?? ""),
            ("当前线路", lineValue),
            ("播放线路", detail.playFrom.count > 1 ? "\(detail.playFrom.count) 条" : ""),
            ("类型", detail.typeName),
            ("年份", detail.year),
            ("地区", detail.area),
            ("更新状态", detail.remarks),
            // v2.09: only when the remarks actually carry a
            // quality token — otherwise the row stays hidden
            // with the rest of the empty fields.
            ("画质", guageQualityToken(in: detail.remarks) ?? ""),
        ].filter { !$0.value.isEmpty }
    }

    @ViewBuilder
    private var mediaInfoSection: some View {
        if !mediaInfoRows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    Haptics.selection()
                    withAnimation(Theme.animQuick) { mediaInfoExpanded.toggle() }
                } label: {
                    HStack {
                        Text("媒体信息").font(.headline).foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: mediaInfoExpanded ? "chevron.up" : "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textDim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if mediaInfoExpanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(mediaInfoRows, id: \.label) { row in
                            HStack(alignment: .top, spacing: 8) {
                                Text(row.label)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.textDim)
                                    .frame(width: 64, alignment: .leading)
                                Text(row.value)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.text.opacity(0.88))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 7)
                            if row.label != mediaInfoRows.last?.label {
                                Divider().background(Theme.glassStroke)
                            }
                        }
                    }
                    .padding(.top, 10)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.cardTint, in: RoundedRectangle(cornerRadius: Theme.innerCardRadius, style: .continuous))
            .background(Theme.glass, in: RoundedRectangle(cornerRadius: Theme.innerCardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.innerCardRadius, style: .continuous)
                .strokeBorder(Theme.glassStroke, lineWidth: 1))
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
        Haptics.tap()
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
        // Display order: original indices ride along so reversed /
        // segmented views still name episodes by their true number.
        let ordered: [(offset: Int, element: VodDetail.Episode)] = episodesReversed
            ? Array(episodes.enumerated().reversed())
            : Array(episodes.enumerated())
        let chunks: [[(offset: Int, element: VodDetail.Episode)]] =
            ordered.isEmpty ? [] : stride(from: 0, to: ordered.count, by: 30).map {
                Array(ordered[$0..<min($0 + 30, ordered.count)])
            }
        let visible = chunks.indices.contains(episodeSegment)
            ? chunks[episodeSegment] : (chunks.first ?? [])
        return VStack(alignment: .leading, spacing: 12) {
            if detail.playFrom.count > 1 {
                // 播放资源 (v1.76, Rex-style): lines as two-column
                // resource cards instead of a dropdown menu; the
                // active line gets the lighter border + green check.
                Text("播放资源").font(.headline).foregroundStyle(Theme.text)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)],
                          spacing: 10) {
                    ForEach(detail.playFrom.indices, id: \.self) { i in
                        lineCard(i)
                    }
                }
            }
            HStack {
                Text("选集").font(.headline).foregroundStyle(Theme.text)
                Spacer()
                if episodes.count > 1 {
                    Button { Haptics.tap(); withAnimation(Theme.animQuick) { episodesReversed.toggle() } } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.caption2.weight(.bold))
                            Text(episodesReversed ? "倒序" : "正序")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Theme.glass, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.glassStroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            if chunks.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chunks.indices, id: \.self) { ci in
                            let first = chunks[ci].first?.offset ?? 0
                            let last = chunks[ci].last?.offset ?? 0
                            Text("\(first + 1)–\(last + 1)")
                                .font(.caption.weight(episodeSegment == ci ? .semibold : .regular))
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(episodeSegment == ci ? Color.white : Theme.glass, in: Capsule())
                                .foregroundStyle(episodeSegment == ci ? .black : Theme.text.opacity(0.85))
                                .onTapGesture { withAnimation(Theme.animQuick) { episodeSegment = ci }; Haptics.selection() }
                        }
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(visible, id: \.element.id) { pair in
                        episodeRailCard(pair.element, origIndex: pair.offset, in: episodes)
                    }
                }
            }
            if episodes.count > 1 {
                Button {
                    Haptics.medium()
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
        .onChange(of: lineIndex) { _, _ in episodeSegment = 0 }
    }

    /// One 播放资源 line card (v1.76): name + episode count; the
    /// active line gets the lighter border and green check (Rex).
    /// (v2.09) a spec line under the count, built only from data
    /// the source actually sent: a quality token in the line name
    /// (e.g. "1080P" in "高清1080P线") and the stream format of
    /// the line's first episode URL (.m3u8 → HLS, .mp4 → MP4).
    /// Lines without either show no spec row at all.
    private func lineSpec(_ i: Int) -> String {
        var parts: [String] = []
        if detail.playFrom.indices.contains(i),
           let token = guageQualityToken(in: detail.playFrom[i]) {
            parts.append(token)
        }
        let episodes = detail.playGroups.indices.contains(i) ? detail.playGroups[i] : []
        if let first = episodes.first?.url.lowercased() {
            if first.contains(".m3u8") { parts.append("HLS") }
            else if first.contains(".mp4") { parts.append("MP4") }
            else if first.contains(".flv") { parts.append("FLV") }
            else if first.contains(".mkv") { parts.append("MKV") }
        }
        return parts.joined(separator: " · ")
    }

    private func lineCard(_ i: Int) -> some View {
        let active = i == lineIndex
        let count = detail.playGroups.indices.contains(i) ? detail.playGroups[i].count : 0
        // v2.32: count and spec were two stacked caption rows —
        // one spec line ("共 12 集 · HLS · 1080P") reads denser,
        // matching the Rex resource-card spec row.
        let spec = lineSpec(i)
        let specLine = (count > 0 ? "共 \(count) 集" : "暂无集数")
            + (spec.isEmpty ? "" : " · \(spec)")
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(detail.playFrom[i])
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(specLine)
                    .font(.caption2)
                    .foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 0)
            if active {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        // v2.32: the hand-built double background (cardTint +
        // glass) and hand-written 0.45/0.12 border pair are the
        // shared glassPanel recipe plus Theme.glassStrokeStrong
        // for the active rim — same look, one dialect.
        .glassPanel(cornerRadius: Theme.innerCardRadius, shadow: false)
        .overlay(RoundedRectangle(cornerRadius: Theme.innerCardRadius, style: .continuous)
            .strokeBorder(active ? Theme.glassStrokeStrong : Theme.glassStroke,
                          lineWidth: active ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.selection()
            lineIndex = i
        }
    }

    /// One episode on the horizontal rail (v1.76, Rex-style): a
    /// 16:9 still card — the show's TMDB backdrop when known,
    /// else its poster (line feeds carry no per-episode stills) —
    /// with 第N集 and the raw name under it. The episode the
    /// history entry sits on keeps its white watched-check badge,
    /// and (v2.08) a white 1.5pt rim so the rail shows where you
    /// are even when playback just started (position 0, no check).
    private func episodeRailCard(_ ep: VodDetail.Episode, origIndex: Int,
                                 in episodes: [VodDetail.Episode]) -> some View {
        let still = [tmdbInfo?.backdrop ?? "", detail.pic].first { !$0.isEmpty } ?? ""
        let displayName = guageEpisodeDisplayName(ep.name, index: origIndex)
        let isCurrent = historyEntry?.episodeID == ep.url
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                if !still.isEmpty {
                    PosterImage(urlString: still)
                        .frame(width: 176, height: 99)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: Theme.posterRadius, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: Theme.posterRadius, style: .continuous)
                        .fill(Theme.glass)
                        .frame(width: 176, height: 99)
                }
                if isWatched(ep) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.black)
                        .frame(width: 17, height: 17)
                        .background(.white, in: Circle())
                        .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                        .offset(x: 5, y: -5)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.posterRadius, style: .continuous)
                .strokeBorder(isCurrent ? Color.white.opacity(0.9) : .clear, lineWidth: 1.5))
            Text(displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if ep.name != displayName {
                Text(ep.name)
                    .font(.caption2)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
        }
        .frame(width: 176, alignment: .leading)
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
        Haptics.medium()
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

    /// Whole-line download (v1.42, D1 并发于 v1.65): resolve every
    /// episode of the active line through the same resolver playback
    /// uses, then enqueue each downloadable one. Resolves run 3 at
    /// a time (a stalled episode no longer blocks the whole line);
    /// a failed episode retries once after a short pause before it
    /// is counted as skipped. Enqueue stays on the parent task so
    /// DownloadManager's @Published list is only touched from the
    /// main actor. Tuple: (index, url, header, retriedAndSucceeded).
    private func downloadWholeLine(episodes: [VodDetail.Episode]) {
        guard !resolving else { return }
        resolving = true
        let resolver = makeEpisodeResolver()
        let line = lineIndex
        Task {
            var added = 0
            var skipped = 0
            var retriedOK = 0
            var done = 0
            let total = episodes.count
            // One chunk = up to 3 episodes resolving concurrently.
            for chunkStart in stride(from: 0, to: total, by: 3) {
                let chunkEnd = min(chunkStart + 3, total)
                let outcomes = await withTaskGroup(
                    of: (Int, String, [String: String]?, Bool).self) { group in
                    for index in chunkStart..<chunkEnd {
                        group.addTask {
                            var outcome = await resolver(line, index)
                            var retried = false
                            if case .failed = outcome {
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                outcome = await resolver(line, index)
                                retried = true
                            }
                            switch outcome {
                            case .ok(let url, let resolvedHeader):
                                guard await DownloadManager.probeDownloadable(
                                    url: url, header: resolvedHeader) else {
                                    return (index, "", nil, false)
                                }
                                return (index, url, resolvedHeader, retried)
                            case .failed:
                                return (index, "", nil, false)
                            }
                        }
                    }
                    var results: [(Int, String, [String: String]?, Bool)] = []
                    for await result in group { results.append(result) }
                    return results
                }
                for (index, url, header, retried) in outcomes.sorted(by: { $0.0 < $1.0 }) {
                    done += 1
                    guard !url.isEmpty, let header else { skipped += 1; continue }
                    let ep = episodes[index]
                    DownloadManager.shared.enqueue(vodName: detail.name, episodeName: ep.name,
                                                   pic: detail.pic, url: url, header: header)
                    added += 1
                    if retried { retriedOK += 1 }
                }
                playNote = "正在加入下载 \(done)/\(total)…"
            }
            resolving = false
            playNote = "全集下载已加入 \(added) 集"
                + (retriedOK > 0 ? "（其中 \(retriedOK) 集重试后成功）" : "")
                + (skipped > 0 ? "，\(skipped) 集解析不了跳过" : "")
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
        Haptics.selection()
        guard !resolving else { return }
        resolving = true
        let startLine = lineIndex
        let startIndex = episodes.firstIndex(where: { $0.id == ep.id }) ?? 0
        let resolver = makeEpisodeResolver()
        let resolveStarted = Date()
        Task {
            let outcome = await resolver(startLine, startIndex)
            Diagnostics.recordResolve(started: resolveStarted, ok: outcome.isOK)
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
