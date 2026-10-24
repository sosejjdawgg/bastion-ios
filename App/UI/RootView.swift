import SwiftUI
import WebKit
import BastionCore

enum Overlay: String, Identifiable { case tabs, report, controls, library, sources, arrange, webHistory, shield, address; var id: String { rawValue } }

/// Sheets and full-screen views shared across the app.
@MainActor
final class Router: ObservableObject {
    static let shared = Router()
    @Published var sheet: Overlay?
    @Published var reader: MediaItem?
    @Published var liveStart: String?
    @Published var episodesFor: MediaSource?
    @Published var shareURL: URL?
    @Published var manageModule: String?
}

struct RootView: View {
    @EnvironmentObject var tm: TabManager
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var stats: PrivacyStats
    @StateObject private var router = Router.shared

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if let tab = tm.current { TabScreen(tab: tab).id(tab.id) }
        }
        .environmentObject(router)
        .sheet(item: $router.sheet) { o in
            Group {
                switch o {
                case .tabs: TabsScreen()
                case .report: ReportScreen()
                case .controls: ControlsScreen()
                case .library: LibraryScreen()
                case .sources: SourcesScreen()
                case .arrange: ArrangeHomeScreen()
                case .webHistory: if let t = tm.current { WebHistorySheet(tab: t) }
                case .shield: if let t = tm.current { ShieldSheet(tab: t) }
                case .address: if let t = tm.current { AddressEditor(tab: t) }
                }
            }
            .environmentObject(router).environmentObject(tm).environmentObject(settings).environmentObject(stats)
            .environmentObject(MediaStore.shared).environmentObject(Shields.shared).environmentObject(Library.shared)
            .preferredColorScheme(.dark)
        }
        .fullScreenCover(item: $router.reader) { item in
            ReaderScreen(item: item).environmentObject(router).environmentObject(settings).environmentObject(tm).preferredColorScheme(.dark)
        }
        .fullScreenCover(item: Binding(get: { router.liveStart.map { LiveStart(id: $0) } }, set: { router.liveStart = $0?.id })) { s in
            LiveViewer(startId: s.id).environmentObject(router).environmentObject(MediaStore.shared).environmentObject(tm).preferredColorScheme(.dark)
        }
        .fullScreenCover(item: $router.episodesFor) { src in
            EpisodesScreen(source: src).environmentObject(router).environmentObject(tm).environmentObject(settings).preferredColorScheme(.dark)
        }
        .sheet(item: Binding(get: { router.shareURL.map { ShareItem(url: $0) } }, set: { router.shareURL = $0?.url })) { s in ShareSheet(items: [s.url]) }
    }
}

struct LiveStart: Identifiable { let id: String }
struct ShareItem: Identifiable { let url: URL; var id: String { url.absoluteString } }

/// Opens a media item the right way: reader view for articles (when on), the browser for videos and pages.
@MainActor
func openMediaItem(_ item: MediaItem, tab: BrowserTab) {
    if !tab.isPrivate { MediaStore.shared.markRead(item) }
    if item.type == .ARTICLE && Settings.shared.mediaReader { Router.shared.reader = item } else { TabManager.shared.navigate(tab, item.url) }
}

struct TabScreen: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var tm: TabManager
    @EnvironmentObject var router: Router
    @EnvironmentObject var stats: PrivacyStats

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                switch tab.content {
                case .home: HomeView(tab: tab)
                case .results: ResultsView(tab: tab)
                case .web:
                    if let wv = tab.webView {
                        VStack(spacing: 0) {
                            if tab.noticeDismissedFor != tab.url { RedirectNotice(tab: tab) }
                            if Wayback.isArchived(tab.url) { ArchiveBanner(tab: tab) }
                            WebViewHost(webView: wv).ignoresSafeArea(.container, edges: .bottom)
                        }
                    }
                }
                if let a = stats.liveAlert, a.tab == tab.id { AlertToast(alert: a.alert) { stats.liveAlert = nil }.padding(.top, 8).transition(.move(edge: .top).combined(with: .opacity)) }
            }
            .frame(maxHeight: .infinity)
            BottomBar(tab: tab)
        }
        .animation(.spring(response: 0.35), value: stats.liveAlert?.alert.id)
        .background(Theme.bg)
    }
}

struct AlertToast: View {
    let alert: PrivacyAlert
    let dismiss: () -> Void
    @EnvironmentObject var router: Router
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: alert.severity == .DANGER ? "exclamationmark.octagon.fill" : alert.severity == .WARNING ? "exclamationmark.triangle.fill" : "shield.lefthalf.filled")
                .foregroundStyle(severityColor(alert.severity))
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                Text(alert.detail).font(.caption).foregroundStyle(Theme.muted).lineLimit(3)
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: { Image(systemName: "xmark").font(.caption).foregroundStyle(Theme.muted) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surfaceHighest).shadow(radius: 12))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(severityColor(alert.severity).opacity(0.5), lineWidth: 1))
        .padding(.horizontal, 12)
        .onTapGesture { dismiss(); router.sheet = .report }
        .task(id: alert.id) { try? await Task.sleep(nanoseconds: 5_000_000_000); dismiss() }
    }
}

// MARK: - Bottom bar

