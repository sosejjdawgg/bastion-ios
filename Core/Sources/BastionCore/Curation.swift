import Foundation

// Everything that keeps a growing pile of sources readable — all on the phone, recomputed from whatever is in the
// feeds right now, so it adapts as sources and items come and go.

/// Which home module a source belongs to: built-in Newsfeed ("news") and Media ("media"), or a module the user made
/// ("c:<id>"), e.g. Entertainment or Hobbies.
public struct Section: Hashable, Codable, Sendable {
    public let key: String
    public init(_ key: String) { self.key = key }
    public static let NEWS = Section("news")
    public static let MEDIA = Section("media")
    public var custom: Bool { key.hasPrefix("c:") }
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        key = raw == "NEWS" ? "news" : raw == "MEDIA" ? "media" : raw
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(key) }
}

// MARK: - Outlets

public struct Outlet: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var sourceIds: [String]
    public var kinds: Set<SourceKind>
    public var hasVideo: Bool { kinds.contains { $0.isVideo } }
    public var hasSite: Bool { kinds.contains { $0.isSite } }
    public init(id: String, name: String, sourceIds: [String], kinds: Set<SourceKind>) {
        self.id = id; self.name = name; self.sourceIds = sourceIds; self.kinds = kinds
    }
}

public enum Outlets {
    static let suffixes = ["news", "tv", "online", "uk", "us", "world", "official", "channel", "media"]
    static let sharedHosts: Set<String> = ["feedburner", "substack", "medium", "blogspot", "wordpress", "github", "tumblr", "ghost", "beehiiv", "buttondown", "podbean", "libsyn", "anchor", "google"]
    static let nonAlnum = Rx("[^a-z0-9]")
    static let generic = Rx.ci("^(world|latest|home|top stories|headlines|news|world news|uk news|breaking news|rss|feed|all)$")

    /// "GB News", "GBNews", gbnews.com and "GB News – Latest" all reduce to the same brand keys.
    public static func brandKeys(_ s: MediaSource) -> Set<String> {
        var out = Set<String>()
        func addVariants(_ raw: String) {
            var k = nonAlnum.replace(raw.lowercased(), with: "")
            if k.hasPrefix("the") && k.count > 6 { k = String(k.dropFirst(3)) }
            if k.count >= 3 { out.insert(k) }
            for suf in suffixes where k.hasSuffix(suf) && k.count - suf.count >= 3 { out.insert(String(k.dropLast(suf.count))) }
        }
        addVariants(cleanName(s.name))
        if s.kind.isSite, let h = host(s.siteUrl.isBlank ? s.feedUrl : s.siteUrl) { addVariants(stem(h)) }
        if s.kind == .RUMBLE || s.kind == .TWITCH {
            var u = s.siteUrl
            while u.hasSuffix("/") { u.removeLast() }
            addVariants(u.afterLast("/"))
        }
        return out
    }

    /// "BBC News - World" → "BBC News"; "World news | The Guardian" → "The Guardian".
    public static func cleanName(_ name: String) -> String {
        var parts = [name]
        for sep in [" | ", " - ", " – ", " — ", ": "] { parts = parts.flatMap { $0.components(separatedBy: sep) } }
        parts = parts.map { $0.trimmed }.filter { !$0.isEmpty }
        if parts.count < 2 { return name.trimmed }
        return parts.filter { !generic.matches($0) }.min(by: { $0.count < $1.count }) ?? parts[0]
    }

    static func host(_ url: String) -> String? {
        URLs.host(url)?.removingPrefix("www.").removingPrefix("feeds.").removingPrefix("rss.")
    }

