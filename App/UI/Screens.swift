import SwiftUI
import WebKit
import UniformTypeIdentifiers
import BastionCore

// MARK: - Tabs

struct TabsScreen: View {
    @EnvironmentObject var tm: TabManager
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(tm.tabs) { t in TabTile(tab: t, selected: t.id == tm.currentId) { tm.select(t); dismiss() } close: { tm.close(t) } }
                }.padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("\(tm.tabs.count) tabs").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .bottomBar) { Button { tm.newTab(isPrivate: true); dismiss() } label: { Label("Private", systemImage: "eyeglasses") }.tint(Theme.purple) }
                ToolbarItem(placement: .bottomBar) { Button { tm.newTab(isPrivate: false); dismiss() } label: { Label("New tab", systemImage: "plus") } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct TabTile: View {
    @ObservedObject var tab: BrowserTab
    let selected: Bool
    let open: () -> Void
    let close: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if tab.isPrivate { Image(systemName: "eyeglasses").foregroundStyle(Theme.purple) }
                    Text(tab.displayTitle).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(2)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Theme.muted).padding(6) }
                }
                Spacer()
                HStack {
                    if tab.content == .web, let h = URLs.host(tab.url) { LetterAvatar(host: h, size: 24) }
                    Text(tab.content == .home ? "Home" : tab.content == .results ? "Search" : (URLs.host(tab.url)?.removingPrefix("www.") ?? ""))
                        .font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .padding(12).frame(height: 140).frame(maxWidth: .infinity)
            .card(16, color: tab.isPrivate ? Theme.purple.opacity(0.12) : Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? (tab.isPrivate ? Theme.purple : Theme.teal) : .clear, lineWidth: 2))
        }.buttonStyle(.plain)
    }
}

// MARK: - Privacy report

struct ReportScreen: View {
    @EnvironmentObject var stats: PrivacyStats
    @Environment(\.dismiss) var dismiss
    @State private var confirmReset = false

    var body: some View {
        let s = stats.summary
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Blocked since \(Date(timeIntervalSince1970: Double(s.since) / 1000).formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(Theme.muted)
                        Text(formatCount(s.totalBlocked)).font(.system(size: 44, weight: .bold)).foregroundStyle(Theme.teal)
                        Text("ads, trackers and threats stopped before they loaded").font(.caption).foregroundStyle(Theme.muted)
                        DayBars(days: s.last7Days).padding(.top, 10)
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).card(20)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("By category").font(.headline).foregroundStyle(Theme.text)
                        let maxC = max(1, s.byCategory.map(\.1).max() ?? 1)
                        ForEach(s.byCategory, id: \.0) { cat, n in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Circle().fill(Color(hex: cat.color)).frame(width: 8, height: 8)
                                    Text(cat.label).font(.subheadline).foregroundStyle(Theme.text)
                                    Spacer()
                                    Text(formatCount(n)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                }
                                GeometryReader { g in Capsule().fill(Color(hex: cat.color)).frame(width: max(4, g.size.width * CGFloat(n) / CGFloat(maxC))) }.frame(height: 4)
                                Text(cat.blurb).font(.caption2).foregroundStyle(Theme.muted)
                            }
                        }
                    }.padding(18).card(20)

                    if !s.topCompanies.isEmpty { RankCard(title: "Top tracking companies", rows: s.topCompanies) }
                    if !s.topSites.isEmpty { RankCard(title: "Sites that tracked you most", rows: s.topSites) }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Other protections").font(.headline).foregroundStyle(Theme.text)
                        prot("HTTPS upgrades", s.httpsUpgrades, "Insecure links switched to encrypted connections")
                        prot("Tracking parameters removed", s.paramsStripped, "utm_, fbclid, gclid and similar stripped from links")
                        prot("Fingerprinting attempts", s.fingerprintAttempts, "Canvas, WebGL, audio and font probing detected")
                        prot("Permission requests denied", s.permissionsDenied, "Camera and microphone requests")
                        prot("YouTube ads removed or skipped", s.youtubeAds, "Stripped from page data, or skipped in the player")
                        prot("Ad-blocker walls removed", s.wallsRemoved, "Anti-adblock pop-ups taken down")
                        prot("Ad containers hidden", s.cosmeticHidden, "Leftover ad boxes hidden by element-hiding rules")
                    }.padding(18).card(20)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Alerts").font(.headline).foregroundStyle(Theme.text)
                            Spacer()
                            if !s.alerts.isEmpty { Button("Clear") { stats.clearAlerts() } }
                        }
                        if s.alerts.isEmpty { Text("No alerts yet. You'll see malware blocks, fingerprinting attempts and heavy trackers here.").font(.caption).foregroundStyle(Theme.muted) }
                        ForEach(s.alerts.prefix(40)) { a in
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(severityColor(a.severity)).frame(width: 8, height: 8).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                    Text(a.detail).font(.caption).foregroundStyle(Theme.muted)
                                    Text(timeAgo(a.time)).font(.caption2).foregroundStyle(Theme.muted)
                                }
                            }
                        }
                    }.padding(18).card(20)

                    Button("Reset statistics", role: .destructive) { confirmReset = true }.frame(maxWidth: .infinity).buttonStyle(.bordered)
                }.padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("Privacy report").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Reset statistics?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { stats.reset() }
            } message: { Text("Counters, breakdowns and alerts will be deleted from this phone.") }
        }
    }

    private func prot(_ label: String, _ n: Int64, _ sub: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline).foregroundStyle(Theme.text)
                Text(sub).font(.caption2).foregroundStyle(Theme.muted)
            }
            Spacer()
            Text(formatCount(n)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
        }
    }
}

