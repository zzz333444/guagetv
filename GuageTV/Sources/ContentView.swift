import SwiftUI

/// App shell — Rex's floating glass pill tab bar:
/// 发现 / 我的 / 资源库 / 设置 in one frosted capsule, search as a separate
/// floating circle button on the right.
struct ContentView: View {
    @State private var config: TVBoxConfig?
    @State private var tab = 0
    @State private var showSearch = false

    init() {
        // Restore the persisted config (v7): imported lines survive the
        // app being swiped away.
        _config = State(initialValue: ConfigLibrary.loadActive())
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case 0: DiscoverView(config: config)
                case 1: HistoryView()
                case 2: LibraryView(config: $config) { tab = 3 }
                default: SettingsView(config: $config)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            floatingBar
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSearch) {
            SearchView(config: config)
        }
    }

    private var floatingBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                tabButton(index: 0, icon: "house.fill", label: "发现")
                tabButton(index: 1, icon: "clock.fill", label: "记录")
                tabButton(index: 2, icon: "externaldrive.fill", label: "资源库")
                tabButton(index: 3, icon: "gearshape.fill", label: "设置")
            }
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.glassStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)

            Button { showSearch = true } label: {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.glassStroke, lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            }
        }
    }

    private func tabButton(index: Int, icon: String, label: String) -> some View {
        Button { tab = index } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 19))
                Text(label).font(.system(size: 10))
            }
            .foregroundStyle(tab == index ? .white : .white.opacity(0.55))
            .frame(width: 62, height: 46)
            .background(tab == index ? Color.white.opacity(0.14) : Color.clear, in: Capsule())
        }
    }
}