    /// gbnews.com → gbnews; feeds.bbci.co.uk → bbc; news.sky.com → sky; jane.substack.com → jane.
    static func stem(_ h: String) -> String {
        let parts = h.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return "" }
        let sld: Set<String> = ["co", "com", "org", "net", "gov", "ac"]
        let idx = parts.count >= 3 && sld.contains(parts[parts.count - 2]) ? parts.count - 3 : (parts.count >= 2 ? parts.count - 2 : 0)
        let core = parts[idx]
        if sharedHosts.contains(core) { return idx > 0 ? parts[idx - 1] : "" }
        return core == "bbci" ? "bbc" : core
    }

    public static func group(_ sources: [MediaSource]) -> [Outlet] {
        var parent: [String: String] = [:]
        func find(_ x: String) -> String { var r = x; while let p = parent[r], p != r { r = p }; return r }
        func union(_ a: String, _ b: String) { let ra = find(a), rb = find(b); if ra != rb { parent[rb] = ra } }
        for s in sources { parent[s.id] = s.id }

        var byFeed: [String: MediaSource] = [:]
        for s in sources where byFeed[s.feedUrl] == nil { byFeed[s.feedUrl] = s }
        var byKey: [String: String] = [:]
        var byGroup: [String: String] = [:]
        for s in sources {
            if s.group == "solo" { continue }
            if let g = s.group { if let o = byGroup[g] { union(o, s.id) } else { byGroup[g] = s.id } }
            if let l = s.liveLink, let t = byFeed[l], t.group != "solo" { union(s.id, t.id) }
            for k in brandKeys(s) { if let o = byKey[k] { union(o, s.id) } else { byKey[k] = s.id } }
        }
        var groups: [String: [MediaSource]] = [:]
        var order: [String] = []
        for s in sources {
            let r = find(s.id)
            if groups[r] == nil { order.append(r) }
            groups[r, default: []].append(s)
        }
        return order.map { r in
            let members = groups[r]!
            let video = members.first { $0.kind == .YOUTUBE || $0.kind == .RUMBLE || $0.kind == .PEERTUBE }
            let name = video?.name ?? members.map { cleanName($0.name) }.min(by: { $0.count < $1.count }) ?? members[0].name
            return Outlet(id: "o:" + members.map(\.id).min()!, name: name, sourceIds: members.map(\.id), kinds: Set(members.map(\.kind)))
        }
    }
}

// MARK: - Sections

public enum Sections {
    static let newsWords = Rx.ci("\\b(news|newsroom|newsnight|newshour|breaking|reporting|reporter|journal|journalism|times|post|press|tribune|herald|gazette|" +
        "daily|politics|briefing|bulletin|headlines|investigat\\w*|current affairs|world report|live coverage)\\b")
    static let newsBrands: Set<String> = [
        "bbc", "cnn", "sky", "gbnews", "aljazeera", "dw", "france24", "reuters", "associatedpress", "ap", "nbc", "cbs", "abc", "fox", "foxnews",
        "bloomberg", "cnbc", "msnbc", "guardian", "telegraph", "independent", "lbc", "talktv", "timesradio", "wion", "euronews", "nhk", "trt",
        "cgtn", "pbs", "npr", "cspan", "newsmax", "rebelnews", "ruptly", "breakingpoints", "statuscoup", "novara", "doubledownnews",
        "theyoungturks", "tyt", "democracynow", "vice", "channel4", "itv", "itvnews", "dailymail", "thesun", "mirror", "economist", "ft",
        "financialtimes", "politico", "axios", "vox", "theintercept", "propublica", "bellingcat", "ladbible", "unherd", "spiked", "middleeasteye",
        "aljazeeraenglish", "nasa", "ukcolumn", "timpool", "redacted", "news2share", "ondemandnews"
    ]

    /// Newsfeed for news sites, news channels and citizen journalists; Media for everything else. Overridable per source.
    /// [customExists] says whether a user-made module ("c:<id>") still exists; sources of a deleted one fall back to auto.
    public static func of(_ s: MediaSource, outlet: Outlet?, all: [String: MediaSource], customExists: (String) -> Bool = { _ in false }) -> Section {
        if s.section == "news" { return .NEWS }
        if s.section == "media" { return .MEDIA }
        if let k = s.section, k.hasPrefix("c:"), customExists(k) { return Section(k) }
        if s.kind.isSite { return .NEWS }
        if let o = outlet, o.sourceIds.contains(where: { all[$0]?.kind.isSite == true }) { return .NEWS }
        if !Outlets.brandKeys(s).isDisjoint(with: newsBrands) { return .NEWS }
        if newsWords.contains(s.name) { return .NEWS }
        return .MEDIA
    }
}

// MARK: - Stories

/// "Storm hits UK | BBC News" → "Storm hits UK": channels often brand their video titles; the badge already says who.
public func displayTitle(_ title: String) -> String {
    guard let g = Rx("^(.{20,}?)\\s+[|•]\\s+[^|•]{2,28}$").find(title.trimmed) else { return title }
    return g[1].trimmed
}

