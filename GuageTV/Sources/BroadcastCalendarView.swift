import SwiftUI

/// 播出日历 (v2.09): bangumi 每日放送的周视图 —— 今天 + 本周
/// 一到周日，点哪天就拉哪天的 dailySchedule 栏目。数据来自已
/// 导入的 Rex 动漫数据模块（rex.bangumi）；没导入时只显示去
/// 模块页导入的指引，不编造、不写死任何番剧。栏目结果复用
/// FWDColumnCache（v2.06 规则：默认 30 分钟），重进当天即出屏。
struct BroadcastCalendarView: View {
    @State private var record: FWDRecord?
    @State private var selectedDay = 0
    @State private var items: [FWDItem] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var detailItem: FWDItem?

    /// 今天 + 本周一到周日：(chip 文案, 传给 dailySchedule 的 day 值)。
    /// 日期用 Calendar 真日期推算，跨月不算错（v2.08 周历教训）。
    private var days: [(label: String, value: String)] {
        let cal = Calendar.current
        let today = Date()
        var out: [(label: String, value: String)] = [("今天", "today")]
        let weekday = cal.component(.weekday, from: today) // 1 = 周日
        let daysSinceMonday = (weekday + 5) % 7
        guard let monday = cal.date(byAdding: .day, value: -daysSinceMonday, to: today) else {
            return out
        }
        let names = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
        let short = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        for i in 0..<7 {
            guard let d = cal.date(byAdding: .day, value: i, to: monday) else { continue }
            let m = cal.component(.month, from: d)
            let day = cal.component(.day, from: d)
            out.append(("\(short[i]) \(m)/\(day)", names[i]))
        }
        return out
    }

    private var dailyModule: FWDModuleEntry? {
        record?.meta.listModules.first { $0.id == "dailySchedule" }
    }

    /// v2.35 今日标记：days[0] 是「今天」快捷芯片，days[1...7]
    /// 是本周一到周日；今天所在的周芯片下标 = 1 + 距周一的天数，
    /// 该芯片下方挂一个强调色小圆点，周切换时一眼能定位今天。
    private var todayWeekdayIndex: Int {
        let weekday = Calendar.current.component(.weekday, from: Date())
        return 1 + (weekday + 5) % 7
    }

