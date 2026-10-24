import SwiftUI
import WebKit
import BastionCore

/// Meta-search results, merged and ranked on the phone, with what Bastion knows about each site.
struct ResultsView: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var tm: TabManager

    var body: some View {
        let accent = tab.isPrivate ? Theme.purple : Theme.teal
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text(tab.query).font(.title3.weight(.semibold)).foregroundStyle(Theme.text).padding(.top, 12)
                if tab.searching {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Fetching and ranking on your phone…").font(.caption).foregroundStyle(Theme.muted) }
                        .padding(.vertical, 30)
                } else if let o = tab.outcome {
                    HStack(spacing: 6) {
                        ForEach(o.statuses) { s in
                            Text(s.error == nil ? "\(s.name) \(s.count)" : "\(s.name) · \(s.error!)").font(.caption2.weight(.medium))
                                .foregroundStyle(s.error == nil ? Theme.muted : Theme.warn)
                                .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Theme.surfaceHigh))
                        }
                    }
                    if o.results.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("No results").font(.headline).foregroundStyle(Theme.text)
                            Text("The sources didn't return anything, or asked for a bot check. You can try again, or open this search on DuckDuckGo in the browser.")
                                .font(.subheadline).foregroundStyle(Theme.muted)
                            Button("Open this search on DuckDuckGo instead") { tm.navigate(tab, "https://duckduckgo.com/?q=" + tab.query.urlQueryEncoded) }.buttonStyle(.bordered)
                            Button("Try again") { tm.search(tab, tab.query) }
                        }.padding(.vertical, 20)
                    }
                    ForEach(o.results) { r in ResultCard(r: r, accent: accent) { tm.openResult(tab, r.url) } }
                    Text("Ranked on this phone from \(o.statuses.filter { $0.error == nil }.map(\.name).joined(separator: ", ")). No search history leaves your device.")
                        .font(.caption2).foregroundStyle(Theme.muted).padding(.vertical, 20)
                } else {
                    Text("Search failed. Check your connection and try again.").foregroundStyle(Theme.muted).padding(.vertical, 30)
                }
            }.padding(.horizontal, 16)
        }
        .background(Theme.bg)
    }
}

struct ResultCard: View {
    let r: RankedResult
    let accent: Color
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    LetterAvatar(host: r.host, size: 22)
                    Text(r.host).font(.caption.weight(.medium)).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer()
                    if r.sources.count > 1 { Text("\(r.sources.count) sources agree").font(.caption2.weight(.semibold)).foregroundStyle(Theme.good) }
                }
                Text(r.title).font(.headline).foregroundStyle(accent).lineLimit(2).multilineTextAlignment(.leading)
                if !r.snippet.isBlank { Text(r.snippet).font(.subheadline).foregroundStyle(Theme.text.opacity(0.85)).lineLimit(3).multilineTextAlignment(.leading) }
                if let f = r.flagged {
                    Label(f.category == .MALICIOUS ? "Known malicious site — Bastion will warn before opening" : "Runs cryptominers", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(Theme.danger)
                }
                if r.pastBlocked > 0 {
                    Label("Bastion has blocked \(formatCount(r.pastBlocked)) trackers on this site before", systemImage: "shield.lefthalf.filled")
                        .font(.caption2).foregroundStyle(Theme.muted)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).card(16)
        }.buttonStyle(.plain)
    }
}