struct DayBars: View {
    let days: [(String, Int64)]
    var body: some View {
        let maxV = max(1, days.map(\.1).max() ?? 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(days, id: \.0) { d, v in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.teal.opacity(v == 0 ? 0.2 : 0.85)).frame(height: max(4, 60 * CGFloat(v) / CGFloat(maxV)))
                    Text(String(d.suffix(2))).font(.caption2).foregroundStyle(Theme.muted)
                }.frame(maxWidth: .infinity)
            }
        }.frame(height: 80)
    }
}

struct RankCard: View {
    let title: String
    let rows: [(String, Int64)]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(Theme.text)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                HStack {
                    Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(Theme.muted).frame(width: 20, alignment: .leading)
                    Text(r.0).font(.subheadline).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    Text(formatCount(r.1)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).card(20)
    }
}

// MARK: - Controls

struct ControlsScreen: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var shields: Shields
    @EnvironmentObject var tm: TabManager
    @EnvironmentObject var library: Library
    @EnvironmentObject var stats: PrivacyStats
    @EnvironmentObject var media: MediaStore
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) var dismiss
    @State private var tabSel = 0
    @State private var updating = false
    @State private var updateNote: String?
    @State private var confirmErase = false
    @State private var siteData: [WKWebsiteDataRecord] = []
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Picker("", selection: $tabSel) { Text("Protection").tag(0); Text("Data").tag(1); Text("Search").tag(2) }.pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                switch tabSel {
                case 0: protection
                case 1: data
                default: search
                }
            }
            .scrollContentBackground(.hidden).background(Theme.bg)
            .navigationTitle("Controls").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: Binding(get: { exportURL.map { ShareItem(url: $0) } }, set: { exportURL = $0?.url })) { ShareSheet(items: [$0.url]) }
        }
    }

    @ViewBuilder private var protection: some View {
        Section {
            Picker("Blocking", selection: Binding(get: { settings.blockLevel }, set: { settings.blockLevel = $0; shields.rebuild() })) {
                Text("Off").tag(BlockLevel.OFF); Text("Balanced").tag(BlockLevel.BALANCED); Text("Strict").tag(BlockLevel.STRICT)
            }.pickerStyle(.segmented)
            Text(settings.blockLevel == .OFF ? "Only malware and scam hosts are blocked." :
                 settings.blockLevel == .BALANCED ? "Ads, trackers, fingerprinters, cryptominers and malware. Social widgets still load." :
                    "Everything in Balanced, plus social trackers and stronger fingerprint noise. Some sites may break.")
                .font(.caption).foregroundStyle(Theme.muted)
            if shields.preparing { HStack { ProgressView().controlSize(.small); Text(shields.status).font(.caption) } }
        } header: { Text("Tracker blocking") }

        Section("Protections") {
            ToggleRow(title: "HTTPS-only", sub: "Upgrade every connection; warn before falling back to HTTP", on: $settings.httpsOnly)
            ToggleRow(title: "Strip tracking parameters", sub: "Remove utm_, fbclid, gclid and 40+ others from links", on: $settings.stripParams)
            ToggleRow(title: "Fingerprinting protection", sub: "Detect and add noise to canvas, WebGL and audio fingerprints",
                      on: Binding(get: { settings.fingerprint }, set: { settings.fingerprint = $0; tm.refreshProtections() }))
            ToggleRow(title: "Global Privacy Control", sub: "Tell sites not to sell or share your data (legally binding in some regions)",
                      on: Binding(get: { settings.gpc }, set: { settings.gpc = $0; tm.refreshProtections() }))
            ToggleRow(title: "JavaScript", sub: "Turning off makes many sites break but removes most tracking", on: $settings.javascript)
            Text("Third-party cookies are blocked by WebKit's Intelligent Tracking Prevention, which is always on in Bastion.").font(.caption).foregroundStyle(Theme.muted)
        }

        Section {
            ToggleRow(title: "YouTube shield", sub: "Strips ads from YouTube's page data, removes the ad-blocker wall and skips any ad that slips through",
                      on: Binding(get: { settings.youtubeShield }, set: { settings.youtubeShield = $0; tm.refreshProtections() }))
        } header: { Text("YouTube & video ads") } footer: { Text("Watch YouTube in Bastion for ad-free playback.") }

        Section("Alerts") {
            ToggleRow(title: "Show privacy alerts", sub: "Malware blocks, fingerprinting attempts and permission requests", on: $settings.alertsEnabled)
            ToggleRow(title: "Warn about heavy tracking", sub: "When a page tries to load 15+ tracking domains", on: $settings.alertHeavy)
        }

        Section {
            if settings.allowlist.isEmpty { Text("None. Turn shields off for a site from the shield button while browsing.").font(.caption).foregroundStyle(Theme.muted) }
            ForEach(settings.allowlist, id: \.self) { d in
                HStack { Text(d); Spacer(); Button("Remove") { settings.setAllowlisted(d, false); tm.refreshProtections() }.font(.caption) }
            }
        } header: { Text("Sites with shields down") } footer: { Text("Trackers are allowed on these sites (malware is still blocked).") }

        Section {
            ForEach(shields.set.statuses) { l in
                HStack { Text(l.name).font(.subheadline); Spacer(); Text("\(formatCount(Int64(l.rules))) · \(l.source)").font(.caption).foregroundStyle(Theme.muted) }
            }
            Button {
                updating = true
                Task { updateNote = await shields.updateLists(); updating = false }
            } label: { HStack { if updating { ProgressView().controlSize(.small) }; Text(updating ? "Updating…" : "Update filter lists now") } }.disabled(updating)
            if let updateNote { Text(updateNote).font(.caption).foregroundStyle(Theme.muted) }
        } header: { Text("Filter lists · \(formatCount(Int64(shields.ruleCount))) rules") } footer: {
            Text("\(formatCount(Int64(shields.safariRules))) of them compiled into Safari content rules. " +
                 (settings.listsUpdatedAt > 0 ? "Last updated \(timeAgo(Int64(settings.listsUpdatedAt * 1000)))." : "Using the lists bundled with the app."))
        }
    }

    @ViewBuilder private var data: some View {
        Section {
            inventory("clock", "Browsing history", "\(library.history.count) pages", "Clear") { library.clearHistory() }
            inventory("magnifyingglass", "Recent searches", "\(library.queries.count) queries", "Clear") { for q in library.queries { library.removeQuery(q) } }
            inventory("star", "Bookmarks", "\(library.bookmarks.count) saved", "View") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { router.sheet = .library } }
            inventory("internaldrive", "Cookies & site data", "\(siteData.count) sites", "Clear") {
                WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { loadSiteData() }
            }
            inventory("shield.lefthalf.filled", "Privacy statistics & alerts", "\(formatCount(stats.summary.totalBlocked)) blocks · \(stats.summary.alerts.count) alerts", "Reset") { stats.reset() }
            inventory("newspaper", "Media sources & headlines", "\(media.sources.count) sources · \(media.items.count) items", "Manage") {
                dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { router.sheet = .sources }
            }
            inventory("key", "Passwords & form data", "Never saved by Bastion", nil) {}
        } header: { Text("Everything below lives only on this phone.") }

        if !siteData.isEmpty {
            Section("Sites storing data") {
                ForEach(siteData.prefix(40), id: \.displayName) { r in
                    HStack {
                        Text(r.displayName).font(.subheadline)
                        Spacer()
                        Button { WKWebsiteDataStore.default().removeData(ofTypes: r.dataTypes, for: [r]) { loadSiteData() } } label: { Image(systemName: "trash") }.foregroundStyle(Theme.danger)
                    }
                }
            }
        }

        Section {
            Text("Bastion never sends analytics, crash reports, ads, accounts or anything to developer servers.").font(.caption).foregroundStyle(Theme.muted)
            Button { exportURL = exportData() } label: { Label("Export my data (JSON)", systemImage: "square.and.arrow.up") }
            Button { exportURL = exportOpml() } label: { Label("Export media sources (OPML)", systemImage: "square.and.arrow.up") }
            Button(role: .destructive) { confirmErase = true } label: { Label("Erase everything", systemImage: "trash") }
        }
        .onAppear(perform: loadSiteData)
        .confirmationDialog("Erase everything?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase", role: .destructive) { eraseEverything() }
        } message: { Text("History, searches, bookmarks, cookies, site storage, cache, statistics, alerts, media sources and per-site exceptions will be permanently deleted from this phone. Settings are kept.") }
    }

    @ViewBuilder private var search: some View {
        Section {
            ToggleRow(title: "DuckDuckGo", sub: "No-JavaScript HTML results. Sponsored results are removed.", on: $settings.srcDdg)
            ToggleRow(title: "Mojeek", sub: "Independent UK crawler with its own index and no tracking", on: $settings.srcMojeek)
            ToggleRow(title: "Wikipedia", sub: "Official API for encyclopedia results", on: $settings.srcWiki)
        } header: { Text("Search sources") } footer: { Text("Queried in parallel from your phone, merged and ranked locally.") }
        Section("How ranking works") {
            Text("Each result scores by its position in each source (weighted), gets a bonus when several independent sources agree, and a boost for matching your words. Known ad and malware domains are pushed down. Everything happens on this phone; no search history leaves it.")
                .font(.caption).foregroundStyle(Theme.muted)
        }
        Section("Media") {
            ToggleRow(title: "Open articles in reader view", sub: "Just the text — no ads, scripts or pop-ups", on: $settings.mediaReader)
            ToggleRow(title: "Show thumbnails", sub: "Loaded straight from the publisher, without cookies", on: $settings.mediaThumbnails)
            ToggleRow(title: "Hide YouTube Shorts", sub: "Keep channel feeds to full videos", on: $settings.mediaHideShorts)
            ToggleRow(title: "Refresh when opening the home page", sub: "Only sources older than 20 minutes; pull down to refresh everything", on: $settings.mediaAutoRefresh)
        }
    }

    private func inventory(_ icon: String, _ title: String, _ value: String, _ action: String?, _ run: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.teal).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.text)
                Text(value).font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            if let action { Button(action, action: run).font(.subheadline.weight(.medium)).buttonStyle(.borderless) }
        }
    }

    private func loadSiteData() {
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { r in siteData = r.sorted { $0.displayName < $1.displayName } }
    }

    private func exportData() -> URL? {
        let o: [String: Any] = [
            "exported": ISO8601DateFormatter().string(from: Date()),
            "history": library.history.map { ["url": $0.url, "title": $0.title, "time": $0.time] },
            "bookmarks": library.bookmarks.map { ["url": $0.url, "title": $0.title] },
            "searches": library.queries,
            "allowlist": settings.allowlist,
            "privacy": stats.exportJSON(),
            "media": ["sources": media.sources.map { ["name": $0.name, "feed": $0.feedUrl, "site": $0.siteUrl, "kind": $0.kind.rawValue, "section": $0.section ?? ""] },
                      "modules": media.modules.map { ["id": $0.id, "title": $0.title, "flare": $0.flare] }]
        ]
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("bastion-data.json")
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted]) else { return nil }
        try? d.write(to: u)
        return u
    }

    private func exportOpml() -> URL? {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("bastion-sources.opml")
        try? media.exportOpml().write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    private func eraseEverything() {
        library.clearAll()
        stats.reset()
        media.clearAll()
        settings.allowlist = []
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { loadSiteData() }
        URLCache.shared.removeAllCachedResponses()
        tm.closeAllPrivate()
        for t in tm.tabs { t.webView?.loadHTMLString("", baseURL: nil); t.content = .home }
    }
}