public struct Story: Identifiable, Sendable {
    public var id: String
    public var items: [MediaItem]
    public init(id: String, items: [MediaItem]) { self.id = id; self.items = items }

    /// The headline that leads the card: a written article with a summary and picture beats a video title.
    public var lead: MediaItem {
        func score(_ m: MediaItem) -> Int { min(m.snippet.count, 200) + (m.thumbnailUrl != nil ? 150 : 0) + (m.type == .ARTICLE ? 250 : 0) }
        return items.max { a, b in score(a) != score(b) ? score(a) < score(b) : a.publishedAt < b.publishedAt }!
    }
    public var newest: Int64 { items.map(\.publishedAt).max() ?? 0 }
}

public enum Stories {
    static let stop: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "into", "over", "after", "before", "about", "what", "when", "where", "who", "why",
        "how", "are", "was", "were", "has", "have", "had", "his", "her", "their", "its", "our", "your", "will", "would", "could", "should",
        "says", "said", "say", "new", "live", "latest", "news", "video", "watch", "update", "updates", "amid", "as", "at", "by", "in", "of", "on",
        "to", "up", "out", "off", "not", "but", "can", "may", "more", "than", "they", "them", "she", "him", "you", "all", "one", "two", "first",
        "year", "years", "day", "days", "week", "uk", "us", "via", "just", "now", "get", "gets", "set", "back", "being", "been", "also"
    ]
    static let splitter = Rx("[^a-z0-9']+")

    public static func tokens(_ title: String) -> Set<String> {
        var out = Set<String>()
        for raw in splitter.split(title.lowercased().replacingOccurrences(of: "’", with: "'")) {
            var w = raw.removingSuffix("'s")
            w = w.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if w.count < 3 || stop.contains(w) || w.allSatisfy({ $0.isNumber }) { continue }
            if w.count > 4 && w.hasSuffix("s") && !w.hasSuffix("ss") { w.removeLast() }
            out.insert(w)
        }
        return out
    }

    /// Greedy single-link clustering on title words: two headlines are the same story when they share at least two
    /// meaningful words and enough of their vocabulary (Jaccard ≥ 0.34), within 36 hours of each other.
    public static func cluster(_ items: [MediaItem], threshold: Double = 0.34) -> [Story] {
        let sorted = items.sorted { $0.publishedAt > $1.publishedAt }
        let toks = sorted.map { tokens($0.title) }
        var groups: [[Int]] = []
        for i in sorted.indices {
            if toks[i].count < 2 { groups.append([i]); continue }
            var best = -1, bestSim = 0.0
            for g in groups.indices {
                for j in groups[g] {
                    let a = sorted[i], b = sorted[j]
                    if abs(a.publishedAt - b.publishedAt) > 36 * 3_600_000 && a.publishedAt > 0 && b.publishedAt > 0 { continue }
                    if a.sourceId == b.sourceId && a.url == b.url { continue }
                    let inter = toks[i].intersection(toks[j]).count
                    if inter < 2 { continue }
                    let sim = Double(inter) / Double(toks[i].count + toks[j].count - inter)
                    if sim > bestSim { bestSim = sim; best = g }
                }
            }
            if best >= 0 && bestSim >= threshold { groups[best].append(i) } else { groups.append([i]) }
        }
        return groups.map { g in Story(id: sorted[g[0]].id, items: g.map { sorted[$0] }) }.sorted { $0.newest > $1.newest }
    }
}

// MARK: - Topics

public struct Topic: Identifiable, Equatable, Sendable {
    public var key: String
    public var label: String
    public var count: Int
    public var id: String { key }
}

public enum Topics {
    static let stopExtra: Set<String> = [
        "watch", "live", "video", "breaking", "latest", "full", "episode", "ep", "part", "official", "trailer", "review", "explained", "shorts", "podcast",
        "warns", "warn", "calls", "call", "faces", "face", "hits", "hit", "wins", "win", "slams", "claims", "claim", "reveals", "urges", "plans", "plan",
        "makes", "make", "takes", "take", "gives", "says", "told", "tells", "report", "reports", "row", "move", "push", "bid", "vows", "set",
        "killed", "dies", "dead", "people", "man", "woman", "after", "over", "could", "major", "big", "top", "best", "how", "why", "what"
    ]
    static let wordSplit = Rx("[^A-Za-z0-9'-]+")

