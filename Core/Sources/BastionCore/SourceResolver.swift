import Foundation
import SwiftSoup

/// Small SwiftSoup helpers shared by the HTML parsers.
enum Soup {
    static func doc(_ html: String, _ base: String) -> Document? { try? SwiftSoup.parse(html, base) }
    static func select(_ e: Element, _ css: String) -> [Element] { (try? e.select(css).array()) ?? [] }
    static func first(_ e: Element, _ css: String) -> Element? { (try? e.select(css).first()) ?? nil }
    static func text(_ e: Element?) -> String { e.flatMap { try? $0.text() } ?? "" }
    static func attr(_ e: Element?, _ a: String) -> String { e.flatMap { try? $0.attr(a) } ?? "" }
    static func absUrl(_ e: Element?, _ a: String) -> String { e.flatMap { try? $0.absUrl(a) } ?? "" }
    static func className(_ e: Element) -> String { (try? e.className()) ?? "" }
    static func parents(_ e: Element) -> [Element] {
        var out: [Element] = []
        var p = e.parent()
        while let cur = p { out.append(cur); p = cur.parent() }
        return out
    }
}

/// Turns whatever the user pastes — a feed URL, a site address, a YouTube channel / @handle / playlist, a PeerTube
/// channel, a Twitch / Rumble / Owncast channel or an HLS stream — into a source Bastion can poll.
public enum SourceResolver {
    public struct Resolved: Sendable {
        public let name: String
        public let feedUrl: String
        public let siteUrl: String
        public let kind: SourceKind
        public let preview: ParsedFeed
    }

    public struct NotFound: Error, LocalizedError {
        public let message: String
        public init(_ m: String) { message = m }
        public var errorDescription: String? { message }
    }

    public static func resolve(_ input: String, fetch: FetchFn = defaultFetch) async throws -> Resolved {
        let raw = input.trimmed
        if raw.isEmpty { throw NotFound("Enter a website, feed or channel address.") }
        let url = normalizeInput(raw)
        let host = (URLs.host(url) ?? "").removingPrefix("www.").removingPrefix("m.")

        if host == "youtube.com" || host == "youtu.be" || host == "music.youtube.com" { return try await youtube(url, fetch) }
        if host == "twitch.tv" { return try twitch(url) }
        if host == "rumble.com" { return try rumble(url) }
        if URLs.path(url).lowercased().hasSuffix(".m3u8") { return try await stream(url, fetch) }
        if let o = await owncast(url, fetch) { return o }
        if let p = await peertube(url, fetch) { return p }

        let first = try await fetch(url)
        if first.code >= 400 { throw NotFound("That address returned an error (HTTP \(first.code)).") }
        if first.body.hasPrefix("#EXTM3U") { return try await stream(first.finalUrl, fetch) }

        // 1. It is already a feed.
        if FeedParser.isFeed(first.body) { return try asFeed(first, kindFor(first.finalUrl, first.body)) }

        // 2. Feed advertised by the page.
        for f in FeedParser.discoverFeeds(first.body, first.finalUrl) {
            guard let r = try? await fetch(f) else { continue }
            if r.code < 400 && FeedParser.isFeed(r.body) { return try asFeed(r, kindFor(r.finalUrl, r.body), siteFallback: first.finalUrl) }
        }

        // 3. Common feed locations.
        let root = URLs.root(first.finalUrl)
        for p in ["/feed", "/rss", "/rss.xml", "/feed.xml", "/atom.xml", "/index.xml", "/feed.json", "/feeds/posts/default"] {
            guard let r = try? await fetch(root + p) else { continue }
            if r.code < 400 && FeedParser.isFeed(r.body) { return try asFeed(r, kindFor(r.finalUrl, r.body), siteFallback: first.finalUrl) }
        }

        // 4. No feed: scrape headlines from the page itself.
        let scraped = FeedParser.scrapeHeadlines(first.body, first.finalUrl)
        if scraped.items.count >= 3 {
            return Resolved(name: scraped.title.nilIfBlank ?? host, feedUrl: first.finalUrl, siteUrl: first.finalUrl, kind: .WEB, preview: scraped)
        }
        throw NotFound("Couldn't find a feed or headlines at \(host).")
    }