// MARK: - Library

struct LibraryScreen: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var tm: TabManager
    @Environment(\.dismiss) var dismiss
    @State private var sel = 0
    @State private var q = ""
    var body: some View {
        NavigationStack {
            List {
                Picker("", selection: $sel) { Text("History").tag(0); Text("Bookmarks").tag(1) }.pickerStyle(.segmented).listRowBackground(Color.clear)
                if sel == 0 {
                    let rows = library.history.filter { q.isBlank || $0.title.localizedCaseInsensitiveContains(q) || $0.url.localizedCaseInsensitiveContains(q) }
                    if rows.isEmpty { Text("Nothing here yet.").foregroundStyle(Theme.muted) }
                    ForEach(rows.prefix(300)) { h in
                        row(h.title, h.url, timeAgo(h.time)).swipeActions { Button(role: .destructive) { library.removeHistory(h) } label: { Label("Delete", systemImage: "trash") } }
                    }
                } else {
                    if library.bookmarks.isEmpty { Text("Bookmark pages from the ⋯ menu.").foregroundStyle(Theme.muted) }
                    ForEach(library.bookmarks) { b in
                        row(b.title, b.url, "").swipeActions { Button(role: .destructive) { library.removeBookmark(b) } label: { Label("Delete", systemImage: "trash") } }
                    }
                }
            }
            .searchable(text: $q)
            .scrollContentBackground(.hidden).background(Theme.bg)
            .navigationTitle("Library").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private func row(_ title: String, _ url: String, _ meta: String) -> some View {
        Button { dismiss(); if let t = tm.current { tm.navigate(t, url) } } label: {
            HStack(spacing: 12) {
                LetterAvatar(host: URLs.host(url) ?? url, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.nilIfBlank ?? url).lineLimit(1).foregroundStyle(Theme.text)
                    Text((URLs.host(url)?.removingPrefix("www.") ?? url) + (meta.isEmpty ? "" : " · \(meta)")).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Sources

struct SourcesScreen: View {
    @EnvironmentObject var media: MediaStore
    @Environment(\.dismiss) var dismiss
    @State private var editing: MediaSource?
    @State private var adding = false
    @State private var importing = false
    @State private var exportURL: URL?
    @State private var note: String?

    var body: some View {
        NavigationStack {
            List {
                if media.sources.isEmpty { Text("No sources yet.").foregroundStyle(Theme.muted) }
                ForEach(media.modules) { m in
                    ModuleSourcesSection(module: m) { editing = $0 }
                }
                Section {
                    Button { importing = true } label: { Label("Import OPML", systemImage: "square.and.arrow.down") }
                    Button { let u = FileManager.default.temporaryDirectory.appendingPathComponent("bastion-sources.opml"); try? media.exportOpml().write(to: u, atomically: true, encoding: .utf8); exportURL = u } label: {
                        Label("Export OPML", systemImage: "square.and.arrow.up")
                    }.disabled(media.sources.isEmpty)
                    if let note { Text(note).font(.caption).foregroundStyle(Theme.muted) }
                } footer: { Text("Sources and headlines are stored only on this phone. Each source is fetched directly from its publisher, without cookies, at most three at a time.") }
            }
            .scrollContentBackground(.hidden).background(Theme.bg)
            .navigationTitle("Sources").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { adding = true } label: { Image(systemName: "plus") } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $editing) { s in SourceSheet(sourceId: s.id).environmentObject(media).preferredColorScheme(.dark) }
            .sheet(isPresented: $adding) { AddSourceSheet(target: nil).environmentObject(media).preferredColorScheme(.dark) }
            .sheet(item: Binding(get: { exportURL.map { ShareItem(url: $0) } }, set: { exportURL = $0?.url })) { ShareSheet(items: [$0.url]) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.xml, .data, .text]) { r in
                guard case .success(let url) = r else { return }
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    let n = media.importOpml(text)
                    note = n == 0 ? "No new sources found in that file." : "Added \(n) sources. They'll fill in on the next refresh."
                    Task { await media.refresh(force: false) }
                }
            }
        }
    }
}

/// One module's sources in the Sources screen.
struct ModuleSourcesSection: View {
    let module: FeedModule
    let edit: (MediaSource) -> Void
    @EnvironmentObject var media: MediaStore

    var body: some View {
        let group: [MediaSource] = media.sources.filter { media.section(of: $0.id) == module.section }
        if !group.isEmpty {
            Section(header: Text(header(group.count))) {
                ForEach(group) { s in SourceRow(source: s) { edit(s) } }
            }
        }
    }

    private func header(_ n: Int) -> String {
        if module.id == FeedModule.NEWS { return module.title + " · \(media.sectionOutlets(module.section).count) outlets" }
        return module.title + " · \(n) channels"
    }
}

struct SourceRow: View {
    let source: MediaSource
    let open: () -> Void
    @EnvironmentObject var media: MediaStore

    var body: some View {
        Button(action: open) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1).foregroundStyle(source.enabled ? Theme.text : Theme.muted)
                    Text(detail).font(.caption).foregroundStyle(source.lastError != nil ? Theme.warn : Theme.muted)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { source.enabled }, set: { media.setEnabled(source.id, $0) })).labelsHidden().tint(Theme.teal)
            }
        }
    }

    private var title: String {
        guard let o = media.outlet(of: source.id), o.sourceIds.count > 1 else { return source.name }
        return source.name + "  ·  " + o.name
    }

    private var detail: String {
        let n = media.items.filter { $0.sourceId == source.id }.count
        var d = "\(source.kind.label) · \(n) items"
        if source.lastFetched > 0 { d += " · " + timeAgo(source.lastFetched) }
        if let e = source.lastError { d += " · " + e }
        return d
    }
}