/// The shield button's sheet: this page's grade, protections, who tried to track you, and shields up/down for the site.
struct ShieldSheet: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var stats: PrivacyStats
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var tm: TabManager
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let page = stats.page(tab.id), tab.content == .web {
                        HStack(spacing: 14) {
                            Text(String(page.grade)).font(.system(size: 28, weight: .bold)).foregroundStyle(gradeColor(page.grade))
                                .frame(width: 56, height: 56).background(RoundedRectangle(cornerRadius: 16).fill(gradeColor(page.grade).opacity(0.15)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(page.host).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                                Text(gradeText(page.grade)).font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                        let base = Domains.base(page.host)
                        let on = !settings.isAllowlisted(page.host)
                        Toggle(isOn: Binding(get: { on }, set: { v in settings.setAllowlisted(base, !v); tm.refreshProtections(); tm.reload(tab) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(on ? "Shields up for \(base)" : "Shields down for \(base)").foregroundStyle(Theme.text)
                                Text(on ? "Ads and trackers are blocked here." : "Trackers are allowed on this site. Malware is still blocked.").font(.caption).foregroundStyle(Theme.muted)
                            }
                        }.tint(Theme.teal).padding(14).card(16)

                        VStack(alignment: .leading, spacing: 8) {
                            line(page.secure, page.secure ? "Encrypted connection (HTTPS)" : "Not encrypted — others on the network can see this page")
                            if page.httpsUpgraded { line(true, "Upgraded to HTTPS automatically") }
                            if page.paramsStripped > 0 { line(true, "Removed \(page.paramsStripped) tracking parameter(s) from the link") }
                            if !page.fingerprinting.isEmpty { line(settings.fingerprint, "Fingerprinting attempt (\(page.fingerprinting.joined(separator: ", "))) — " + (settings.fingerprint ? "noise added" : "protection off")) }
                            ForEach(Array(Set(page.permissionsDenied)).sorted(), id: \.self) { line(true, "Denied access to your \($0)") }
                            if page.youtubeAds > 0 { line(true, "Removed or skipped \(page.youtubeAds) YouTube ad(s)") }
                            if page.wallsRemoved > 0 { line(true, "Removed the ad-blocker wall") }
                            if page.cosmeticHidden > 0 { line(true, "Hid \(page.cosmeticHidden) leftover ad container(s)") }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).card(16)

                        if !page.items.isEmpty {
                            Text("Who tried to track you").font(.headline).foregroundStyle(Theme.text)
                            ForEach(TrackerCategory.allCases, id: \.self) { cat in
                                let items = page.items.filter { $0.category == cat }
                                if !items.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Circle().fill(Color(hex: cat.color)).frame(width: 8, height: 8)
                                            Text("\(cat.label) · \(items.count)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                        }
                                        ForEach(items) { it in
                                            HStack {
                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text(it.domain).font(.caption).foregroundStyle(Theme.text).lineLimit(1)
                                                    if it.company != it.domain { Text(it.company).font(.caption2).foregroundStyle(Theme.muted) }
                                                }
                                                Spacer()
                                                Text(it.blocked ? "Blocked ×\(it.count)" : "Allowed ×\(it.count)").font(.caption2.weight(.semibold))
                                                    .foregroundStyle(it.blocked ? Theme.good : Theme.warn)
                                            }
                                        }
                                    }.padding(14).card(16)
                                }
                            }
                        }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "shield.lefthalf.filled").font(.system(size: 44)).foregroundStyle(Theme.teal)
                            Text("Shields are up").font(.title2.weight(.semibold)).foregroundStyle(Theme.text)
                            Text("Open a website to see exactly who tried to track you there.").font(.subheadline).foregroundStyle(Theme.muted)
                        }.frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    Button { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { router.sheet = .report } } label: {
                        Text("Open full privacy report").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                    Text("On iPhone, requests are blocked by Safari's content-blocking engine before they're made. This list shows what the page tried to load, scored by Bastion's filter lists.")
                        .font(.caption2).foregroundStyle(Theme.muted)
                }.padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("Shields").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func line(_ ok: Bool, _ text: String) -> some View {
        Label { Text(text).font(.subheadline).foregroundStyle(Theme.text) } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(ok ? Theme.good : Theme.warn)
        }
    }

    private func gradeText(_ g: Character) -> String {
        switch g {
        case "A": return "Barely tried to track you"
        case "B": return "A little tracking, all blocked"
        case "C": return "Moderate tracking"
        case "D": return "Heavy tracking"
        default: return "Aggressive or dangerous"
        }
    }
}

/// Reader view: the article's text only. No scripts, no ads, no trackers.
struct ReaderScreen: View {
    let item: MediaItem
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var tm: TabManager
    @Environment(\.dismiss) var dismiss
    @State private var article: Reader.Article?
    @State private var failed = false

    var body: some View {
        let scale = CGFloat(settings.readerTextScale) / 100
        NavigationStack {
            Group {
                if let a = article {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(a.title.nilIfBlank ?? item.title).font(.system(size: 24 * scale, weight: .bold)).foregroundStyle(Theme.text)
                            Text([a.byline, a.site ?? MediaStore.shared.name(of: item.sourceId).nilIfBlank, item.publishedAt > 0 ? timeAgo(item.publishedAt) : nil,
                                  "\(max(1, a.words / 230)) min read"].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption.weight(.medium)).foregroundStyle(Theme.muted)
                            ForEach(Array(a.blocks.enumerated()), id: \.offset) { _, b in
                                switch b.kind {
                                case .HEADING: Text(b.text).font(.system(size: 19 * scale, weight: .semibold)).foregroundStyle(Theme.text).padding(.top, 6)
                                case .QUOTE:
                                    Text(b.text).font(.system(size: 17 * scale)).italic().foregroundStyle(Theme.text.opacity(0.85))
                                        .padding(.leading, 14).overlay(Rectangle().fill(Theme.teal).frame(width: 3), alignment: .leading)
                                case .BULLET: HStack(alignment: .top, spacing: 8) { Text("•"); Text(b.text) }.font(.system(size: 17 * scale)).foregroundStyle(Theme.text)
                                case .PARAGRAPH: Text(b.text).font(.system(size: 17 * scale)).lineSpacing(5 * scale).foregroundStyle(Theme.text)
                                }
                            }
                            Button("Open the full page") { openPage() }.padding(.vertical, 24)
                        }.padding(.horizontal, 22).padding(.vertical, 8).frame(maxWidth: 680)
                    }
                } else {
                    VStack(spacing: 12) { ProgressView(); Text("Loading text only…").font(.caption).foregroundStyle(Theme.muted) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.bg)
            .navigationTitle(MediaStore.shared.name(of: item.sourceId)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "chevron.left") } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("A−") { settings.readerTextScale = max(80, settings.readerTextScale - 10) }
                    Button("A+") { settings.readerTextScale = min(160, settings.readerTextScale + 10) }
                    Button("Full page") { openPage() }
                }
            }
        }
        .task {
            let f = try? await Http.shared.fetch(item.url, accept: "text/html")
            if let f, f.code < 400, let a = Reader.extract(f.body, f.finalUrl) { article = a } else { openPage() }
        }
    }

    private func openPage() { dismiss(); if let t = tm.current { tm.navigate(t, item.url) } }
}
