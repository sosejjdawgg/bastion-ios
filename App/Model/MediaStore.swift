import SwiftUI
import BastionCore

/// One feed module on the home page: built-in Newsfeed and Media, plus any the user makes. Each can be renamed,
/// collapsed, and chosen to light up the World Events globe or not.
struct FeedModule: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var title: String
    var flare: Bool
    var accent: UInt32
    var collapsed: Bool = false

    static let NEWS = "news", MEDIA = "media"
    var builtin: Bool { id == FeedModule.NEWS || id == FeedModule.MEDIA }
    var section: FeedSection { id == FeedModule.NEWS ? .NEWS : id == FeedModule.MEDIA ? .MEDIA : FeedSection("c:\(id)") }
    var defaultTitle: String { id == FeedModule.NEWS ? "Newsfeed" : id == FeedModule.MEDIA ? "Media" : title }
    var color: Color { Color(hex: accent) }
}

/// Sources, their latest items, modules, filters and live status. Stored as JSON on this device only.
/// Refreshes are polite: at most 3 sources at a time, conditional GET, and only when older than 20 minutes.
@MainActor
final class MediaStore: ObservableObject {
    static let shared = MediaStore()
    static let staleMs: Int64 = 20 * 60_000

    @Published private(set) var sources: [MediaSource] = []
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var readIds: Set<String> = []
    @Published private(set) var refreshing = false
    @Published private(set) var modules: [FeedModule] = []
    @Published var filters: [String: FeedFilter] = [:]
    @Published private(set) var live: [String: LiveStatus] = [:]
    @Published private(set) var liveChecking = false
    private var removedCompanions: Set<String> = []

    private init() {
        sources = (Files.load("sources.json", as: [MediaSource].self) ?? []).sorted { $0.order < $1.order }
        items = Files.load("items.json", as: [MediaItem].self) ?? []
        readIds = Set(Files.load("read.json", as: [String].self) ?? [])
        removedCompanions = Set(Files.load("removed.json", as: [String].self) ?? [])
        let saved = Files.load("modules.json", as: [FeedModule].self) ?? []
        let defaults = [FeedModule(id: FeedModule.NEWS, title: "Newsfeed", flare: true, accent: 0xFF8A65),
                        FeedModule(id: FeedModule.MEDIA, title: "Media", flare: true, accent: 0x4FD1C5)]
        modules = defaults.map { d in saved.first { $0.id == d.id } ?? d } + saved.filter { !$0.builtin }
        for s in sources where s.liveLink != nil { addCompanion(s) }
    }

    // MARK: modules

    var news: FeedModule { modules.first { $0.id == FeedModule.NEWS }! }
    var media: FeedModule { modules.first { $0.id == FeedModule.MEDIA }! }
    var customModules: [FeedModule] { modules.filter { !$0.builtin } }
    func module(_ id: String) -> FeedModule? { modules.first { $0.id == id } }
    func module(for s: FeedSection) -> FeedModule? { modules.first { $0.section == s } }
    func flares(_ s: FeedSection) -> Bool { module(for: s)?.flare ?? true }

    private func updateModule(_ id: String, _ f: (inout FeedModule) -> Void) {
        guard let i = modules.firstIndex(where: { $0.id == id }) else { return }
        f(&modules[i]); saveModules()
    }
    func rename(module id: String, _ title: String) {
        updateModule(id) { m in m.title = String(title.trimmed.prefix(28)).nilIfBlank ?? m.defaultTitle }
    }
    func setFlare(_ id: String, _ on: Bool) { updateModule(id) { $0.flare = on } }
    func setCollapsed(_ id: String, _ on: Bool) { updateModule(id) { $0.collapsed = on } }

    static let accents: [UInt32] = [0xF78FB3, 0x9CCC65, 0x7AA2F7, 0xF6C177, 0xB39DDB, 0x4DD0E1, 0xE6A26B]

    func createModule(_ title: String, flare: Bool) -> FeedModule {
        let m = FeedModule(id: "m" + String(Clock.now, radix: 36), title: String(title.trimmed.prefix(28)).nilIfBlank ?? "My channels",
                           flare: flare, accent: MediaStore.accents[customModules.count % MediaStore.accents.count])
        modules.append(m); saveModules()
        return m
    }

    /// Removes a user-made module. Its sources go back to automatic sorting, or are deleted with their posts.
    func deleteModule(_ id: String, deleteSources: Bool) {
        guard let m = module(id), !m.builtin else { return }
        for s in sources where s.section == m.section.key { if deleteSources { delete(s.id) } else { setSection(s.id, nil) } }
        modules.removeAll { $0.id == id }; saveModules()
    }

    private func saveModules() { Files.save("modules.json", modules); invalidate() }

    // MARK: curation (recomputed only when sources or modules change)