struct SourceSheet: View {
    let sourceId: String
    @EnvironmentObject var media: MediaStore
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var confirmDelete = false

    var body: some View {
        if let s = media.source(sourceId) {
            NavigationStack {
                Form {
                    Section {
                        TextField("Name", text: $name)
                        Text(s.lastFetched == 0 ? "Not fetched yet" : "Updated \(timeAgo(s.lastFetched))" + (s.lastError.map { " · \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(s.lastError != nil ? Theme.warn : Theme.muted)
                    } header: { Text(s.kind.label + " · " + (URLs.host(s.siteUrl)?.removingPrefix("www.") ?? s.siteUrl)) }

                    Section("Appears in") {
                        let autoSec = autoSection(s)
                        let opts: [(String?, String)] = [(nil, "Auto · " + (autoSec == .NEWS ? media.news.title : media.media.title))] + media.modules.map { ($0.section.key, $0.title) }
                        FlowLayout(spacing: 6) {
                            ForEach(Array(opts.enumerated()), id: \.offset) { _, o in
                                QuickChip(label: o.1, selected: s.section == o.0) { media.setSection(s.id, o.0) }
                            }
                        }.padding(.vertical, 4)
                    }

                    if let o = media.outlet(of: s.id), o.sourceIds.count > 1 || s.group == "solo" {
                        Section {
                            Toggle(isOn: Binding(get: { s.group != "solo" }, set: { media.setGroup(s.id, $0 ? nil : "solo") })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Merged with " + (s.group == "solo" ? "nothing" : o.sourceIds.filter { $0 != s.id }.compactMap { media.source($0)?.kind.label }.joined(separator: ", ")))
                                    Text("Its site and channels show as one outlet, \(o.name).").font(.caption).foregroundStyle(Theme.muted)
                                }
                            }.tint(Theme.teal)
                        }
                    }

                    Section {
                        Toggle("Show on home", isOn: Binding(get: { s.enabled }, set: { media.setEnabled(s.id, $0) })).tint(Theme.teal)
                        Button { Task { await media.refresh(force: true, only: s.id) } } label: { Label("Refresh now", systemImage: "arrow.clockwise") }
                        HStack {
                            Button { media.move(s.id, -1) } label: { Label("Earlier", systemImage: "arrow.up") }.buttonStyle(.borderless)
                            Spacer()
                            Button { media.move(s.id, 1) } label: { Label("Later", systemImage: "arrow.down") }.buttonStyle(.borderless)
                        }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Remove source", systemImage: "trash") }
                    }
                }
                .scrollContentBackground(.hidden).background(Theme.bg)
                .navigationTitle(s.name).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { media.rename(source: s.id, name); dismiss() } } }
                .confirmationDialog("Remove \(s.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { media.delete(s.id); dismiss() }
                } message: { Text("Its saved headlines are deleted from this phone.") }
            }
            .onAppear { name = s.name }
            .presentationDetents([.medium, .large])
        }
    }

