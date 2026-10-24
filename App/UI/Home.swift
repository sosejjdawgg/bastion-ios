import SwiftUI
import BastionCore

/// The rearrangeable blocks of the home page. Built-ins are fixed; feed modules the user makes are "C:<id>".
enum HomeLayout {
    static let defaults = ["LIVE", "NEWSFEED", "GLOBE", "MEDIA", "STATS", "BOOKMARKS"]

    @MainActor
    static func order() -> [String] {
        let custom = MediaStore.shared.customModules.map { "C:\($0.id)" }
        let all = defaults + custom
        let saved = Settings.shared.homeOrder.filter { all.contains($0) }
        var out = saved.isEmpty ? defaults : saved
        for m in all where !out.contains(m) {
            if m == "NEWSFEED", let i = out.firstIndex(of: "MEDIA") { out.insert(m, at: i) }
            else if m.hasPrefix("C:"), let last = out.lastIndex(where: { feedId($0) != nil }) { out.insert(m, at: last + 1) }
            else { out.append(m) }
        }
        return out
    }

    @MainActor static func visible() -> [String] { order().filter { !Settings.shared.homeHidden.contains($0) } }

    static func feedId(_ key: String) -> String? {
        key == "NEWSFEED" ? FeedModule.NEWS : key == "MEDIA" ? FeedModule.MEDIA : key.hasPrefix("C:") ? String(key.dropFirst(2)) : nil
    }

    @MainActor static func title(_ key: String) -> String {
        if let id = feedId(key), let m = MediaStore.shared.module(id) { return m.title }
        return ["LIVE": "Live now", "GLOBE": "World events", "STATS": "This week", "BOOKMARKS": "Bookmarks"][key] ?? key
    }

    @MainActor static func color(_ key: String) -> Color {
        switch key {
        case "LIVE": return Theme.live
        case "GLOBE": return Theme.gold
        case "NEWSFEED": return Theme.news
        case "MEDIA": return Theme.teal
        case "STATS": return Theme.purple
        case "BOOKMARKS": return Color(hex: 0x8AA4BF)
        default: return feedId(key).flatMap { MediaStore.shared.module($0)?.color } ?? Theme.teal
        }
    }

    static func icon(_ key: String) -> String {
        ["LIVE": "play.fill", "GLOBE": "globe.europe.africa.fill", "NEWSFEED": "newspaper.fill", "MEDIA": "play.rectangle.on.rectangle.fill",
         "STATS": "shield.lefthalf.filled", "BOOKMARKS": "star.fill"][key] ?? "square.stack.fill"
    }

    static func previewHeight(_ key: String) -> CGFloat {
        ["LIVE": 26, "GLOBE": 42, "NEWSFEED": 54, "MEDIA": 44, "STATS": 16, "BOOKMARKS": 18][key] ?? 44
    }

    @MainActor static func summary(_ key: String) -> String {
        let media = MediaStore.shared
        switch key {
        case "LIVE": let c = media.channels.count; return c == 0 ? "No channels yet" : "\(media.liveNow.count)/\(c) live now"
        case "GLOBE": return "\(WorldGlobeModel.shared.clusters(.H24).count) hotspots in the last 24h"
        case "STATS": return "\(formatCount(PrivacyStats.shared.summary.weekTotal)) blocked this week"
        case "BOOKMARKS": return "\(Library.shared.bookmarks.count) saved"
        default:
            guard let id = feedId(key), let m = media.module(id) else { return "" }
            let n = media.outlets(in: m.section).count
            let new = media.items(in: m.section).filter { !media.readIds.contains($0.id) }.count
            let base = n == 0 ? "Empty — tap ⚙ on the module to add channels" : "\(n) \(id == FeedModule.NEWS ? "outlets" : "channels") · \(new) new"
            return base + (m.flare ? "" : " · not on globe")
        }
    }

    @MainActor static func save(_ order: [String]) { Settings.shared.homeOrder = order }
    @MainActor static func setHidden(_ key: String, _ hidden: Bool) {
        var h = Settings.shared.homeHidden
        h.removeAll { $0 == key }
        if hidden { h.append(key) }
        Settings.shared.homeHidden = h
    }
    @MainActor static func reset() { Settings.shared.homeOrder = []; Settings.shared.homeHidden = [] }
}