    private var cacheKey: Int?
    private var outletList: [Outlet] = []
    private var outletOf: [String: Outlet] = [:]
    private var sectionOf: [String: FeedSection] = [:]

    private func invalidate() { cacheKey = nil; objectWillChange.send() }

    private func curate() {
        var h = Hasher(); h.combine(sources); h.combine(modules)
        let key = h.finalize()
        if cacheKey == key { return }
        outletList = Outlets.group(sources)
        outletOf = [:]
        for o in outletList { for id in o.sourceIds { outletOf[id] = o } }
        let byId = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let keys = Set(modules.map { $0.section.key })
        sectionOf = Dictionary(uniqueKeysWithValues: sources.map { s in (s.id, Sections.of(s, outlet: outletOf[s.id], all: byId, customExists: { keys.contains($0) })) })
        cacheKey = key
    }

    var outlets: [Outlet] { curate(); return outletList }
    func outlet(of id: String) -> Outlet? { curate(); return outletOf[id] }
    func section(of id: String) -> FeedSection { curate(); return sectionOf[id] ?? .MEDIA }

    func sectionOutlets(_ s: FeedSection) -> [Outlet] {
        outlets.compactMap { o in
            let ids = o.sourceIds.filter { section(of: $0) == s }
            if ids.isEmpty { return nil }
            return Outlet(id: o.id, name: o.name, sourceIds: ids, kinds: Set(ids.compactMap { source($0)?.kind }))
        }
    }

    func sectionItems(_ s: FeedSection) -> [MediaItem] {
        let ids = Set(sources.filter { $0.enabled && section(of: $0.id) == s }.map(\.id))
        let hide = Settings.shared.mediaHideShorts
        return items.filter { ids.contains($0.sourceId) && !(hide && $0.url.contains("youtube.com/shorts/")) }
    }

    func groupKey(_ id: String) -> String { outlet(of: id)?.id ?? id }
    func name(of id: String) -> String { outlet(of: id)?.name ?? source(id)?.name ?? "" }
    func source(_ id: String) -> MediaSource? { sources.first { $0.id == id } }

    var context: FilterContext {
        FilterContext(read: readIds, kindOf: { [weak self] in self?.source($0)?.kind }, groupOf: { [weak self] in self?.groupKey($0) ?? $0 },
                      nameOf: { [weak self] in self?.name(of: $0) ?? "" })
    }

    func filter(for s: FeedSection) -> FeedFilter { filters[s.key] ?? FeedFilter() }
    func setFilter(_ s: FeedSection, _ f: FeedFilter) { filters[s.key] = f }

    /// Drops filter values that no longer exist, so a stale filter never hides everything.
    func prune(_ f: FeedFilter, _ s: FeedSection) -> FeedFilter {
        let os = sectionOutlets(s)
        let groups = Set(os.map(\.id)), kinds = Set(os.flatMap(\.kinds))
        var out = f
        out.sources = f.sources.filter { groups.contains($0) }
        out.platforms = f.platforms.filter { kinds.contains($0) }
        return out
    }

    func filtered(_ s: FeedSection, _ f: FeedFilter, base: [MediaItem]) -> [MediaItem] { Filtering.apply(base, prune(f, s), context) }
    func facets(_ s: FeedSection, _ f: FeedFilter, base: [MediaItem]) -> Facets { Filtering.facets(base, prune(f, s), context) }

    // MARK: read state

    func markRead(_ item: MediaItem) {
        guard !readIds.contains(item.id) else { return }
        readIds.insert(item.id); saveRead()
    }
    func markAllRead(_ list: [MediaItem]) { readIds.formUnion(list.map(\.id)); saveRead() }

    // MARK: sources

    /// Look up what the user typed and add it (to [section] when it's a user-made module).
    @discardableResult
    func add(_ input: String, section: FeedSection? = nil) async throws -> MediaSource {
        let r = try await SourceResolver.resolve(input)
        if let existing = sources.first(where: { $0.feedUrl == r.feedUrl }) { return existing }
        var src = MediaSource(id: String(r.feedUrl.stableHash.prefix(12)), name: String(r.name.prefix(60)), feedUrl: r.feedUrl, siteUrl: r.siteUrl,
                              kind: r.kind, order: (sources.map(\.order).max() ?? -1) + 1, lastFetched: Clock.now)
        if let section, section.custom { src.section = section.key }
        sources.append(src)
        items = MediaItems.merge(items, sourceId: src.id, fresh: MediaItems.from(src, r.preview))
        saveSources(); saveItems()
        if src.kind.isSite {
            let link = await LiveLinker.discover(src)
            setLiveLink(src.id, link?.0, link?.1)
            if let l = source(src.id)?.liveLink, let c = sources.first(where: { $0.feedUrl == l && $0.lastFetched == 0 }) { await refresh(force: true, only: c.id) }
        }
        if src.kind == .YOUTUBE || src.kind.liveOnly || src.kind == .PEERTUBE || src.kind == .RUMBLE { await checkLive(force: true, only: src.id) }
        return source(src.id) ?? src
    }

