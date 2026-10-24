import Foundation

/// How a source is fetched. New kinds plug in here without touching the UI.
public enum SourceKind: String, Codable, CaseIterable, Sendable {
    case FEED, YOUTUBE, PEERTUBE, WEB, TWITCH, OWNCAST, STREAM, RUMBLE

    public var label: String {
        switch self {
        case .FEED: return "Feed"
        case .YOUTUBE: return "YouTube"
        case .PEERTUBE: return "PeerTube"
        case .WEB: return "Web page"
        case .TWITCH: return "Twitch"
        case .OWNCAST: return "Owncast"
        case .STREAM: return "Live stream"
        case .RUMBLE: return "Rumble"
        }
    }

    /// Kinds with no article/video feed — only a live status.
    public var liveOnly: Bool { self == .TWITCH || self == .OWNCAST || self == .STREAM }
    public var isVideo: Bool { self == .YOUTUBE || self == .PEERTUBE || self == .RUMBLE || self == .TWITCH }
    public var isSite: Bool { self == .FEED || self == .WEB }
    public var order: Int { SourceKind.allCases.firstIndex(of: self) ?? 0 }
}

public enum ItemType: String, Codable, Sendable { case ARTICLE, VIDEO }

public struct MediaSource: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var feedUrl: String
    public var siteUrl: String
    public var kind: SourceKind
    public var enabled: Bool = true
    public var order: Int = 0
    public var lastFetched: Int64 = 0
    public var lastError: String? = nil
    public var etag: String? = nil
    public var lastModified: String? = nil
    /// A live channel found for this source automatically (e.g. a news site's YouTube channel).
    public var liveLink: String? = nil
    public var liveLinkKind: SourceKind? = nil
    public var liveLinkChecked: Bool = false
    /// User override: "news" or "media" (nil = automatic).
    public var section: String? = nil
    /// User override for outlet grouping: a shared key merges sources, "solo" keeps one apart.
    public var group: String? = nil

    public init(id: String, name: String, feedUrl: String, siteUrl: String, kind: SourceKind, enabled: Bool = true, order: Int = 0,
                lastFetched: Int64 = 0, lastError: String? = nil, liveLink: String? = nil, liveLinkKind: SourceKind? = nil,
                section: String? = nil, group: String? = nil) {
        self.id = id; self.name = name; self.feedUrl = feedUrl; self.siteUrl = siteUrl; self.kind = kind
        self.enabled = enabled; self.order = order; self.lastFetched = lastFetched; self.lastError = lastError
        self.liveLink = liveLink; self.liveLinkKind = liveLinkKind; self.section = section; self.group = group
    }
}

public struct MediaItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var sourceId: String
    public var title: String
    public var url: String
    public var publishedAt: Int64
    public var snippet: String
    public var thumbnailUrl: String?
    public var type: ItemType

    public init(id: String, sourceId: String, title: String, url: String, publishedAt: Int64, snippet: String, thumbnailUrl: String?, type: ItemType) {
        self.id = id; self.sourceId = sourceId; self.title = title; self.url = url; self.publishedAt = publishedAt
        self.snippet = snippet; self.thumbnailUrl = thumbnailUrl; self.type = type
    }
}

/// What a parser pulls out of one feed or page.
public struct ParsedFeed: Sendable {
    public var title: String
    public var siteUrl: String?
    public var items: [ParsedItem]
    public init(title: String, siteUrl: String?, items: [ParsedItem]) { self.title = title; self.siteUrl = siteUrl; self.items = items }
    public static let empty = ParsedFeed(title: "", siteUrl: nil, items: [])
}

public struct ParsedItem: Sendable {
    public var title: String
    public var url: String
    public var publishedAt: Int64
    public var snippet: String
    public var thumbnailUrl: String?
    public var type: ItemType
    public init(title: String, url: String, publishedAt: Int64, snippet: String, thumbnailUrl: String?, type: ItemType) {
        self.title = title; self.url = url; self.publishedAt = publishedAt; self.snippet = snippet; self.thumbnailUrl = thumbnailUrl; self.type = type
    }
}

public enum MediaItems {
    /// Turns parsed entries into stored items: clean URLs, stable ids, undated items keep feed order.
    public static func from(_ src: MediaSource, _ parsed: ParsedFeed, perSource: Int = 60, now: Int64 = Clock.now) -> [MediaItem] {
        let forceVideo = src.kind == .YOUTUBE || src.kind == .PEERTUBE || src.kind == .RUMBLE
        return parsed.items.prefix(perSource).enumerated().map { i, p in
            let clean = UrlCleaner.clean(p.url).url
            return MediaItem(
                id: normalize(clean).stableHash, sourceId: src.id, title: p.title, url: clean,
                publishedAt: p.publishedAt > 0 ? min(p.publishedAt, now) : Int64(-i),
                snippet: p.snippet, thumbnailUrl: p.thumbnailUrl, type: forceVideo ? .VIDEO : p.type
            )
        }
    }

    /// Replace one source's items, dropping duplicates another source already carries.
    public static func merge(_ all: [MediaItem], sourceId: String, fresh: [MediaItem]) -> [MediaItem] {
        let others = all.filter { $0.sourceId != sourceId }
        var seen = Set(others.map(\.id))
        var out = others
        for f in fresh where !seen.contains(f.id) { seen.insert(f.id); out.append(f) }
        return out
    }

    public static func normalize(_ url: String) -> String {
        var u = url.lowercased().removingPrefix("https://").removingPrefix("http://").removingPrefix("www.").removingPrefix("m.")
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }
}
