import SwiftUI

/// 直播 (Live) — one live source from the config: group chips,
/// channel rows with logos and the currently-airing programme (EPG),
/// tap to play. Modeled on the reference shells' live pages: the
/// programme guide is a first-class citizen, not an afterthought.
struct LiveView: View {
    let live: TVBoxConfig.Live

    @State private var groups: [LiveGroup] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var playChannel: LiveListParser.Channel?
    /// v2.43: 本次播放的回看上下文——生效的回看模板（频道级
    /// 优先、线路级兜底）与拼模板用的原始频道地址（回看地址
    /// 本身不能再当模板底）。随 playChannel 一起设置。
    @State private var playCatchupTemplate: String?
    @State private var playCatchupBaseURL: String?
    @State private var epgByKey: [String: [EPGProgramme]] = [:]
    @State private var templateCache: [String: [EPGProgramme]] = [:]
    @State private var sheetProgrammes: ProgrammeSheetItem?

    /// v2.10: 频道搜索（跨全部分组）与分组折叠。
    @State private var searchText = ""
    /// v2.23: 折叠状态与当前分组按直播源分别持久化（此前是
    /// 全源共用一个 "live.groupsCollapsed" 开关，在 A 源折叠
    /// 会把 B 源也折叠起来；选中分组每次进页都回到第一组）。
    /// AppStorage 的 key 只能在 init 里动态拼，用源名 + 源地址
    /// 区分同名不同源的直播配置。
    @AppStorage("live.groupsCollapsed") private var groupsCollapsed = false
    @AppStorage("live.selectedGroup") private var selectedGroup = ""

    init(live: TVBoxConfig.Live) {
        self.live = live
        let keySuffix = "\(live.name)|\(live.url)"
        _groupsCollapsed = AppStorage(wrappedValue: false,
                                      "live.groupsCollapsed.\(keySuffix)")
        _selectedGroup = AppStorage(wrappedValue: "",
                                    "live.selectedGroup.\(keySuffix)")
    }

    /// v2.23: EPG 进度条的刷新节拍对齐到整分钟。节目起止都在
    /// 整分钟上，TimelineView 从 .now 起每 60 秒一拍会让「正在播」
    /// 在节目交接后最多晚一分钟才翻页、进度条也跳变；从下一个
    /// 整分钟起拍，交接时刻正好重绘。
    @State private var epgTickStart: Date = LiveView.nextMinuteBoundary()

    private static func nextMinuteBoundary() -> Date {
        Calendar.current.nextDate(after: Date(),
                                  matching: DateComponents(second: 0),
                                  matchingPolicy: .nextTime) ?? Date()
    }

    // Favourites + custom groups (v1.42), stored per live source.
    @AppStorage("live.favourites") private var favouritesJSON = "[]"
    @AppStorage("live.customGroups") private var customGroupsJSON = "{}"
    @State private var groupAssignTarget: LiveListParser.Channel?
    @State private var newGroupName = ""

    private static let favouritesGroup = "⭐ 收藏"