    func setLiveLink(_ id: String, _ link: String?, _ kind: SourceKind?) {
        update(id) { $0.liveLink = link; $0.liveLinkKind = kind; $0.liveLinkChecked = true }
        if let s = source(id) { addCompanion(s) }
    }

    /// A news site linked to its video channel gets that channel's videos too, so headlines and videos sit together in
    /// one outlet. The companion is an ordinary source; once removed it is never re-added.
    @discardableResult
    func addCompanion(_ site: MediaSource) -> MediaSource? {
        guard let link = site.liveLink, let kind = site.liveLinkKind, kind == .YOUTUBE || kind == .RUMBLE || kind == .PEERTUBE,
              !sources.contains(where: { $0.feedUrl == link }), !removedCompanions.contains(link) else { return nil }
        var c = MediaSource(id: String(link.stableHash.prefix(12)), name: String(Outlets.cleanName(site.name).prefix(60)), feedUrl: link,
                            siteUrl: kind == .YOUTUBE ? "https://www.youtube.com/channel/" + link.after("channel_id=") : link,
                            kind: kind, order: (sources.map(\.order).max() ?? -1) + 1)
        c.group = "c:" + site.id
        if let sec = site.section, sec.hasPrefix("c:") { c.section = sec }
        sources.append(c); saveSources()
        return c
    }

    func rename(source id: String, _ name: String) { update(id) { $0.name = String(name.trimmed.prefix(60)).nilIfBlank ?? $0.name } }
    func setEnabled(_ id: String, _ on: Bool) { update(id) { $0.enabled = on } }
    func setSection(_ id: String, _ section: String?) { update(id) { $0.section = section } }
    func setGroup(_ id: String, _ g: String?) { update(id) { $0.group = g } }

    func delete(_ id: String) {
        if let s = source(id), s.group?.hasPrefix("c:") == true { removedCompanions.insert(s.feedUrl); Files.save("removed.json", Array(removedCompanions)) }
        sources.removeAll { $0.id == id }
        items.removeAll { $0.sourceId == id }
        live[id] = nil
        saveSources(); saveItems()
    }

