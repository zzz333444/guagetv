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
    /// v2.12 bottom-bar settings: compact (icons only, no labels)
    /// and the floating search circle on/off. Search stays
    /// reachable from Discover's 跨线搜索 when the circle is off.
    @AppStorage("tabCompact.v1") private var compactTab = false
    @AppStorage("tabShowSearch") private var showSearchTab = true
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

    /// Deferred launch work (v2.03): the JarProxy warm call and the
    /// stale-line refresh used to run in onAppear, before the first
    /// frame — warmLine alone did a full config read + parse on the
    /// main thread. They now wait 1.5s, i.e. until after the shell
    /// is on screen and interactive.
    @State private var launchWorkDone = false

    private var colorScheme: ColorScheme? {
        switch themeMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    init() {
        // v2.03 startup: do NOT parse the active config here —
        // loadActive() reads the config file off disk and JSON-parses
        // 700+ sites, which used to block the first frame on the
        // main thread. The shell renders immediately with config
        // nil (every page tolerates that) and the config lands in
        // the .task below, parsed on a background thread.
        _config = State(initialValue: nil)
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
        .task {
            // v2.03: active config, parsed off the main thread.
            // Runs after the first frame, so the shell is already
            // interactive while the 700-site config parses.
            if config == nil {
                let cfg = await Task.detached(priority: .userInitiated) {
                    ConfigLibrary.loadActive()
                }.value
                config = cfg
            }
        }
        .onAppear {
            clampTab()
            if appLockEnabled { appLocked = true }
            guard !launchWorkDone else { return }
            launchWorkDone = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if let id = ConfigLibrary.activeID() { JarProxyClient.warmLine(id: id) }
                ConfigLibrary.refreshStaleEntries()
            }
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

    /// F4 (v1.56): four pages stay mounted in a ZStack and only
    /// visibility/hit-testing flips with `tab`, so switching tabs no
    /// longer destroys and rebuilds DiscoverView (its feed, scroll
    /// position and in-flight loads survive). Hidden pages get
    /// allowsHitTesting(false) so they cannot swallow touches.
    private var tabContent: some View {
        ZStack {
            DiscoverView(config: config)
                .opacity(tab == 0 ? 1 : 0)
                .allowsHitTesting(tab == 0)
            HistoryView()
                .opacity(tab == 1 ? 1 : 0)
                .allowsHitTesting(tab == 1)
            LibraryView(config: $config) { tab = 3 }
                .opacity(tab == 2 ? 1 : 0)
                .allowsHitTesting(tab == 2)
            SettingsView(config: $config)
                .opacity(tab == 3 ? 1 : 0)
                .allowsHitTesting(tab == 3)
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
            if showSearchTab {
                Button { showSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 52, height: 52)
                        .glassCircle()
                }
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

            if showSearchTab {
                Button { showSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 52, height: 52)
                        .glassCircle()
                }
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
            if compactTab {
                Image(systemName: icon).font(.system(size: 19))
                    .foregroundStyle(tab == index ? Theme.text : Theme.text.opacity(0.55))
                    .frame(width: 52, height: 40)
                    .background(tab == index ? Theme.text.opacity(0.14) : Color.clear, in: Capsule())
            } else {
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
}
