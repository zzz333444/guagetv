import SwiftUI

/// App shell — Rex's floating glass pill tab bar:
/// 发现 / 我的 / 资源库 / 设置 in one frosted capsule, search as a separate
/// floating circle button on the right.
struct ContentView: View {
    @State private var config: TVBoxConfig?
    @State private var tab = 0
    @State private var showSearch = false
    /// 外观与交互 choice: "system" follows the phone, else forced.
    @AppStorage("themeMode.v1") private var themeMode = "dark"
    @AppStorage("tabShowRecords") private var showRecordsTab = true
    @AppStorage("tabShowLibrary") private var showLibraryTab = true
    /// Share-sheet import offer (SharedImportCenter bumps the
    /// counter from onOpenURL; the alert below consumes it).
    @AppStorage(SharedImportCenter.counterKey) private var sharedImportCounter = 0
    @State private var shareOfferName: String?
    @State private var shareResult: String?
    /// App lock (v1.41): locked on cold start and after any trip
    /// to the background while the setting is on.
    @AppStorage("appLock.enabled") private var appLockEnabled = false
    @State private var appLocked = false
    @Environment(\.scenePhase) private var scenePhase

    private var colorScheme: ColorScheme? {
        switch themeMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    init() {
        // Restore the persisted config (v7): imported lines survive the
        // app being swiped away.
        _config = State(initialValue: ConfigLibrary.loadActive())
    }

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .regular {
                // iPad layout (v1.42): a slim glass rail on the
                // left instead of the floating bottom bar; pages
                // get the full width for wider grids.
                HStack(spacing: 0) {
                    sideRail
                    tabContent
                }
            } else {
                ZStack(alignment: .bottom) {
                    tabContent
                    floatingBar
                        .padding(.horizontal, 18)
                        .padding(.bottom, 10)
                }
            }
        }
        .overlay {
            if appLockEnabled, appLocked {
                AppLockView { appLocked = false }
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .preferredColorScheme(colorScheme)
        .onAppear {
            clampTab()
            if appLockEnabled { appLocked = true }
            if let id = ConfigLibrary.activeID() { JarProxyClient.warmLine(id: id) }
            ConfigLibrary.refreshStaleEntries()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, appLockEnabled { appLocked = true }
        }
        .onChange(of: showRecordsTab) { _ in clampTab() }
        .onChange(of: showLibraryTab) { _ in clampTab() }
        .sheet(isPresented: $showSearch) {
            SearchView(config: config)
        }
        .onChange(of: sharedImportCounter) { _ in
            shareOfferName = SharedImportCenter.pendingFileName
        }
        .alert("收到分享的文件", isPresented: Binding(
            get: { shareOfferName != nil },
            set: { if !$0 { shareOfferName = nil } }
        )) {
            Button("加入资源库") {
                shareResult = SharedImportCenter.performImport()
                config = ConfigLibrary.loadActive()
                shareOfferName = nil
            }
            Button("取消", role: .cancel) { shareOfferName = nil }
        } message: {
            Text("把「\(shareOfferName ?? "")」导入为线路？")
        }
        .alert("导入结果", isPresented: Binding(
            get: { shareResult != nil },
            set: { if !$0 { shareResult = nil } }
        )) {
            Button("好") { shareResult = nil }
        } message: {
            Text(shareResult ?? "")
        }
    }

    private var tabContent: some View {
        Group {
            switch tab {
            case 0: DiscoverView(config: config)
            case 1: HistoryView()
            case 2: LibraryView(config: $config) { tab = 3 }
            default: SettingsView(config: $config)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.22), value: tab)
    }

    private var sideRail: some View {
        VStack(spacing: 14) {
            tabButton(index: 0, icon: "house.fill", label: "发现")
            if showRecordsTab { tabButton(index: 1, icon: "clock.fill", label: "记录") }
            if showLibraryTab { tabButton(index: 2, icon: "externaldrive.fill", label: "资源库") }
            tabButton(index: 3, icon: "gearshape.fill", label: "设置")
            Spacer()
            Button { showSearch = true } label: {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 52, height: 52)
                    .glassCircle()
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 8)
        .background(Theme.glass.opacity(0.5))
    }

    private var floatingBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                tabButton(index: 0, icon: "house.fill", label: "发现")
                if showRecordsTab { tabButton(index: 1, icon: "clock.fill", label: "记录") }
                if showLibraryTab { tabButton(index: 2, icon: "externaldrive.fill", label: "资源库") }
                tabButton(index: 3, icon: "gearshape.fill", label: "设置")
            }
            .padding(6)
            .glassCapsule()

            Button { showSearch = true } label: {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 52, height: 52)
                    .glassCircle()
            }
        }
    }

    /// A hidden tab must not stay selected (its page would strand
    /// the user on a view with no button back).
    private func clampTab() {
        if tab == 1 && !showRecordsTab { tab = 0 }
        if tab == 2 && !showLibraryTab { tab = 0 }
    }

    private func tabButton(index: Int, icon: String, label: String) -> some View {
        Button { Haptics.tap(); withAnimation(.easeInOut(duration: 0.2)) { tab = index } } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 19))
                Text(label).font(.system(size: 10))
            }
            .foregroundStyle(tab == index ? Theme.text : Theme.text.opacity(0.55))
            .frame(width: 62, height: 46)
            .background(tab == index ? Theme.text.opacity(0.14) : Color.clear, in: Capsule())
        }
    }
}