    private static func asFeed(_ f: Fetched, _ kind: SourceKind, siteFallback: String? = nil) throws -> Resolved {
        let parsed = FeedParser.parse(f.body, f.finalUrl)
        if parsed.items.isEmpty && parsed.title.isBlank { throw NotFound("That feed is empty or unreadable.") }
        let site = parsed.siteUrl.flatMap { $0.hasPrefix("http") ? $0 : nil } ?? siteFallback ?? URLs.root(f.finalUrl)
        let name = parsed.title.nilIfBlank ?? (URLs.host(site)?.removingPrefix("www.") ?? site)
        return Resolved(name: name, feedUrl: f.finalUrl, siteUrl: site, kind: kind, preview: parsed)
    }

    static func kindFor(_ feedUrl: String, _ body: String) -> SourceKind {
        if feedUrl.contains("youtube.com/feeds/videos.xml") { return .YOUTUBE }
        if body.take(3000).containsCI("PeerTube") || feedUrl.contains("/feeds/videos.") { return .PEERTUBE }
        return .FEED
    }

    // MARK: YouTube

    static let channelId = Rx("UC[0-9A-Za-z_-]{22}")

    private static func youtube(_ url: String, _ fetch: FetchFn) async throws -> Resolved {
        let path = URLs.path(url)
        let list = URLs.queryParam(url, "list")
        let feed: String
        if path.hasPrefix("/feeds/videos.xml") {
            feed = url
        } else if let list, !list.hasPrefix("RD") {
            feed = "https://www.youtube.com/feeds/videos.xml?playlist_id=\(list)"
        } else if path.hasPrefix("/channel/"), let id = channelId.find(path)?[0] {
            feed = "https://www.youtube.com/feeds/videos.xml?channel_id=\(id)"
        } else {
            // @handle, /c/name, /user/name or a video: read the channel id from the page.
            let page = try await fetch(url)
            if let adv = FeedParser.discoverFeeds(page.body, page.finalUrl).first(where: { $0.contains("youtube.com/feeds/videos.xml") }) {
                feed = adv
            } else if let id = Rx("\"(?:channelId|externalId|browseId)\":\"(UC[0-9A-Za-z_-]{22})\"").group1(page.body) {
                feed = "https://www.youtube.com/feeds/videos.xml?channel_id=\(id)"
            } else {
                throw NotFound("Couldn't find that YouTube channel. Try its channel page (youtube.com/@name).")
            }
        }
        let f = try await fetch(feed)
        if f.code >= 400 || !FeedParser.isFeed(f.body) { throw NotFound("YouTube didn't return a feed for that channel.") }
        let parsed = FeedParser.parse(f.body, f.finalUrl)
        return Resolved(name: parsed.title.nilIfBlank ?? "YouTube channel", feedUrl: f.finalUrl, siteUrl: parsed.siteUrl ?? url, kind: .YOUTUBE, preview: parsed)
    }

    // MARK: live-only sources

    private static func twitch(_ url: String) throws -> Resolved {
        let name = URLs.path(url).trimmingCharacters(in: CharacterSet(charactersIn: "/")).before("/")
        guard Rx("^[A-Za-z0-9_]{3,25}$").matches(name) else { throw NotFound("That doesn't look like a Twitch channel address.") }
        let u = "https://www.twitch.tv/\(name.lowercased())"
        return Resolved(name: name, feedUrl: u, siteUrl: u, kind: .TWITCH, preview: .empty)
    }