struct BottomBar: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var tm: TabManager
    @EnvironmentObject var router: Router
    @EnvironmentObject var stats: PrivacyStats
    @EnvironmentObject var library: Library

    var body: some View {
        let accent = tab.isPrivate ? Theme.purple : Theme.teal
        VStack(spacing: 0) {
            if tab.content == .web && tab.loading {
                GeometryReader { g in Rectangle().fill(accent).frame(width: g.size.width * tab.progress) }.frame(height: 2)
            } else { Divider().overlay(Theme.outlineVariant) }
            if tab.content != .home {
                HStack(spacing: 8) {
                    shieldButton(accent)
                    Button { router.sheet = .address } label: {
                        HStack(spacing: 6) {
                            if tab.content == .web && tab.url.hasPrefix("https") { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(Theme.muted) }
                            Text(tab.content == .results ? tab.query : (URLs.host(tab.url)?.removingPrefix("www.") ?? tab.url))
                                .font(.subheadline).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14).frame(height: 40)
                        .background(Capsule().fill(Theme.surfaceHigh))
                    }.buttonStyle(.plain)
                    if tab.content == .web {
                        Button { tab.loading ? tm.stop(tab) : tm.reload(tab) } label: {
                            Image(systemName: tab.loading ? "xmark" : "arrow.clockwise").foregroundStyle(Theme.muted).frame(width: 36, height: 40)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
            HStack {
                bar("chevron.left", enabled: tab.content != .home) { tm.goBack(tab) }
                bar("chevron.right", enabled: tab.canGoForward && tab.content == .web) { tm.goForward(tab) }
                bar("house", enabled: tab.content != .home) { tm.goHome(tab) }
                Button { router.sheet = .tabs } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5).stroke(tab.isPrivate ? Theme.purple : Theme.text, lineWidth: 1.6).frame(width: 22, height: 22)
                        Text("\(tm.tabs.count)").font(.caption2.weight(.bold)).foregroundStyle(tab.isPrivate ? Theme.purple : Theme.text)
                    }.frame(maxWidth: .infinity, minHeight: 44)
                }
                Menu {
                    Button { tm.newTab(isPrivate: false) } label: { Label("New tab", systemImage: "plus.square") }
                    Button { tm.newTab(isPrivate: true) } label: { Label("New private tab", systemImage: "eyeglasses") }
                    if tab.content == .web {
                        Divider()
                        Button { library.toggleBookmark(tab.url, tab.title) } label: {
                            Label(library.isBookmarked(tab.url) ? "Remove bookmark" : "Bookmark", systemImage: library.isBookmarked(tab.url) ? "star.slash" : "star")
                        }
                        Button { router.sheet = .webHistory } label: { Label("Web history", systemImage: "clock.arrow.circlepath") }
                        Button { if let u = URL(string: Wayback.isArchived(tab.url) ? Wayback.originalUrl(tab.url) : tab.url) { router.shareURL = u } } label: { Label("Share page", systemImage: "square.and.arrow.up") }
                    }
                    Divider()
                    Button { router.sheet = .report } label: { Label("Privacy report", systemImage: "chart.bar.xaxis") }
                    Button { router.sheet = .library } label: { Label("History & bookmarks", systemImage: "book") }
                    Button { router.sheet = .controls } label: { Label("Controls", systemImage: "slider.horizontal.3") }
                    if tm.tabs.contains(where: \.isPrivate) {
                        Button(role: .destructive) { tm.closeAllPrivate() } label: { Label("Close private tabs", systemImage: "xmark.circle") }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text).frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .padding(.horizontal, 8)
        }
        .background(Theme.bg.opacity(0.98))
    }

    private func shieldButton(_ accent: Color) -> some View {
        let snap = stats.page(tab.id)
        let n = snap?.blockedCount ?? 0
        return Button { router.sheet = .shield } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 20)).foregroundStyle(snap.map { gradeColor($0.grade) } ?? accent)
                    .frame(width: 36, height: 40)
                if n > 0 {
                    Text(n > 99 ? "99+" : "\(n)").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.bg)
                        .padding(.horizontal, 4).padding(.vertical, 1).background(Capsule().fill(accent)).offset(x: 2, y: 2)
                }
            }
        }
    }

    private func bar(_ icon: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18, weight: .medium)).foregroundStyle(enabled ? Theme.text : Theme.muted.opacity(0.4))
                .frame(maxWidth: .infinity, minHeight: 44)
        }.disabled(!enabled)
    }
}

// MARK: - Address editor

struct AddressEditor: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var tm: TabManager
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Search privately or type a URL", text: $text)
                        .focused($focused).keyboardType(.webSearch).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.go).onSubmit { go(text) }
                }
                let q = text.trimmed.lowercased()
                let matches = library.history.filter { q.isEmpty || $0.url.lowercased().contains(q) || $0.title.lowercased().contains(q) }.prefix(6)
                let queries = library.queries.filter { q.isEmpty || $0.lowercased().contains(q) }.prefix(5)
                if !queries.isEmpty || (!q.isEmpty && !tm.looksLikeUrl(text.trimmed)) {
                    Section("Search") {
                        if !q.isEmpty && !tm.looksLikeUrl(text.trimmed) {
                            Button { go(text) } label: { Label("Search “\(text.trimmed)”", systemImage: "magnifyingglass") }
                        }
                        ForEach(Array(queries), id: \.self) { s in Button { go(s) } label: { Label(s, systemImage: "clock") } }
                    }
                }
                if !matches.isEmpty && !tab.isPrivate {
                    Section("History") {
                        ForEach(Array(matches)) { h in
                            Button { go(h.url) } label: {
                                VStack(alignment: .leading) {
                                    Text(h.title.nilIfBlank ?? h.url).lineLimit(1).foregroundStyle(Theme.text)
                                    Text(h.url).font(.caption).lineLimit(1).foregroundStyle(Theme.muted)
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Theme.bg)
            .navigationTitle(tab.isPrivate ? "Private" : "Go to").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .onAppear { text = tab.content == .results ? tab.query : (tab.content == .web ? (Wayback.isArchived(tab.url) ? Wayback.originalUrl(tab.url) : tab.url) : ""); focused = true }
        .presentationDetents([.large])
    }

    private func go(_ s: String) { dismiss(); tm.openUserInput(tab, s) }
}