    var body: some View {
        Group {
            if loading {
                ScrollView(showsIndicators: false) {
                    SkeletonPosterGrid()
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 110)
                }
                .transition(.opacity)
            } else if record == nil || dailyModule == nil {
                VStack {
                    Spacer()
                    EmptyStateView(icon: "calendar",
                                   title: "动漫数据模块还没导入",
                                   message: "播出日历来自 Rex 动漫数据模块（bangumi 每日放送）。去「模块」页点「导入 Rex 官方模块」，回来就能看本周每天播什么。")
                        .padding(.horizontal, 18)
                    Spacer()
                }
            } else if let errorText, items.isEmpty {
                VStack {
                    Spacer()
                    EmptyStateCopy.loadFailed(message: errorText,
                                                retry: { Task { await load(bypassCache: true) } })
                        .padding(.horizontal, 18)
                    Spacer()
                }
            } else {
                content
            }
        }
        .animation(Theme.animStandard, value: loading)
        .background(AmbientBackground(imageURL: nil))
        .navigationTitle("播出日历")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $detailItem) { item in
            Group {
                if let record {
                    FWDDetailView(record: record, item: item)
                }
            }
        }
        .task {
            record = FWDStore.records().first { $0.id == "rex.bangumi" }
                ?? FWDStore.records().first {
                    $0.meta.listModules.contains { $0.id == "dailySchedule" }
                }
            await load()
        }
    }

    private var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                // Week strip: 今天 + 周一…周日（带日期）。v2.35：
                // 今天所在的周芯片下方挂强调色圆点；选中态切换
                // 走 animQuick，不再瞬间跳变。
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(days.indices, id: \.self) { idx in
                            Button {
                                Haptics.selection()
                                selectedDay = idx
                                Task { await load() }
                            } label: {
                                VStack(spacing: 2) {
                                    Text(days[idx].label)
                                        .font(.caption.weight(selectedDay == idx ? .semibold : .regular))
                                        .foregroundStyle(selectedDay == idx ? .black : Theme.text.opacity(0.85))
                                    // 占位圆点保持各芯片同高，只在今天那格着色。
                                    Circle()
                                        .fill(idx == todayWeekdayIndex ? Theme.accent : Color.clear)
                                        .frame(width: 5, height: 5)
                                }
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(selectedDay == idx ? Color.white : Theme.glass, in: Capsule())
                                .overlay(Capsule().strokeBorder(Theme.glassStroke, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18)
                    .animation(Theme.animQuick, value: selectedDay)
                }
                if let errorText, !items.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Theme.accent)
                        Text(errorText)
                            .font(.caption).foregroundStyle(Theme.textDim)
                            .lineLimit(2)
                        Spacer()
                        Button("重新加载") {
                            Haptics.tap()
                            Task { await load(bypassCache: true) }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(10)
                    .background(Theme.glass, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                    .padding(.horizontal, 18)
                }
                if items.isEmpty {
                    EmptyStateView(icon: "calendar.badge.exclamationmark",
                                   title: "这天没有放送",
                                   message: "换一天看看",
                                   compact: true)
                        .padding(.horizontal, 18)
                } else {
                    VStack(spacing: 10) {
                        ForEach(items) { item in
                            Button {
                                Haptics.tap()
                                detailItem = item
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    PosterImage(urlString: item.posterURL, pixelSize: 240)
                                        .frame(width: 54, height: 76)
                                        .posterFrame()
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Theme.text)
                                            .lineLimit(2)
                                        if !item.shortMetaLine.isEmpty {
                                            Text(item.shortMetaLine)
                                                .font(.caption)
                                                .foregroundStyle(Theme.textDim)
                                        }
                                        if !item.genreTitle.isEmpty {
                                            Text(item.genreTitle)
                                                .font(.caption)
                                                .foregroundStyle(Theme.textDim)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textDim)
                                        .padding(.top, 4)
                                }
                                .padding(10)
                                .background(Theme.glass, in: RoundedRectangle(cornerRadius: Theme.innerCardRadius, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Theme.innerCardRadius, style: .continuous)
                                    .strokeBorder(Theme.glassStroke, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 40)
                }
            }
            .padding(.top, 12)
        }
    }

    /// Same cache rule as the module column view (v2.06): page-1
    /// results replay from cache inside the TTL; manual retries
    /// bypass it; empty results are never cached.
    private func load(bypassCache: Bool = false) async {
        guard let record, let module = dailyModule,
              let source = FWDStore.source(for: record) else {
            loading = false
            return
        }
        loading = true
        errorText = nil
        var params: [String: Any] = ["day": days[selectedDay].value]
        for p in record.meta.globalParams where !p.value.isEmpty {
            params[p.name] = p.value
        }
        let ttl = record.meta.cacheDuration > 0
            ? TimeInterval(record.meta.cacheDuration) : FWDColumnCache.defaultTTL
        let cacheKey = FWDColumnCache.key(moduleID: record.id,
                                          columnID: module.id, params: params)
        if !bypassCache, let cached = FWDColumnCache.get(key: cacheKey, ttl: ttl) {
            items = cached.map(FWDItem.init)
            loading = false
            return
        }
        do {
            let result = try await FWDRuntime(widgetID: record.id)
                .call(function: module.functionName,
                      params: params,
                      source: source)
            let rows = (result as? [[String: Any]] ?? [])
            items = rows.map(FWDItem.init)
            if !rows.isEmpty {
                FWDColumnCache.set(key: cacheKey, rows: rows)
            }
            errorText = nil
        } catch {
            errorText = "加载失败：\(error.localizedDescription)"
        }
        loading = false
    }
}