    private static func rumble(_ url: String) throws -> Resolved {
        guard let m = Rx("rumble\\.com/(c|user)/([^/?#]+)").find(url) else {
            throw NotFound("Paste a Rumble channel address, like rumble.com/c/ChannelName.")
        }
        let canonical = "https://rumble.com/\(m[1])/\(m[2])"
        return Resolved(name: m[2], feedUrl: canonical, siteUrl: canonical, kind: .RUMBLE, preview: .empty)
    }

    private static func stream(_ url: String, _ fetch: FetchFn) async throws -> Resolved {
        let f = try await fetch(url)
        if f.code >= 400 || !f.body.hasPrefix("#EXTM3U") { throw NotFound("That isn't a playable HLS stream.") }
        return Resolved(name: URLs.host(url)?.removingPrefix("www.") ?? "Live stream", feedUrl: url, siteUrl: url, kind: .STREAM, preview: .empty)
    }

    /// Owncast servers answer /api/status with {"online": …}.
    private static func owncast(_ url: String, _ fetch: FetchFn) async -> Resolved? {
        let root = URLs.root(url)
        guard let st = try? await fetch("\(root)/api/status"), st.code < 400,
              st.body.trimmed.hasPrefix("{"), st.body.contains("\"online\"") else { return nil }
        var name = URLs.host(root) ?? root
        if let cfg = try? await fetch("\(root)/api/config"), let o = JSON.object(cfg.body), let n = o["name"] as? String, !n.isBlank { name = n }
        return Resolved(name: name, feedUrl: root, siteUrl: root, kind: .OWNCAST, preview: .empty)
    }

    // MARK: PeerTube

    private static func peertube(_ url: String, _ fetch: FetchFn) async -> Resolved? {
        guard let m = Rx("^/(c|a|video-channels|accounts)/([^/]+)").find(URLs.path(url)) else { return nil }
        let base = URLs.root(url)
        let handle = m[2]
        let isChannel = m[1] == "c" || m[1] == "video-channels"
        let api = "\(base)/api/v1/\(isChannel ? "video-channels" : "accounts")/" + handle.urlQueryEncoded
        guard let info = try? await fetch(api), info.code < 400, let o = JSON.object(info.body),
              let id = (o["id"] as? NSNumber)?.int64Value, id >= 0 else { return nil }
        let feed = "\(base)/feeds/videos.xml?" + (isChannel ? "videoChannelId=" : "accountId=") + "\(id)"
        guard let f = try? await fetch(feed), f.code < 400, FeedParser.isFeed(f.body) else { return nil }
        let parsed = FeedParser.parse(f.body, f.finalUrl)
        let name = (o["displayName"] as? String)?.nilIfBlank ?? parsed.title.nilIfBlank ?? handle
        return Resolved(name: name, feedUrl: f.finalUrl, siteUrl: url, kind: .PEERTUBE, preview: parsed)
    }

    // MARK: helpers

    static func normalizeInput(_ s: String) -> String {
        var u = s
        if u.hasPrefix("@") { u = "https://www.youtube.com/\(u)" }
        if !Rx("^[a-zA-Z][a-zA-Z0-9+.-]*://").contains(u) { u = "https://\(u)" }
        return u
    }
}

/// Tiny JSON helpers over JSONSerialization (works the same on Linux and iOS).
public enum JSON {
    public static func object(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
    public static func array(_ s: String) -> [Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [Any]
    }
    public static func string(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]) else { return "null" }
        return String(decoding: d, as: UTF8.self)
    }
    /// Walks a path of keys / indexes: JSON.at(o, "a", 0, "b").
    public static func at(_ v: Any?, _ path: Any...) -> Any? {
        var cur = v
        for p in path {
            if let k = p as? String { cur = (cur as? [String: Any])?[k] }
            else if let i = p as? Int { let a = cur as? [Any]; cur = (a != nil && i < a!.count) ? a![i] : nil }
        }
        return cur
    }
}

// MARK: - OPML