struct HomeView: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var tm: TabManager
    @EnvironmentObject var router: Router
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var media: MediaStore
    @EnvironmentObject var library: Library
    @EnvironmentObject var shields: Shields
    @EnvironmentObject var stats: PrivacyStats
    @State private var query = ""
    @State private var addChannel = false

    var body: some View {
        let accent = tab.isPrivate ? Theme.purple : Theme.teal
        ScrollView {
            LazyVStack(spacing: 0) {
                VStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(accent.opacity(0.14)).frame(width: 64, height: 64)
                        Image(systemName: tab.isPrivate ? "eyeglasses" : "shield.fill").font(.system(size: 28)).foregroundStyle(accent)
                    }
                    Text(tab.isPrivate ? "Private tab" : "Bastion").font(.largeTitle.weight(.bold)).foregroundStyle(Theme.text)
                    Text(tab.isPrivate ? "Nothing from this tab is kept. Cookies and storage vanish when you close it." : "Private search, ranked on your phone")
                        .font(.body).foregroundStyle(Theme.text.opacity(0.85)).multilineTextAlignment(.center)
                }
                .padding(.top, 36)

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(accent)
                    TextField("Search privately or type a URL", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.webSearch).submitLabel(.search)
                        .onSubmit { let q = query; query = ""; tm.openUserInput(tab, q) }
                        .foregroundStyle(Theme.text)
                }
                .padding(.horizontal, 18).frame(height: 54)
                .background(Capsule().fill(Theme.surface))
                .overlay(Capsule().stroke(Theme.outline, lineWidth: 1))
                .padding(.top, 26)

                if !tab.isPrivate && !library.queries.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(library.queries, id: \.self) { q in
                                HStack(spacing: 6) {
                                    Text(q).lineLimit(1).font(.subheadline)
                                    Button { library.removeQuery(q) } label: { Image(systemName: "xmark").font(.caption2) }.foregroundStyle(Theme.muted)
                                }
                                .padding(.horizontal, 12).frame(height: 32)
                                .overlay(Capsule().stroke(Theme.outline))
                                .contentShape(Capsule())
                                .onTapGesture { tm.search(tab, q) }
                            }
                        }
                    }.padding(.top, 14)
                }

                ForEach(HomeLayout.visible(), id: \.self) { key in
                    module(key).padding(.top, key == "LIVE" || key == "STATS" ? 24 : 20)
                }

                Button { router.sheet = .arrange } label: {
                    Label("Arrange home", systemImage: "square.grid.2x2").font(.subheadline).foregroundStyle(Theme.text)
                        .padding(.horizontal, 16).padding(.vertical, 8).overlay(Capsule().stroke(Theme.outline))
                }.padding(.top, 28)
                Text(shields.ready ? "\(formatCount(Int64(shields.ruleCount))) blocking rules active · no telemetry · no accounts" : shields.status)
                    .font(.caption2).foregroundStyle(Theme.muted).padding(.top, 14).padding(.bottom, 40)
            }
            .padding(.horizontal, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            await media.refresh(force: true)
            await media.checkLive(force: true)
        }
        .task {
            if settings.mediaAutoRefresh { await media.refresh(force: false) }
            await media.checkLive()
        }
        .sheet(isPresented: $addChannel) { AddSourceSheet(target: nil, liveFocus: true).environmentObject(media).preferredColorScheme(.dark) }
    }

    @ViewBuilder private func module(_ key: String) -> some View {
        switch key {
        case "LIVE": LiveNowSection(onAddChannel: { addChannel = true })
        case "GLOBE": WorldGlobe(tab: tab)
        case "NEWSFEED": NewsfeedView(tab: tab)
        case "MEDIA": FeedModuleView(tab: tab, moduleId: FeedModule.MEDIA)
        case "STATS": StatsCard()
        case "BOOKMARKS": if !tab.isPrivate && !library.bookmarks.isEmpty { BookmarksCard(tab: tab) }
        default: if let id = HomeLayout.feedId(key) { FeedModuleView(tab: tab, moduleId: id) }
        }
    }
}

struct StatsCard: View {
    @EnvironmentObject var stats: PrivacyStats
    @EnvironmentObject var router: Router
    var body: some View {
        let s = stats.summary
        Button { router.sheet = .report } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("This week").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    Text("Full report ›").font(.subheadline.weight(.medium)).foregroundStyle(Theme.teal)
                }
                HStack {
                    stat(formatCount(s.weekTotal), "trackers & ads\nblocked")
                    stat(formatCount(s.fingerprintAttempts), "fingerprint\nattempts")
                    stat(formatCount(s.httpsUpgrades), "HTTPS\nupgrades")
                }
                if let d = s.alerts.first(where: { $0.severity == .DANGER }) {
                    Label("\(d.title) · \(timeAgo(d.time))", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.danger)
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).card(20)
        }.buttonStyle(.plain)
    }
    private func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.title2.weight(.bold)).foregroundStyle(Theme.text)
            Text(l).font(.caption2).foregroundStyle(Theme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BookmarksCard: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var library: Library
    @EnvironmentObject var tm: TabManager
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bookmarks").font(.headline).foregroundStyle(Theme.text).padding(.bottom, 6)
            ForEach(library.bookmarks.prefix(6)) { b in
                Button { tm.navigate(tab, b.url) } label: {
                    HStack(spacing: 12) {
                        LetterAvatar(host: URLs.host(b.url) ?? b.url)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.title).lineLimit(1).font(.subheadline).foregroundStyle(Theme.text)
                            Text(URLs.host(b.url)?.removingPrefix("www.") ?? b.url).lineLimit(1).font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                    }.padding(.vertical, 6)
                }.buttonStyle(.plain)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The header shared by Newsfeed, Media and user-made modules.
struct ModuleHeader: View {
    let title: String
    var sub: String?
    var leading: AnyView? = nil
    let collapsed: Bool
    let onToggle: () -> Void
    let refreshing: Bool
    var onRefresh: (() -> Void)?
    let onAdd: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    if let leading { leading }
                    Text(title).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                    if let sub { Text(sub).font(.caption.weight(.medium)).foregroundStyle(Theme.muted).lineLimit(1) }
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if !collapsed, let onRefresh {
                if refreshing { ProgressView().controlSize(.small).frame(width: 36) }
                else { Button(action: onRefresh) { Image(systemName: "arrow.clockwise").foregroundStyle(Theme.muted).frame(width: 36, height: 36) } }
            }
            Button(action: onAdd) { Image(systemName: "plus").font(.body.weight(.semibold)).foregroundStyle(Theme.teal).frame(width: 36, height: 36) }
                .accessibilityLabel("Add source")
            Button(action: onSettings) { Image(systemName: "gearshape.fill").foregroundStyle(Theme.muted).frame(width: 36, height: 36) }
                .accessibilityLabel("Module settings")
        }
    }
}
