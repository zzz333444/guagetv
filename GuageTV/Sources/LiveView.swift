import SwiftUI

/// 直播 (Live) — one live source from the config: group chips,
/// channel rows with logos and the currently-airing programme (EPG),
/// tap to play. Modeled on the reference shells' live pages: the
/// programme guide is a first-class citizen, not an afterthought.
struct LiveView: View {
    let live: TVBoxConfig.Live

    @State private var groups: [LiveGroup] = []
    @State private var selectedGroup = ""
    @State private var loading = true
    @State private var errorText: String?
    @State private var playChannel: LiveListParser.Channel?
    @State private var epgByKey: [String: [EPGProgramme]] = [:]
    @State private var templateCache: [String: [EPGProgramme]] = [:]
    @State private var sheetProgrammes: ProgrammeSheetItem?

    private var isTemplateEPG: Bool { (live.epg ?? "").contains("{name}") }
    private var currentChannels: [LiveListParser.Channel] {
        groups.first { $0.name == selectedGroup }?.channels ?? []
    }
    private var playHeader: [String: String] {
        live.ua.map { ["User-Agent": $0] } ?? [:]
    }

    var body: some View {
        Group {
            if loading {
                ProgressView().tint(Theme.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText {
                Text(errorText).font(.subheadline).foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center).padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    groupChips
                    channelList
                }
            }
        }
        .background(AmbientBackground(imageURL: nil))
        .navigationTitle(live.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .task(id: selectedGroup) { await loadTemplateEPG() }
        .fullScreenCover(item: $playChannel) { channel in
            PlayerView(episodes: [PlayerView.EpisodeRef(name: channel.name, url: channel.url)],
                       startIndex: 0, header: playHeader, title: channel.name)
        }
        .sheet(item: $sheetProgrammes) { entry in
            programmeSheet(entry)
        }
    }

    private var groupChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(groups, id: \.name) { group in
                    Text(group.name)
                        .font(.subheadline.weight(selectedGroup == group.name ? .semibold : .regular))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(selectedGroup == group.name ? Color.white : Theme.glass, in: Capsule())
                        .foregroundStyle(selectedGroup == group.name ? .black : Theme.text.opacity(0.85))
                        .onTapGesture { selectedGroup = group.name }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }

    private var channelList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 10) {
                ForEach(currentChannels) { channel in
                    channelRow(channel)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 110)
        }
    }

    private func channelRow(_ channel: LiveListParser.Channel) -> some View {
        let programmes = programmes(for: channel)
        let now = programmes.first { $0.contains(Date()) }
        return HStack(spacing: 12) {
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
            if !programmes.isEmpty {
                Button {
                    sheetProgrammes = ProgrammeSheetItem(channel: channel.name, list: programmes)
                } label: {
                    Text("节目单").font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.glass, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Image(systemName: "play.circle.fill").font(.title3).foregroundStyle(Theme.text.opacity(0.9))
        }
        .padding(12)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
        .onTapGesture { playChannel = channel }
    }

    private func logo(_ channel: LiveListParser.Channel) -> some View {
        Group {
            if !channel.logo.isEmpty, let url = URL(string: channel.logo) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Image(systemName: "tv").foregroundStyle(Theme.textDim)
                }
            } else {
                Image(systemName: "tv").foregroundStyle(Theme.textDim)
            }
        }
        .frame(width: 44, height: 30)
    }

    private func programmeSheet(_ entry: ProgrammeSheetItem) -> some View {
        NavigationStack {
            List {
                ForEach(dayGroups(entry.list), id: \.day) { group in
                    Section {
                        ForEach(group.items) { programme in
                            programmeRow(programme)
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

    private func programmeRow(_ programme: EPGProgramme) -> some View {
        HStack(spacing: 10) {
            Text("\(timeText(programme.start))–\(timeText(programme.end))")
                .font(.caption.monospacedDigit()).foregroundStyle(Theme.textDim)
            Text(programme.title).font(.subheadline)
                .foregroundStyle(programme.contains(Date()) ? Theme.accent : Theme.text)
            if programme.contains(Date()) {
                Spacer()
                Text("正在播").font(.caption2.weight(.bold)).foregroundStyle(Theme.accent)
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
                groups = [LiveGroup(name: live.name, channels: channels)]
            } else {
                let text = try await fetchListText()
                groups = LiveListParser.parse(text).map { LiveGroup(name: $0.name, channels: $0.channels) }
            }
            if groups.isEmpty {
                errorText = "直播列表是空的，或格式不认识"
            } else {
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

/// One channel group in first-seen order.
struct LiveGroup: Identifiable {
    let name: String
    let channels: [LiveListParser.Channel]
    var id: String { name }
}

// Sheet payload wrapper (tuples are not Identifiable).
private struct ProgrammeSheetItem: Identifiable {
    let channel: String
    let list: [EPGProgramme]
    var id: String { channel }
}