/// OPML 2.0 import/export, so sources move to and from any other feed reader.
public enum Opml {
    public struct Entry: Sendable { public let title: String; public let xmlUrl: String; public let htmlUrl: String? }

    public static func parse(_ text: String) -> [Entry] {
        guard let doc = try? SwiftSoup.parse(text, "", Parser.xmlParser()) else { return [] }
        var seen = Set<String>()
        return Soup.select(doc, "outline").compactMap { o in
            let url = Soup.attr(o, "xmlUrl").trimmed
            guard url.hasPrefix("http"), seen.insert(url).inserted else { return nil }
            return Entry(title: Soup.attr(o, "title").nilIfBlank ?? Soup.attr(o, "text").nilIfBlank ?? url, xmlUrl: url, htmlUrl: Soup.attr(o, "htmlUrl").nilIfBlank)
        }
    }

    /// Pages saved as type="link" by our own export.
    public static func parseLinks(_ text: String) -> [Entry] {
        guard let doc = try? SwiftSoup.parse(text, "", Parser.xmlParser()) else { return [] }
        return Soup.select(doc, "outline").compactMap { o in
            let u = Soup.attr(o, "url")
            guard Soup.attr(o, "type") == "link", !u.isBlank else { return nil }
            return Entry(title: Soup.attr(o, "text").nilIfBlank ?? u, xmlUrl: u, htmlUrl: u)
        }
    }

    public static func write(_ sources: [MediaSource]) -> String {
        var sb = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\">\n  <head><title>Bastion media sources</title></head>\n  <body>\n"
        for s in sources where s.kind != .WEB {
            sb += "    <outline type=\"rss\" text=\"\(s.name.htmlEscaped)\" title=\"\(s.name.htmlEscaped)\" xmlUrl=\"\(s.feedUrl.htmlEscaped)\" htmlUrl=\"\(s.siteUrl.htmlEscaped)\"/>\n"
        }
        let web = sources.filter { $0.kind == .WEB }
        if !web.isEmpty {
            sb += "    <!-- Web pages without a feed (Bastion scrapes their headlines) -->\n"
            for s in web { sb += "    <outline type=\"link\" text=\"\(s.name.htmlEscaped)\" url=\"\(s.siteUrl.htmlEscaped)\"/>\n" }
        }
        return sb + "  </body>\n</opml>\n"
    }
}

// MARK: - Reader view

/// Reader view extraction: title, byline and text only. Runs on downloaded HTML — no scripts, no ads, no images.
public enum Reader {
    public enum Kind: String, Sendable { case HEADING, PARAGRAPH, QUOTE, BULLET }
    public struct Block: Sendable, Hashable { public let kind: Kind; public let text: String; public init(_ k: Kind, _ t: String) { kind = k; text = t } }
    public struct Article: Sendable {
        public let title: String
        public let byline: String?
        public let site: String?
        public let blocks: [Block]
        public init(title: String, byline: String?, site: String?, blocks: [Block]) { self.title = title; self.byline = byline; self.site = site; self.blocks = blocks }
        public var words: Int { blocks.reduce(0) { $0 + $1.text.split(separator: " ").count } }
    }

    static let noise = "script, style, noscript, iframe, svg, form, button, nav, footer, aside, figure figcaption, [aria-hidden=true], " +
        "[role=navigation], [role=complementary], .ad, .ads, .advert, .advertisement, .newsletter, .related, .share, .social, .comments, " +
        "#comments, .promo, .subscribe, [class*=paywall], [class*=cookie]"