    /// Words and two-word phrases that recur across several headlines from at least two sources.
    public static func trending(_ items: [MediaItem], max: Int = 6) -> [Topic] {
        if items.count < 6 { return [] }
        var count: [String: Int] = [:]
        var sources: [String: Set<String>] = [:]
        var surface: [String: [String: Int]] = [:]
        for it in items {
            let words = wordSplit.split(it.title.replacingOccurrences(of: "’", with: "'"))
                .map { $0.removingSuffix("'s").trimmingCharacters(in: CharacterSet(charactersIn: "'-")) }.filter { !$0.isEmpty }
            var seen = Set<String>()
            for i in words.indices {
                let w = words[i]
                guard let k = norm(w) else { continue }
                var cands = [(k, w)]
                if i + 1 < words.count, let n = norm(words[i + 1]) { cands.append(("\(k) \(n)", "\(w) \(words[i + 1])")) }
                for (key, surf) in cands {
                    if !seen.insert(key).inserted { continue }
                    count[key, default: 0] += 1
                    sources[key, default: []].insert(it.sourceId)
                    surface[key, default: [:]][surf, default: 0] += 1
                }
            }
        }
        let minCount = Swift.max(3, items.count / 40)
        let ranked = count.filter { $0.value >= minCount && (sources[$0.key]?.count ?? 0) >= 2 }
            .sorted { a, b in
                let sa = Double(a.value) * (a.key.contains(" ") ? 1.6 : 1), sb = Double(b.value) * (b.key.contains(" ") ? 1.6 : 1)
                return sa != sb ? sa > sb : a.key < b.key
            }
        var out: [Topic] = []
        for e in ranked {
            if out.contains(where: { o in o.key.split(separator: " ").map(String.init).contains(e.key) || e.key.split(separator: " ").allSatisfy { String($0) == o.key } }) { continue }
            let label = surface[e.key]!.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }!.key
            let chars = Array(label)
            let shown = chars.count > 1 && chars[1].isUppercase ? label : label.prefix(1).uppercased() + label.dropFirst()
            out.append(Topic(key: e.key, label: shown, count: e.value))
            if out.count >= max { break }
        }
        return out
    }

    static func norm(_ w: String) -> String? {
        let l = w.lowercased()
        if l.count < 3 || l.allSatisfy({ $0.isNumber }) || stopExtra.contains(l) { return nil }
        guard let t = Stories.tokens(l).first, !stopExtra.contains(t) else { return nil }
        return t
    }

    public static func matches(_ item: MediaItem, _ topicKey: String) -> Bool {
        let t = Stories.tokens(item.title)
        return topicKey.split(separator: " ").allSatisfy { t.contains(String($0)) }
    }
}

// MARK: - Filtering

public enum TimeFacet: String, Codable, CaseIterable, Sendable {
    case ANY, TODAY, DAY, WEEK
    public var label: String { ["Any time", "Today", "24 hours", "This week"][TimeFacet.allCases.firstIndex(of: self)!] }
    var hours: Int { [0, -1, 24, 168][TimeFacet.allCases.firstIndex(of: self)!] }
}

public enum SortMode: String, Codable, CaseIterable, Sendable {
    case NEWEST, UNREAD, SOURCE
    public var label: String { self == .NEWEST ? "Newest" : self == .UNREAD ? "Unread first" : "By source" }
}

/// One filter state. Empty sets mean "no restriction", so new sources show up automatically.
public struct FeedFilter: Codable, Equatable, Sendable {
    public var query = ""
    public var sources: Set<String> = []
    public var platforms: Set<SourceKind> = []
    public var type: ItemType? = nil
    public var time: TimeFacet = .ANY
    public var unreadOnly = false
    public var topic: String? = nil
    public var sort: SortMode = .NEWEST

    public init(query: String = "", sources: Set<String> = [], platforms: Set<SourceKind> = [], type: ItemType? = nil, time: TimeFacet = .ANY,
                unreadOnly: Bool = false, topic: String? = nil, sort: SortMode = .NEWEST) {
        self.query = query; self.sources = sources; self.platforms = platforms; self.type = type; self.time = time
        self.unreadOnly = unreadOnly; self.topic = topic; self.sort = sort
    }

