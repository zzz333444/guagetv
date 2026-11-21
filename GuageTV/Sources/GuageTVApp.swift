import SwiftUI

@main
struct GuageTVApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        SelfHeal.checkPreviousRun()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in SharedImportCenter.receive(url) }
        }
    }
}

/// AppDelegate (v1.49, S3): the only place UIKit delivers a
/// background URLSession's completion handler. It is forwarded
/// to DownloadManager, which calls it exactly once (then
/// clears it) from urlSessionDidFinishEventsForBackgroundURLSession.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadManager.shared.setBackgroundCompletionHandler(
            completionHandler, forSessionIdentifier: identifier)
    }
}

/// Crash self-heal (v1.42): a "session alive" flag is set at
/// launch and cleared when the app reaches the background (a
/// normal way to leave). If the flag is still set at the NEXT
/// launch, the previous session died in the foreground — most
/// likely a crash or a wedged spider. Recovery resets the
/// spider circuit breaker and drops cached spider code, and
/// the event is written to the diagnostics log so it is visible
/// instead of mysterious.
enum SelfHeal {
    private static let flagKey = "selfHeal.sessionAlive"

    static func checkPreviousRun() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: flagKey) {
            SpiderBridge.shared.resetBreaker()
            // v2.15 startup: the spiders-directory sweep used to run
            // on the main thread inside the App init, before the
            // first frame. It is pure cleanup — move it off-main.
            DispatchQueue.global(qos: .utility).async {
                let support = FileManager.default
                    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                let spiders = support.appendingPathComponent("spiders")
                if let names = try? FileManager.default.contentsOfDirectory(atPath: spiders.path) {
                    for name in names where name.hasSuffix(".meta") {
                        try? FileManager.default.removeItem(
                            at: spiders.appendingPathComponent(name))
                    }
                }
            }
            Diagnostics.log("自愈", "检测到上次异常退出，已重置蜘蛛熔断并刷新蜘蛛缓存")
        }
        defaults.set(true, forKey: flagKey)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            UserDefaults.standard.set(false, forKey: flagKey)
        }
    }
}