    public static func extract(_ html: String, _ url: String) -> Article? {
        guard let doc = Soup.doc(html, url), let body = doc.body() else { return nil }
        let title = Soup.attr(Soup.first(doc, "meta[property=og:title]"), "content").nilIfBlank
            ?? Soup.text(Soup.first(doc, "h1")).nilIfBlank ?? ((try? doc.title()) ?? "")
        let byline = Soup.attr(Soup.first(doc, "meta[name=author]"), "content").nilIfBlank
            ?? Soup.text(Soup.first(doc, "[rel=author], .byline, [class*=author-name]")).take(80).nilIfBlank
        let site = Soup.attr(Soup.first(doc, "meta[property=og:site_name]"), "content").nilIfBlank
        _ = try? doc.select(noise).remove()
        for h in Soup.select(body, "header") where !Soup.parents(h).contains(where: { $0.tagName() == "article" }) { _ = try? h.remove() }

        guard let root = pickRoot(body) else { return nil }
        var blocks: [Block] = []
        for el in Soup.select(root, "h2, h3, p, blockquote, li") {
            let tag = el.tagName()
            let ps = Soup.parents(el)
            if tag != "blockquote" && ps.contains(where: { $0.tagName() == "blockquote" }) { continue }
            if tag == "li" && !ps.contains(where: { $0 === root }) { continue }
            let t = Soup.text(el).collapsedSpaces
            if t.isEmpty { continue }
            let kind: Kind = (tag == "h2" || tag == "h3") ? .HEADING : tag == "blockquote" ? .QUOTE : tag == "li" ? .BULLET : .PARAGRAPH
            if kind == .PARAGRAPH && t.count < 30 && !t.hasSuffix(".") { continue }
            if kind == .BULLET && t.count < 20 { continue }
            if blocks.last?.text == t { continue }
            blocks.append(Block(kind, t))
        }
        if blocks.filter({ $0.kind == .PARAGRAPH }).count < 2 { return nil }
        return Article(title: title.trimmed, byline: byline?.trimmed, site: site?.trimmed, blocks: blocks)
    }

    private static func textScore(_ e: Element) -> Int { Soup.select(e, "p").reduce(0) { $0 + Soup.text($1).count } }

    private static func pickRoot(_ body: Element) -> Element? {
        let semantic = Soup.select(body, "article, [itemprop=articleBody], main, [role=main], .post-content, .entry-content, .article-body, .story-body")
            .max { textScore($0) < textScore($1) }
        if let s = semantic, textScore(s) > 600 { return s }
        var scores: [(Element, Int)] = []
        for p in Soup.select(body, "p") {
            let len = Soup.text(p).count
            guard len >= 40, let parent = p.parent() else { continue }
            if let i = scores.firstIndex(where: { $0.0 === parent }) { scores[i].1 += len } else { scores.append((parent, len)) }
        }
        return scores.max { $0.1 < $1.1 }?.0 ?? semantic
    }
}

// MARK: - Rumble

/// Rumble channels: latest videos, live status and embeds, read from rumble.com's own pages (no API, no account).
/// Page structure follows yt-dlp's Rumble extractor. When rumble.com answers with a Cloudflare check, the app
/// loads the page through a hidden web view instead ([Rumble.pageLoader]).
public enum Rumble {
    public struct Video: Sendable, Hashable {
        public let title: String
        public let pageUrl: String
        public let thumbnailUrl: String?
        public let publishedAt: Int64
        public let live: Bool
        public let upcoming: Bool
        public let duration: String?
    }

    /// Set by the app: loads a page in a real (hidden) browser when plain HTTP meets a bot check.
    nonisolated(unsafe) public static var pageLoader: (@Sendable (String) async -> String?)? = nil

    static let embed = Rx("https://rumble\\.com/embed/(?:[0-9a-z]+\\.)?([0-9a-z]+)/?")

    public static func page(_ url: String) async throws -> String {
        let f = try? await Http.shared.fetch(url)
        let blocked = f == nil || f!.code == 403 || f!.code == 503 || f!.body.containsCI("<title>Just a moment")
        if !blocked, let f, f.code < 400 { return f.body }
        if let loader = pageLoader, let html = await loader(url) { return html }
        throw HTTPError("Rumble didn't load")
    }

    public static func channel(_ url: String) async throws -> [Video] { parseChannel(try await page(url), url) }

