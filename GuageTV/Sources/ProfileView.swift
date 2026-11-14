import SwiftUI

/// 我的 (Profile) — Rex's stats dashboard: week calendar strip, today's
/// watch time, history heatmap, 待看 / 收藏 / 在看 counters. Numbers bind to
/// the history store in stage 3; the module layout matches Rex now.
struct ProfileView: View {
    @ObservedObject private var store = HistoryStore.shared

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

    /// Real heat: last 18 weeks × 7 days, intensity = how many
    /// titles were touched that day.
    private var heatmapCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("历史观看").font(.subheadline).foregroundStyle(Theme.textDim)
                let cols = Array(repeating: GridItem(.fixed(14), spacing: 4), count: 18)
                LazyVGrid(columns: cols, spacing: 4) {
                    ForEach(0..<(18 * 7), id: \.self) { i in
                        let count = heatCount(cellIndex: i)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(count == 0
                                  ? Color.white.opacity(0.07)
                                  : Theme.accent.opacity(0.35 + 0.2 * Double(min(count, 3))))
                            .frame(width: 14, height: 14)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func heatCount(cellIndex: Int) -> Int {
        // Cell 0 = 125 days ago, cells flow day by day to today.
        let cal = Calendar.current
        guard let day = cal.date(byAdding: .day, value: -(18 * 7 - 1) + cellIndex,
                                 to: cal.startOfDay(for: Date())) else { return 0 }
        return store.entries.filter { cal.isDate($0.updatedAt, inSameDayAs: day) }.count
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
