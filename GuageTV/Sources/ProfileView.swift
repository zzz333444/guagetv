import SwiftUI

/// 我的 (Profile) — Rex's stats dashboard: week calendar strip, today's
/// watch time, history heatmap, 待看 / 收藏 / 在看 counters. Numbers bind to
/// the history store in stage 3; the module layout matches Rex now.
struct ProfileView: View {
    @ObservedObject private var store = HistoryStore.shared
    /// Tapped heatmap cell readout (v1.87): "M月d日 · 观看 X".
    @State private var heatDayInfo: String?

    /// Entries touched today / this week drive the stat cards.
    private var todayEntries: [HistoryStore.Entry] {
        store.entries.filter { Calendar.current.isDateInToday($0.updatedAt) }
    }
    private var totalHoursText: String {
        let total = store.entries.reduce(0) { $0 + $1.watchedSeconds }
        return total >= 3600
            ? String(format: "%.1f", total / 3600)
            : String(format: "%.0f", total / 60)
    }
    private var totalUnit: String {
        store.entries.reduce(0) { $0 + $1.watchedSeconds } >= 3600 ? "小时" : "分钟"
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                header
                calendarStrip
                todayCard
                heatmapCard
                counters
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .background(AmbientBackground(imageURL: nil))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.35)).frame(width: 34, height: 34)
                Image(systemName: "person.fill").foregroundStyle(Theme.text)
            }
            Text("默认环境").font(.headline).foregroundStyle(Theme.text)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption).foregroundStyle(Theme.textDim)
            Spacer()
            Text("编辑").font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(Theme.glass, in: Capsule())
        }
    }

    private var calendarStrip: some View {
        let days = ["日", "一", "二", "三", "四", "五", "六"]
        let today = Calendar.current.component(.day, from: Date())
        return HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { i in
                let day = today - 3 + i
                VStack(spacing: 4) {
                    Text(days[i]).font(.caption2).foregroundStyle(Theme.textDim)
                    Text("\(day)")
                        .font(.subheadline.weight(i == 3 ? .bold : .regular))
                        .foregroundStyle(i == 3 ? .white : .white.opacity(0.75))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(i == 3 ? Theme.accent.opacity(0.45) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var todayCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("累计观看").font(.subheadline).foregroundStyle(Theme.textDim)
                    Spacer()
                    Text(Date.now.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline).foregroundStyle(Theme.textDim)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(totalHoursText).font(.system(size: 34, weight: .bold)).foregroundStyle(Theme.text)
                    Text(totalUnit).foregroundStyle(Theme.textDim)
                }
                HStack(spacing: 16) {
                    Text("共 \(store.entries.count) 部").font(.footnote).foregroundStyle(Theme.textDim)
                    Text("今天看了 \(todayEntries.count) 部").font(.footnote).foregroundStyle(Theme.textDim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Real heat: last 12 weeks × 7 days, intensity = seconds actually
    /// watched that day (HistoryStore daily ledger). Below the grid,
    /// this week / this month totals with days watched.
    private var heatmapCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("观看热力").font(.subheadline).foregroundStyle(Theme.textDim)
                    Spacer()
                    Text("近 12 周").font(.caption).foregroundStyle(Theme.textDim)
                }
                let cols = Array(repeating: GridItem(.fixed(20), spacing: 5), count: 12)
                LazyVGrid(columns: cols, spacing: 5) {
                    ForEach(0..<(12 * 7), id: \.self) { i in
                        let level = heatLevel(cellIndex: i)
                        let fill: Color = level == 0
                            ? Color.white.opacity(0.07)
                            : Theme.accent.opacity(0.30 + 0.17 * Double(level))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(fill)
                            .frame(width: 20, height: 20)
                            .onTapGesture { heatCellTapped(i) }
                    }
                }
                HStack(spacing: 4) {
                    Text("少").font(.caption2).foregroundStyle(Theme.textDim)
                    ForEach(0...4, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(level == 0
                                  ? Color.white.opacity(0.07)
                                  : Theme.accent.opacity(0.30 + 0.17 * Double(level)))
                            .frame(width: 12, height: 12)
                    }
                    Text("多").font(.caption2).foregroundStyle(Theme.textDim)
                    if let heatDayInfo {
                        Spacer()
                        Text(heatDayInfo).font(.caption2).foregroundStyle(Theme.text)
                    }
                }
                Divider().background(Color.white.opacity(0.08))
                HStack(spacing: 12) {
                    periodStat(title: "本周", component: .weekOfYear)
                    periodStat(title: "本月", component: .month)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Cell 0 = 83 days ago, cells flow day by day to today.
    private func heatDate(cellIndex: Int) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: -(12 * 7 - 1) + cellIndex,
                        to: cal.startOfDay(for: Date())) ?? Date()
    }

    private func heatCellTapped(_ index: Int) {
        Haptics.selection()
        let day = heatDate(cellIndex: index)
        let seconds = store.watchedSeconds(on: day)
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        heatDayInfo = seconds > 0
            ? "\(f.string(from: day)) · 观看 \(heatDurationText(seconds))"
            : "\(f.string(from: day)) · 没看"
    }

    private func heatDurationText(_ seconds: Double) -> String {
        if seconds < 3600 { return "\(max(1, Int(seconds) / 60)) 分钟" }
        return String(format: "%.1f 小时", seconds / 3600)
    }

    /// 0 = 没看；1 = <30 分钟；2 = <1 小时；3 = <2 小时；4 = ≥2 小时。
    private func heatLevel(cellIndex: Int) -> Int {
        let day = heatDate(cellIndex: cellIndex)
        let seconds = store.watchedSeconds(on: day)
        switch seconds {
        case 0: return 0
        case ..<1800: return 1
        case ..<3600: return 2
        case ..<7200: return 3
        default: return 4
        }
    }

    private func periodStat(title: String, component: Calendar.Component) -> some View {
        let stats = watchedStats(for: component)
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(Theme.textDim)
            Text(durationText(stats.seconds)).font(.headline).foregroundStyle(Theme.text)
            Text("看了 \(stats.days) 天").font(.caption2).foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Total seconds watched inside the current week / month, plus
    /// how many days in that span had any viewing.
    private func watchedStats(for component: Calendar.Component) -> (seconds: Double, days: Int) {
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: component, for: Date()) else { return (0, 0) }
        var seconds = 0.0
        var days = 0
        var day = interval.start
        while day < interval.end {
            let s = store.watchedSeconds(on: day)
            seconds += s
            if s > 0 { days += 1 }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return (seconds, days)
    }

    private func durationText(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "0分钟" }
        if minutes < 60 { return "\(minutes)分钟" }
        return "\(minutes / 60)小时\(minutes % 60)分钟"
    }

    private var counters: some View {
        HStack(spacing: 12) {
            counterCard(title: "收藏",
                        value: "\(store.entries.filter { $0.isFavourite }.count)")
            counterCard(title: "在看",
                        value: "\(store.entries.filter { $0.positionSeconds > 30 && ($0.durationSeconds <= 0 || $0.positionSeconds < $0.durationSeconds * 0.95) }.count)")
            counterCard(title: "追剧",
                        value: "\(store.entries.filter { $0.isWatchlist }.count)")
        }
    }

    private func counterCard(title: String, value: String) -> some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(value).font(.title2.bold()).foregroundStyle(Theme.text)
                Text(title).font(.footnote).foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