    public static func parseChannel(_ html: String, _ baseUrl: String) -> [Video] {
        guard let doc = Soup.doc(html, baseUrl) else { return [] }
        var out: [Video] = []
        var seen = Set<String>()
        for a in Soup.select(doc, "a[class*=videostream__link][href]") {
            let href = Soup.absUrl(a, "href").before("?")
            guard href.contains("rumble.com/v"), seen.insert(href).inserted else { continue }
            let box = Soup.parents(a).first { p in Soup.className(p).split(separator: " ").contains { $0 == "videostream" } } ?? a.parent()
            guard let box else { continue }
            guard let title = Soup.text(Soup.first(box, ".thumbnail__title, h3, [class*=title]")).trimmed.nilIfBlank
                    ?? Soup.attr(a, "title").nilIfBlank ?? Soup.attr(Soup.first(box, "img[alt]"), "alt").nilIfBlank else { continue }
            let img = Soup.first(box, "img.thumbnail__image, img[src]")
            let thumb = [Soup.absUrl(img, "src"), Soup.absUrl(img, "data-src")].first { $0.hasPrefix("http") }
            let time = Soup.first(box, "time[datetime]").map { FeedParser.parseDate(Soup.attr($0, "datetime")) } ?? 0
            let status = Soup.select(box, "[class*=status], [class*=badge], [class*=live]").map { Soup.className($0) + " " + Soup.text($0) }.joined(separator: " ").lowercased()
            let live = status.contains("status--live") || (Rx("\\blive\\b").contains(status) && !status.contains("upcoming") && !status.contains("dvr"))
            let upcoming = status.contains("upcoming")
            let dur = Soup.text(Soup.first(box, "[class*=duration], .videostream__time")).trimmed
            out.append(Video(title: title, pageUrl: href, thumbnailUrl: thumb, publishedAt: time, live: live && !upcoming, upcoming: upcoming,
                             duration: Rx("^[0-9:]+$").matches(dur) ? dur : nil))
            if out.count >= 40 { break }
        }
        return out
    }

    /// The player embed for a video page (only fetched when you press play).
    public static func embedFor(_ videoPageUrl: String) async throws -> String? {
        let html = try await page(videoPageUrl)
        guard let id = embed.group1(html) ?? Rx("\"embedUrl\"\\s*:\\s*\"[^\"]*/embed/(?:[0-9a-z]+\\.)?([0-9a-z]+)").group1(html) else { return nil }
        return "https://rumble.com/embed/\(id)/?autoplay=2&rel=0"
    }
}

// MARK: - Live linking

/// Finds the live channel behind a news site, so its broadcasts and videos join the outlet automatically.
public enum LiveLinker {
    /// Official YouTube channels of major news outlets (IDs verified against their channel feeds, Oct 2026).
    static let known: [String: String] = [
        "bbc.co.uk": "UC16niRr50-MSBwiO3YDb3RA", "bbc.com": "UC16niRr50-MSBwiO3YDb3RA", "bbci.co.uk": "UC16niRr50-MSBwiO3YDb3RA",
        "aljazeera.com": "UCNye-wNBqNL5ZzHSJj3l8Bg", "dw.com": "UCknLrEdhRCp1aegoMqRaCZg", "france24.com": "UCQfwfsi5VrQ8yKZ-UWmAEFg",
        "sky.com": "UCoMdktPbSTixAyNGwb-UYkQ", "cnn.com": "UCupvZG-5ko_eiXAupbDfxWw", "abcnews.go.com": "UCBi2mrWuNuyYy4gbM6fU18Q",
        "nbcnews.com": "UCeY0bbntWzzVIaj2z3QigXg", "cbsnews.com": "UC8p1vwvWtl6T73JiExfWs1g", "reuters.com": "UChqUTb7kYRX8-EiaN3XFrSQ",
        "apnews.com": "UC52X5wxOL_s5yw0dQk7NtgA", "euronews.com": "UCSrZ3UV4jOidv8ppoVuvW9Q", "theguardian.com": "UCHpw8xwDNhU9gdohEcJu4aA",
        "abc.net.au": "UCVgO39Bk5sMo66-6o6Spn6Q", "cbc.ca": "UCuFFtHWoLl5fauMMD5Ww2jA", "pbs.org": "UC6ZFN9Tx6xh-skXCuRHCDpQ",
        "wionews.com": "UC_gUM8rL-Lrg6O3adPW9K1g", "nasa.gov": "UCLA_DiR1FfKNvjuUpBHmylQ"
    ]
    static let ytReserved: Set<String> = ["watch", "embed", "results", "feed", "playlist", "shorts", "live", "about", "redirect", "t", "s", "yt", "account", "premium", "kids", "music", "gaming", "channel", "c", "user"]
    static let link = Rx("https?://(?:www\\.|m\\.)?(youtube\\.com/(?:@[A-Za-z0-9_.-]+|channel/UC[A-Za-z0-9_-]{22}|c/[A-Za-z0-9_.-]+|user/[A-Za-z0-9_.-]+|[A-Za-z0-9]{3,40})|twitch\\.tv/[A-Za-z0-9_]{3,25}|rumble\\.com/(?:c|user)/[A-Za-z0-9_.-]+)")

