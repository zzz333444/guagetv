import SwiftUI

@main
struct GuageTVApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in SharedImportCenter.receive(url) }
        }
    }
}
