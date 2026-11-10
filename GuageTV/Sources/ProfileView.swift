import SwiftUI

/// 我的 (Profile) — Rex's stats dashboard: week calendar strip, today's
/// watch time, history heatmap, 待看 / 收藏 / 在看 counters. Numbers bind to
/// the history store in stage 3; the module layout matches Rex now.
struct ProfileView: View {
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
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.35)).frame(width: 34, height: 34)
                Image(systemName: "person.fill").foregroundStyle(.white)
            }
            Text("默认环境").font(.headline).foregroundStyle(.white)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption).foregroundStyle(Theme.textDim)
            Spacer()
            Text("编辑").font(.subheadline.weight(.medium)).foregroundStyle(.white)
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
                    Text("今天").font(.subheadline).foregroundStyle(Theme.textDim)
                    Spacer()
                    Text(Date.now.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline).foregroundStyle(Theme.textDim)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("0.0").font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
                    Text("小时").foregroundStyle(Theme.textDim)
                }
                HStack(spacing: 16) {
                    Text("0 部电影").font(.footnote).foregroundStyle(Theme.textDim)
                    Text("0 集剧").font(.footnote).foregroundStyle(Theme.textDim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var heatmapCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("历史观看").font(.subheadline).foregroundStyle(Theme.textDim)
                let cols = Array(repeating: GridItem(.fixed(14), spacing: 4), count: 18)
                LazyVGrid(columns: cols, spacing: 4) {
                    ForEach(0..<(18 * 7), id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(i % 37 == 0 ? Theme.accent : Color.white.opacity(0.07))
                            .frame(width: 14, height: 14)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var counters: some View {
        HStack(spacing: 12) {
            counterCard(title: "收藏", value: "0")
            counterCard(title: "在看", value: "0")
            counterCard(title: "待看", value: "0")
        }
    }

    private func counterCard(title: String, value: String) -> some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(value).font(.title2.bold()).foregroundStyle(.white)
                Text(title).font(.footnote).foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