    public static func knownChannel(_ src: MediaSource) -> String? {
        let site = src.siteUrl.nilIfBlank ?? src.feedUrl
        guard let host = URLs.host(site) else { return nil }
        let id = known[Domains.base(host)] ?? known[host.removingPrefix("www.")] ?? (host.hasPrefix("news.sky.com") ? known["sky.com"] : nil)
        return id.map { "https://www.youtube.com/feeds/videos.xml?channel_id=\($0)" }
    }

    /// (channel address or YouTube feed URL, kind), or nil when the site has no live channel.
    public static func discover(_ src: MediaSource, fetch: FetchFn = defaultFetch) async -> (String, SourceKind)? {
        if let k = knownChannel(src) { return (k, .YOUTUBE) }
        let site = src.siteUrl.nilIfBlank ?? src.feedUrl
        guard URLs.host(site) != nil, let page = try? await fetch(URLs.root(site) + "/"), page.code < 400 else { return nil }
        return await pick(page.body, fetch: fetch)
    }

    static func pick(_ body: String, fetch: FetchFn) async -> (String, SourceKind)? {
        var counts: [String: Int] = [:]
        for m in link.findAll(body) {
            let path = m.groups[1]
            if path.hasPrefix("youtube.com/") {
                let seg = path.removingPrefix("youtube.com/").before("/")
                if ytReserved.contains(seg.lowercased()) && !path.contains("/channel/UC") && !path.contains("/c/") && !path.contains("/user/") { continue }
            }
            let key = "https://www." + path.removingPrefix("www.")
            let lo = body.index(m.range.lowerBound, offsetBy: -400, limitedBy: body.startIndex) ?? body.startIndex
            let weight = body[lo..<m.range.lowerBound].contains("sameAs") ? 2 : 1
            counts[key, default: 0] += weight
        }
        let best = counts.sorted { a, b in
            if a.value != b.value { return a.value > b.value }
            func rank(_ k: String) -> Int { k.contains("youtube") ? 0 : k.contains("rumble") ? 1 : 2 }
            return rank(a.key) < rank(b.key)
        }.first?.key
        guard let best else { return nil }
        if best.contains("youtube.com") {
            guard let r = try? await SourceResolver.resolve(best, fetch: fetch), r.kind == .YOUTUBE, r.feedUrl.contains("channel_id=") else { return nil }
            return (r.feedUrl, .YOUTUBE)
        }
        if best.contains("twitch.tv") { return (best, .TWITCH) }
        if best.contains("rumble.com") { return (best.replacingOccurrences(of: "https://www.", with: "https://"), .RUMBLE) }
        return nil
    }
}