    private func autoSection(_ s: MediaSource) -> FeedSection {
        var auto = s
        auto.section = nil
        let byId = Dictionary(uniqueKeysWithValues: media.sources.map { ($0.id, $0) })
        return Sections.of(auto, outlet: media.outlet(of: s.id), all: byId)
    }
}

// MARK: - Arrange home

struct ArrangeHomeScreen: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var media: MediaStore
    @Environment(\.dismiss) var dismiss
    @State private var order: [String] = []
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .center, spacing: 20) {
                        PhonePreview(order: order, hidden: settings.homeHidden)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Find the order that feels right").font(.headline).foregroundStyle(Theme.text)
                            Text("Drag a row by its handle to move it. Tap the eye to hide a section.").font(.caption).foregroundStyle(Theme.muted)
                            Text("Search always stays at the top.").font(.caption2).foregroundStyle(Theme.muted)
                        }
                    }.listRowBackground(Color.clear)
                    Button { creating = true } label: { Label("New module — like Media, for anything you follow", systemImage: "plus") }
                }
                Section {
                    ForEach(Array(order.enumerated()), id: \.element) { i, key in
                        let hidden = settings.homeHidden.contains(key)
                        HStack(spacing: 12) {
                            Image(systemName: HomeLayout.icon(key)).foregroundStyle(HomeLayout.color(key).opacity(hidden ? 0.4 : 1))
                                .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 12).fill(HomeLayout.color(key).opacity(hidden ? 0.06 : 0.16)))
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("\(i + 1)").font(.caption2.weight(.bold)).foregroundStyle(HomeLayout.color(key))
                                    Text(HomeLayout.title(key)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                }
                                Text(hidden ? "Hidden" : HomeLayout.summary(key)).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                            }.opacity(hidden ? 0.45 : 1)
                            Spacer()
                            Button { HomeLayout.setHidden(key, !hidden); UIImpactFeedbackGenerator(style: .light).impactOccurred() } label: {
                                Image(systemName: hidden ? "eye.slash" : "eye").foregroundStyle(hidden ? Theme.muted : Theme.text)
                            }.buttonStyle(.borderless)
                        }.padding(.vertical, 4)
                    }
                    .onMove { from, to in
                        order.move(fromOffsets: from, toOffset: to)
                        HomeLayout.save(order)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden).background(Theme.bg)
            .navigationTitle("Arrange home").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Reset") { HomeLayout.reset(); order = HomeLayout.order() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.bold() }
            }
            .sheet(isPresented: $creating) { NewModuleSheet { _ in order = HomeLayout.order(); HomeLayout.save(order) }.environmentObject(media).preferredColorScheme(.dark) }
        }
        .onAppear { order = HomeLayout.order() }
    }
}

/// A tiny phone that redraws the home page layout as you drag.
struct PhonePreview: View {
    let order: [String]
    let hidden: [String]
    var body: some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 4).fill(Theme.teal.opacity(0.7)).frame(width: 12, height: 12)
            Capsule().fill(Theme.text.opacity(0.6)).frame(width: 36, height: 4)
            Capsule().stroke(Theme.outline).frame(height: 9)
            ForEach(order.filter { !hidden.contains($0) }, id: \.self) { k in
                RoundedRectangle(cornerRadius: 5).fill(HomeLayout.color(k).opacity(0.55)).frame(height: HomeLayout.previewHeight(k) * 0.8)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 10).frame(width: 96)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.surfaceLow))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.outline, lineWidth: 1.5))
        .animation(.spring(), value: order)
    }
}
