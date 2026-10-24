import SwiftUI
import BastionCore

@main
struct BastionApp: App {
    @StateObject private var settings = Settings.shared
    @StateObject private var tm = TabManager.shared
    @StateObject private var media = MediaStore.shared
    @StateObject private var stats = PrivacyStats.shared
    @StateObject private var shields = Shields.shared
    @StateObject private var library = Library.shared
    @Environment(\.scenePhase) private var phase

    init() {
        Shields.shared.start()
        Rumble.pageLoader = { url in await HeadlessFetch.shared.html(url) }
        WorldGlobeModel.shared.load()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings).environmentObject(tm).environmentObject(media)
                .environmentObject(stats).environmentObject(shields).environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(Theme.teal)
                .onOpenURL { url in
                    guard let tab = tm.current else { return }
                    if url.isFileURL, let text = try? String(contentsOf: url, encoding: .utf8), text.contains("<opml") { media.importOpml(text) }
                    else if url.scheme == "http" || url.scheme == "https" { tm.navigate(tab, url.absoluteString) }
                }
        }
        .onChange(of: phase) { p in if p == .background { stats.saveNow() } }
    }
}