    func move(_ id: String, _ delta: Int) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard sources.indices.contains(j) else { return }
        sources.swapAt(i, j)
        for k in sources.indices { sources[k].order = k }
        saveSources()
    }

    private func update(_ id: String, _ f: (inout MediaSource) -> Void) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        f(&sources[i]); saveSources()
    }

    // MARK: refresh

    func refresh(force: Bool, only: String? = nil) async {
        if refreshing { return }
        let now = Clock.now
        let due = sources.filter { $0.enabled && (only == nil || $0.id == only) && (force || now - $0.lastFetched > MediaStore.staleMs) }
        if due.isEmpty { return }
        refreshing = true
        defer { refreshing = false }
        var results: [(MediaSource, [MediaItem]?)] = []
        // at most three at a time
        var i = 0
        while i < due.count {
            let batch = Array(due[i..<min(i + 3, due.count)])
            await withTaskGroup(of: (MediaSource, [MediaItem]?).self) { g in
                for s in batch { g.addTask { await MediaStore.fetchOne(s) } }
                for await r in g { results.append(r) }
            }
            i += 3
        }
        var all = items
        for (src, fresh) in results {
            if let idx = sources.firstIndex(where: { $0.id == src.id }) {
                var updated = src; updated.section = sources[idx].section; updated.group = sources[idx].group; updated.name = sources[idx].name; updated.enabled = sources[idx].enabled
                sources[idx] = updated
            }
            if let fresh { all = MediaItems.merge(all, sourceId: src.id, fresh: fresh) }
        }
        items = all
        saveSources(); saveItems()
    }

    nonisolated static func fetchOne(_ s: MediaSource) async -> (MediaSource, [MediaItem]?) {
        var s = s
        let now = Clock.now
        if s.kind == .RUMBLE {
            do {
                let vids = try await Rumble.channel(s.feedUrl)
                let parsed = ParsedFeed(title: s.name, siteUrl: s.siteUrl, items: vids.filter { !$0.live }.map {
                    ParsedItem(title: $0.title, url: $0.pageUrl, publishedAt: $0.publishedAt, snippet: "", thumbnailUrl: $0.thumbnailUrl, type: .VIDEO)
                })
                s.lastFetched = now; s.lastError = vids.isEmpty ? "No videos found" : nil
                return (s, MediaItems.from(s, parsed))
            } catch { s.lastFetched = now; s.lastError = "Couldn't reach Rumble"; return (s, nil) }
        }
        if s.kind.liveOnly { s.lastFetched = now; s.lastError = nil; return (s, nil) }
        do {
            let f = try await Http.shared.fetch(s.kind == .WEB ? s.siteUrl : s.feedUrl, etag: s.etag, lastModified: s.lastModified)
            s.lastFetched = now
            if f.code == 304 { s.lastError = nil; return (s, nil) }
            if f.code >= 400 { s.lastError = "HTTP \(f.code)"; return (s, nil) }
            let parsed = s.kind == .WEB ? FeedParser.scrapeHeadlines(f.body, f.finalUrl) : FeedParser.parse(f.body, f.finalUrl)
            s.lastError = parsed.items.isEmpty ? "No items found" : nil
            s.etag = f.etag; s.lastModified = f.lastModified
            return (s, MediaItems.from(s, parsed))
        } catch {
            s.lastFetched = now; s.lastError = "Couldn't connect"
            return (s, nil)
        }
    }

    // MARK: live

    var channels: [MediaSource] { Live.channels(sources) }
    var liveNow: [(MediaSource, LiveStatus)] {
        channels.compactMap { s in live[s.id].flatMap { $0.state == .LIVE ? (s, $0) : nil } }.sorted { ($0.1.viewers ?? -1) > ($1.1.viewers ?? -1) }
    }
    var offline: [MediaSource] { channels.filter { live[$0.id]?.state != .LIVE } }

    func checkLive(force: Bool = false, only: String? = nil) async {
        if liveChecking && only == nil { return }
        liveChecking = true
        defer { liveChecking = false }
        // look for live channels behind news sites not checked yet (a few per round)
        for s in sources.filter({ $0.kind.isSite && !$0.liveLinkChecked }).prefix(3) {
            let link = await LiveLinker.discover(s)
            setLiveLink(s.id, link?.0, link?.1)
        }
        let now = Clock.now
        let due = channels.filter { s in (only == nil || s.id == only) && (force || now - (live[s.id]?.checkedAt ?? 0) > Live.minInterval) }
        var i = 0
        while i < due.count {
            let batch = Array(due[i..<min(i + 3, due.count)])
            let results: [(String, LiveStatus)] = await withTaskGroup(of: (String, LiveStatus).self) { g in
                for s in batch { let t = Live.target(s); g.addTask { (s.id, await Live.probe(t)) } }
                var out: [(String, LiveStatus)] = []
                for await r in g { out.append(r) }
                return out
            }
            for (id, st) in results { live[id] = st }
            i += 3
        }
    }

    // MARK: OPML & data

    func exportOpml() -> String { Opml.write(sources) }

    @discardableResult
    func importOpml(_ text: String) -> Int {
        var known = Set(sources.map(\.feedUrl))
        var order = (sources.map(\.order).max() ?? -1) + 1
        var added: [MediaSource] = []
        for e in Opml.parse(text) where !known.contains(e.xmlUrl) {
            let kind: SourceKind = e.xmlUrl.contains("twitch.tv/") ? .TWITCH : e.xmlUrl.lowercased().before("?").hasSuffix(".m3u8") ? .STREAM :
                e.xmlUrl.contains("youtube.com/feeds/videos.xml") ? .YOUTUBE : e.xmlUrl.contains("/feeds/videos.xml") ? .PEERTUBE : .FEED
            added.append(MediaSource(id: String(e.xmlUrl.stableHash.prefix(12)), name: String(e.title.prefix(60)), feedUrl: e.xmlUrl, siteUrl: e.htmlUrl ?? e.xmlUrl, kind: kind, order: order))
            order += 1; known.insert(e.xmlUrl)
        }
        for e in Opml.parseLinks(text) where !known.contains(e.xmlUrl) {
            added.append(MediaSource(id: String(e.xmlUrl.stableHash.prefix(12)), name: String(e.title.prefix(60)), feedUrl: e.xmlUrl, siteUrl: e.xmlUrl, kind: .WEB, order: order))
            order += 1; known.insert(e.xmlUrl)
        }
        if !added.isEmpty { sources += added; saveSources() }
        return added.count
    }

    func clearAll() {
        sources = []; items = []; readIds = []; filters = [:]; live = [:]
        saveSources(); saveItems(); saveRead()
    }

    // MARK: persistence

    private func saveSources() { Files.save("sources.json", sources); invalidate() }
    private func saveItems() { Files.save("items.json", items) }
    private func saveRead() {
        let current = Set(items.map(\.id))
        if readIds.count > 6000 { readIds = readIds.filter { current.contains($0) } }
        Files.save("read.json", Array(readIds))
    }

    /// For previews only.
    func seed(_ s: [MediaSource], _ i: [MediaItem]) { sources = s; items = i; invalidate() }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}