    public var activeCount: Int {
        [!query.isBlank, !sources.isEmpty, !platforms.isEmpty, type != nil, time != .ANY, unreadOnly, topic != nil].filter { $0 }.count
    }
    public var isDefault: Bool { activeCount == 0 && sort == .NEWEST }
}

public struct SavedView: Codable, Equatable, Identifiable, Sendable {
    public var section: Section
    public var name: String
    public var filter: FeedFilter
    public var id: String { section.key + ":" + name }
    public init(section: Section, name: String, filter: FeedFilter) { self.section = section; self.name = name; self.filter = filter }
}

public struct Facets: Sendable {
    public var bySource: [String: Int]
    public var byPlatform: [SourceKind: Int]
    public var byType: [ItemType: Int]
    public var unread: Int
    public var total: Int
}

public struct FilterContext {
    public var read: Set<String>
    public var kindOf: (String) -> SourceKind?
    public var groupOf: (String) -> String
    public var nameOf: (String) -> String
    public init(read: Set<String>, kindOf: @escaping (String) -> SourceKind?, groupOf: @escaping (String) -> String, nameOf: @escaping (String) -> String) {
        self.read = read; self.kindOf = kindOf; self.groupOf = groupOf; self.nameOf = nameOf
    }
}

public enum Filtering {
    public static func apply(_ items: [MediaItem], _ f: FeedFilter, _ c: FilterContext, now: Int64 = Clock.now) -> [MediaItem] {
        let words = f.query.trimmed.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let cutoff: Int64
        switch f.time {
        case .ANY: cutoff = Int64.min
        case .TODAY:
            let d = Date(timeIntervalSince1970: TimeInterval(now) / 1000)
            cutoff = Int64(Calendar.current.startOfDay(for: d).timeIntervalSince1970 * 1000)
        default: cutoff = now - Int64(f.time.hours) * 3_600_000
        }
        let out = items.filter { it in
            (f.sources.isEmpty || f.sources.contains(c.groupOf(it.sourceId))) &&
                (f.platforms.isEmpty || c.kindOf(it.sourceId).map { f.platforms.contains($0) } == true) &&
                (f.type == nil || it.type == f.type) &&
                (f.time == .ANY || it.publishedAt >= cutoff) &&
                (!f.unreadOnly || !c.read.contains(it.id)) &&
                (f.topic == nil || Topics.matches(it, f.topic!)) &&
                (words.isEmpty || words.allSatisfy { w in
                    it.title.lowercased().contains(w) || it.snippet.lowercased().contains(w) || c.nameOf(it.sourceId).lowercased().contains(w)
                })
        }
        switch f.sort {
        case .NEWEST: return out.sorted { $0.publishedAt > $1.publishedAt }
        case .UNREAD:
            return out.sorted { a, b in
                let ra = c.read.contains(a.id), rb = c.read.contains(b.id)
                return ra != rb ? !ra : a.publishedAt > b.publishedAt
            }
        case .SOURCE:
            return out.sorted { a, b in
                let na = c.nameOf(a.sourceId).lowercased(), nb = c.nameOf(b.sourceId).lowercased()
                return na != nb ? na < nb : a.publishedAt > b.publishedAt
            }
        }
    }

    /// Facet counts computed as if that facet were not set, so every chip shows what choosing it would give.
    public static func facets(_ items: [MediaItem], _ f: FeedFilter, _ c: FilterContext, now: Int64 = Clock.now) -> Facets {
        var a = f; a.sources = []
        var b = f; b.platforms = []
        var t = f; t.type = nil
        var u = f; u.unreadOnly = false
        let noSource = apply(items, a, c, now: now), noPlatform = apply(items, b, c, now: now)
        let noType = apply(items, t, c, now: now), noUnread = apply(items, u, c, now: now)
        var bySource: [String: Int] = [:], byPlatform: [SourceKind: Int] = [:], byType: [ItemType: Int] = [:]
        for i in noSource { bySource[c.groupOf(i.sourceId), default: 0] += 1 }
        for i in noPlatform { if let k = c.kindOf(i.sourceId) { byPlatform[k, default: 0] += 1 } }
        for i in noType { byType[i.type, default: 0] += 1 }
        return Facets(bySource: bySource, byPlatform: byPlatform, byType: byType, unread: noUnread.filter { !c.read.contains($0.id) }.count, total: noUnread.count)
    }
}