    private func channelKey(_ channel: LiveListParser.Channel) -> String {
        live.name + "|" + channel.name + "|" + channel.url
    }
    private var favouriteKeys: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(favouritesJSON.utf8))) ?? [])
    }
    private var customGroupMap: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(customGroupsJSON.utf8))) ?? [:]
    }
    private var customGroupNames: [String] {
        Array(Set(customGroupMap.values)).sorted()
    }
    private var allChannels: [LiveListParser.Channel] {
        groups.flatMap(\.channels)
    }

    private func toggleFavourite(_ channel: LiveListParser.Channel) {
        var keys = favouriteKeys
        let key = channelKey(channel)
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        if let data = try? JSONEncoder().encode(Array(keys)),
           let json = String(data: data, encoding: .utf8) {
            favouritesJSON = json
        }
    }

    private func assignGroup(_ channel: LiveListParser.Channel, group: String?) {
        var map = customGroupMap
        if let group, !group.isEmpty {
            map[channelKey(channel)] = group
        } else {
            map.removeValue(forKey: channelKey(channel))
        }
        if let data = try? JSONEncoder().encode(map),
           let json = String(data: data, encoding: .utf8) {
            customGroupsJSON = json
        }
    }

    private var isTemplateEPG: Bool { (live.epg ?? "").contains("{name}") }
    private var currentChannels: [LiveListParser.Channel] {
        // v2.10: 有搜索词时跨全部分组找频道，不受当前分组限制。
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return allChannels.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        if selectedGroup == Self.favouritesGroup {
            let keys = favouriteKeys
            return allChannels.filter { keys.contains(channelKey($0)) }
        }
        if customGroupNames.contains(selectedGroup) {
            let map = customGroupMap
            return allChannels.filter { map[channelKey($0)] == selectedGroup }
        }
        return groups.first { $0.name == selectedGroup }?.channels ?? []
    }
    private var playHeader: [String: String] {
        live.ua.map { ["User-Agent": $0] } ?? [:]
    }

    /// v2.43: 频道生效的回看模板——频道级 catchup-source 优先，
    /// 没有时回落到线路级 catchup。返回模板与频道声明的回看天数。
    private func effectiveCatchup(for channel: LiveListParser.Channel) -> (template: String, days: Int?)? {
        if !channel.catchupSource.isEmpty {
            return (channel.catchupSource, channel.catchupDays)
        }
        if let source = live.catchup?.source, !source.isEmpty {
            return (source, nil)
        }
        return nil
    }

    /// 按频道地址找生效模板（节目单行只有地址、没有 Channel 对象时用）。
    private func effectiveCatchup(forChannelURL url: String) -> (template: String, days: Int?)? {
        if let channel = allChannels.first(where: { $0.url == url }) {
            return effectiveCatchup(for: channel)
        }
        if let source = live.catchup?.source, !source.isEmpty {
            return (source, nil)
        }
        return nil
    }

    /// 用生效模板拼回看地址；拼不出来（模板无占位符）返回 nil。
    private func replayURL(channelURL: String, start: Date, end: Date) -> String? {
        guard let hit = effectiveCatchup(forChannelURL: channelURL) else { return nil }
        return TVBoxConfig.CatchupTemplate.buildURL(template: hit.template, channelURL: channelURL,
                                                    start: start, end: end)
    }

    /// v2.43 EPG 与回看范围对齐校验：节目开始时间早于
    /// catchup-days 的起点时已出回看期，不给回看入口。
    /// 未声明天数的频道/线路不限期（沿用旧行为）。
    private func catchupExpired(_ programme: EPGProgramme, channelURL: String, now: Date = Date()) -> Bool {
        guard let days = effectiveCatchup(forChannelURL: channelURL)?.days,
              let earliest = TVBoxConfig.CatchupTemplate.earliestDate(days: days, now: now)
        else { return false }
        return programme.start < earliest
    }

    var body: some View {
        Group {
            if loading {
                // v2.12: bare spinner → channel-row skeleton.
                SkeletonRowList(count: 6)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            } else if let errorText {
                // R8 (v1.85): bare error text → shared empty state
                // with a retry action (load() is idempotent).
                VStack {
                    Spacer()
                    EmptyStateCopy.loadFailed(message: errorText,
                                                retry: { Task { await load() } })
                        .padding(.horizontal, 18)
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    searchBar
                    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        groupHeader
                        if !groupsCollapsed { groupChips }
                    } else {
                        searchSummary
                    }
                    channelList
                }
            }
        }
        .animation(Theme.animStandard, value: loading)
        .background(AmbientBackground(imageURL: nil))
        .navigationTitle(live.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .task(id: selectedGroup) { await loadTemplateEPG() }
        .fullScreenCover(item: $playChannel) { channel in
            PlayerView(episodes: [PlayerView.EpisodeRef(name: channel.name, url: channel.url)],
                       startIndex: 0, header: playHeader, title: channel.name, isLive: true,
                       catchupTemplate: playCatchupTemplate,
                       catchupBaseURL: playCatchupBaseURL ?? channel.url)
        }
        .sheet(item: $sheetProgrammes) { entry in
            programmeSheet(entry)
        }
        .alert("新建分组", isPresented: Binding(
            get: { groupAssignTarget != nil },
            set: { if !$0 { groupAssignTarget = nil } }
        )) {
            TextField("分组名，如 央视", text: $newGroupName)
            Button("取消", role: .cancel) { groupAssignTarget = nil }
            Button("创建并加入") {
                if let target = groupAssignTarget, !newGroupName.isEmpty {
                    assignGroup(target, group: newGroupName)
                    selectedGroup = newGroupName
                }
                groupAssignTarget = nil
            }
        } message: {
            Text("频道会同时出现在这个分组里（长按频道可管理）。")
        }
    }

    /// v2.10: 频道搜索框（玻璃胶囊，跨全部分组过滤）。
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textDim)
            TextField("搜索频道", text: $searchText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: Theme.posterRadius))
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    /// v2.10: 搜索时显示命中计数；平时显示当前分组与折叠开关。
    private var searchSummary: some View {
        HStack {
            Text("在 \(groups.count) 个分组中找到 \(currentChannels.count) 个频道")
                .font(.caption).foregroundStyle(Theme.textDim)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    private var groupHeader: some View {
        HStack(spacing: 8) {
            Text("分组").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
            Text(selectedGroup).font(.subheadline).foregroundStyle(Theme.textDim).lineLimit(1)
            Spacer()
            Text("\(groups.count) 组 · \(allChannels.count) 频道")
                .font(.caption).foregroundStyle(Theme.textDim)
            Button {
                Haptics.selection()
                withAnimation { groupsCollapsed.toggle() }
            } label: {
                Image(systemName: groupsCollapsed ? "chevron.down" : "chevron.up")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.textDim)
                    .padding(6)
                    .glassCircle()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, groupsCollapsed ? 10 : 2)
    }

    private var groupChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(Self.favouritesGroup)
                ForEach(customGroupNames, id: \.self) { name in chip(name) }
                ForEach(groups) { group in chip(group.name) }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }

    private func chip(_ name: String) -> some View {
        Text(name)
            .font(.subheadline.weight(selectedGroup == name ? .semibold : .regular))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(selectedGroup == name ? Color.white : Theme.glass, in: Capsule())
            .foregroundStyle(selectedGroup == name ? .black : Theme.text.opacity(0.85))
            .onTapGesture { Haptics.selection(); selectedGroup = name }
    }

    private var channelList: some View {
        ScrollView(showsIndicators: false) {
            // R5 (v1.92): 60 秒一拍重绘，EPG 进度条随时间推进。
            // v2.23: 节拍从下一个整分钟起，与节目起止时刻对齐。
            TimelineView(.periodic(from: epgTickStart, by: 60)) { _ in
                LazyVStack(spacing: 10) {
                    ForEach(currentChannels) { channel in
                        channelRow(channel)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 110)
            }
        }
    }

    private func channelRow(_ channel: LiveListParser.Channel) -> some View {
        let programmes = programmes(for: channel)
        let now = programmes.first { $0.contains(Date()) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                logo(channel)
                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.name).font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text).lineLimit(1)
                    if let now {
                        Text("正在播 \(timeText(now.start))–\(timeText(now.end)) \(now.title)")
                            .font(.caption).foregroundStyle(Theme.accent).lineLimit(1)
                    } else if !programmes.isEmpty {
                        Text("今日 \(programmes.count) 个节目").font(.caption).foregroundStyle(Theme.textDim)
                    }
                }
                Spacer()
                // v2.43 回看：频道级 catchup-source 或线路级
                // catchup 任一存在时，频道行挂「可回看」角标。
                if effectiveCatchup(for: channel) != nil {
                    Text("可回看")
                        .font(.caption2.weight(.semibold)).foregroundStyle(Theme.ok)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.ok.opacity(0.15), in: Capsule())
                }
                if !programmes.isEmpty {
                    Button {
                        sheetProgrammes = ProgrammeSheetItem(channel: channel.name,
                                                             channelURL: channel.url,
                                                             list: programmes)
                    } label: {
                        Text("节目单").font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.glass, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if favouriteKeys.contains(channelKey(channel)) {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                }
                Image(systemName: "play.circle.fill").font(.title3).foregroundStyle(Theme.text.opacity(0.9))
            }
            // R5 (v1.92): 当前节目细进度条 — 按 EPG now 起止算已播比例。
            if let now {
                epgProgressBar(now)
            }
        }
        .padding(12)
        // v2.32: the row was a flat Theme.glass fill at a hand
        // 14pt radius — now the shared glassPanel recipe
        // (tint + rim light, no shadow: dense repeated rows)
        // at Theme.innerCardRadius, like the detail line cards.
        .glassPanel(cornerRadius: Theme.innerCardRadius, shadow: false)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.medium()
            playCatchupTemplate = effectiveCatchup(for: channel)?.template
            playCatchupBaseURL = channel.url
            playChannel = channel
        }
        .contextMenu {
            Button {
                toggleFavourite(channel)
            } label: {
                Label(favouriteKeys.contains(channelKey(channel)) ? "取消收藏" : "收藏频道",
                      systemImage: "star")
            }
            ForEach(customGroupNames, id: \.self) { name in
                Button {
                    assignGroup(channel, group: name)
                } label: {
                    Label("加入分组「\(name)」", systemImage: "folder")
                }
            }
            Button {
                groupAssignTarget = channel
                newGroupName = ""
            } label: {
                Label("新建分组并加入", systemImage: "folder.badge.plus")
            }
            if customGroupMap[channelKey(channel)] != nil {
                Button(role: .destructive) {
                    assignGroup(channel, group: nil)
                } label: {
                    Label("移出自定义分组", systemImage: "folder.badge.minus")
                }
            }
        }
    }

    private func logo(_ channel: LiveListParser.Channel) -> some View {
        Group {
            if !channel.logo.isEmpty {
                // R8 (v1.85): bare AsyncImage decoded channel logos
                // at full resolution with no cache cap; PosterImage
                // goes through the downsampled cache (240 px: the
                // logo only ever shows at 44×30 pt).
                PosterImage(urlString: channel.logo, fit: true, pixelSize: 240)
            } else {
                Image(systemName: "tv").foregroundStyle(Theme.textDim)
            }
        }
        .frame(width: 44, height: 30)
    }

    /// R5 (v1.92): 当前节目细进度条 — 已播时长 / 节目总时长，
    /// 轨道淡白、填充用主题强调色，3pt 高贴在频道行底部。
    private func epgProgressBar(_ programme: EPGProgramme) -> some View {
        let total = programme.end.timeIntervalSince(programme.start)
        let elapsed = Date().timeIntervalSince(programme.start)
        let fraction = total > 0 ? min(1, max(0, elapsed / total)) : 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.text.opacity(0.16))
                Capsule().fill(Theme.accent)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
    }

    private func programmeSheet(_ entry: ProgrammeSheetItem) -> some View {
        NavigationStack {
            List {
                ForEach(dayGroups(entry.list), id: \.day) { group in
                    Section {
                        ForEach(group.items) { programme in
                            programmeRow(programme, channelURL: entry.channelURL,
                                         channelName: entry.channel)
                        }
                    } header: {
                        Text(dayLabel(group.day)).foregroundStyle(Theme.section)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("\(entry.channel) · 节目单")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    /// v2.43 回看：已播完的节目（end ≤ 现在）且该频道有生效
    /// 回看模板（频道级 catchup-source 优先、线路级兜底）时，
    /// 给出「回看」按钮——按节目起止时刻展开模板拼出回看地址、
    /// 走同一播放器播；超出 catchup-days 回看期的节目只显示
    /// 「超出回看范围」。正在播 / 未开播的节目没有回看。
    /// 点按先关节目单 sheet，0.35 秒后再弹播放器全屏盖板
    /// （sheet 未收起时直接弹盖板会被系统吞掉）。
    private func programmeRow(_ programme: EPGProgramme,
                              channelURL: String, channelName: String) -> some View {
        HStack(spacing: 10) {
            Text("\(timeText(programme.start))–\(timeText(programme.end))")
                .font(.caption.monospacedDigit()).foregroundStyle(Theme.textDim)
            Text(programme.title).font(.subheadline)
                .foregroundStyle(programme.contains(Date()) ? Theme.accent : Theme.text)
            if programme.contains(Date()) {
                Spacer()
                Text("正在播").font(.caption2.weight(.bold)).foregroundStyle(Theme.accent)
            } else if programme.end <= Date(), catchupExpired(programme, channelURL: channelURL) {
                // v2.43: 节目开始时间已超出该频道声明的
                // catchup-days 回看期，不给回看入口。
                Spacer()
                Text("超出回看范围").font(.caption2).foregroundStyle(Theme.textDim)
            } else if programme.end <= Date(),
                      let url = replayURL(channelURL: channelURL,
                                          start: programme.start, end: programme.end) {
                Spacer()
                Button("回看") {
                    Haptics.medium()
                    sheetProgrammes = nil
                    playCatchupTemplate = effectiveCatchup(forChannelURL: channelURL)?.template
                    playCatchupBaseURL = channelURL
                    let replay = LiveListParser.Channel(
                        name: "\(channelName) · \(programme.title)", url: url, group: "")
                    Task {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        playChannel = replay
                    }
                }
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.ok)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Theme.ok.opacity(0.15), in: Capsule())
                .buttonStyle(.plain)
            }
        }
        .listRowBackground(Color.clear)
    }


    /// Programmes grouped by broadcast day, days in order.
    private func dayGroups(_ list: [EPGProgramme]) -> [(day: Date, items: [EPGProgramme])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: list) { cal.startOfDay(for: $0.start) }
        return grouped.keys.sorted().map { day in
            (day: day, items: (grouped[day] ?? []).sorted { $0.start < $1.start })
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "今天" }
        if cal.isDateInTomorrow(day) { return "明天" }
        if cal.isDateInYesterday(day) { return "昨天" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 EEE"
        return formatter.string(from: day)
    }

    // MARK: data

    private func programmes(for channel: LiveListParser.Channel) -> [EPGProgramme] {
        if isTemplateEPG { return templateCache[channel.name] ?? [] }
        if !channel.tvgId.isEmpty, let hit = epgByKey[channel.tvgId] { return hit }
        return epgByKey[channel.name] ?? []
    }

    private func load() async {
        loading = true
        errorText = nil
        do {
            if let embedded = live.channels, !embedded.isEmpty {
                let channels = embedded.compactMap { item -> LiveListParser.Channel? in
                    guard let url = item.urls.first, !url.isEmpty else { return nil }
                    return LiveListParser.Channel(name: item.name, url: url, group: live.name)
                }
                groups = [LiveGroup(ordinal: 0, name: live.name, channels: channels)]
            } else {
                let text = try await fetchListText()
                groups = LiveListParser.parse(text).enumerated().map { LiveGroup(ordinal: $0.offset, name: $0.element.name, channels: $0.element.channels) }
            }
            if groups.isEmpty {
                errorText = "直播列表是空的，或格式不认识"
            } else if !groups.contains(where: { $0.name == selectedGroup })
                        && !customGroupNames.contains(selectedGroup)
                        && selectedGroup != Self.favouritesGroup {
                // v2.23: 只在存的分组已不存在时回落到第一组，
                // 否则保留上次选中的分组（按源持久化）。
                selectedGroup = groups[0].name
            }
        } catch {
            errorText = "直播列表加载失败：\(error.localizedDescription)"
        }
        loading = false
        // Plain-mode EPG loads once for the whole source.
        if let epg = live.epg, !epg.isEmpty, !isTemplateEPG {
            epgByKey = await EPGService.fetchAll(epgURL: epg, ua: live.ua)
        }
    }

    /// Template-mode EPG: one fetch per channel in the visible
    /// group, capped so a huge group can't flood the guide service.
    private func loadTemplateEPG() async {
        guard isTemplateEPG, let template = live.epg else { return }
        for channel in currentChannels.prefix(40) where templateCache[channel.name] == nil {
            let programmes = await EPGService.fetchChannel(template: template, channelName: channel.name, ua: live.ua)
            if !programmes.isEmpty { templateCache[channel.name] = programmes }
        }
    }

    private func fetchListText() async throws -> String {
        let url: URL?
        if let direct = URL(string: live.url), direct.scheme?.hasPrefix("http") == true {
            url = direct
        } else if let baseText = UserDefaults.standard.string(forKey: "configSourceURL"),
                  let base = URL(string: baseText) {
            url = URL(string: live.url, relativeTo: base)?.absoluteURL
        } else {
            url = nil
        }
        guard let url else { throw URLError(.badURL) }
        let data = try await NetFetch.data(from: url, ua: live.ua ?? NetFetch.okhttpUA)
        if let utf8 = String(bytes: data, encoding: .utf8) { return utf8 }
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringConvertIANACharSetNameToEncoding("GB18030" as CFString))
        if let text = String(bytes: data, encoding: String.Encoding(rawValue: gb)) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// One channel group in first-seen order. The id carries the
/// first-seen ordinal: two sources may both ship a group called
/// "电影", and keying on name alone collapsed the second group's
/// rows (and their selection state) into the first.
struct LiveGroup: Identifiable {
    let ordinal: Int
    let name: String
    let channels: [LiveListParser.Channel]
    var id: String { "\(ordinal)-\(name)" }
}

// Sheet payload wrapper (tuples are not Identifiable).
private struct ProgrammeSheetItem: Identifiable {
    let channel: String
    let channelURL: String
    let list: [EPGProgramme]
    var id: String { channel }
}
