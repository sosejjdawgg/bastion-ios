import Foundation
import SwiftSoup

/// Parses RSS 2.0 / RSS 1.0 (RDF) / Atom / JSON Feed, and — for sites with no feed — pulls a light list of
/// headline links from plain HTML. Extracts only title, link, date, a short plain-text snippet and a thumbnail.
public enum FeedParser {
    static let snippetMax = 220
    static let maxItems = 60

    public static func isFeed(_ body: String) -> Bool {
        let head = body.trimmingCharacters(in: .whitespacesAndNewlines).take(1500).lowercased()
        if head.hasPrefix("{") { return head.contains("jsonfeed.org/version") }
        return head.contains("<rss") || head.contains("<feed") || head.contains("<rdf:rdf")
    }

    public static func parse(_ body: String, _ baseUrl: String) -> ParsedFeed {
        let trimmed = body.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF} \n\r\t"))
        if trimmed.hasPrefix("{") { return parseJsonFeed(trimmed, baseUrl) }
        return parseXml(trimmed, baseUrl)
    }

    // MARK: XML

    private static func parseXml(_ body: String, _ baseUrl: String) -> ParsedFeed {
        guard let doc = try? SwiftSoup.parse(body, baseUrl, Parser.xmlParser()) else { return .empty }
        let atom = first(doc, "feed") != nil && first(doc, "rss") == nil
        return atom ? parseAtom(doc, baseUrl) : parseRss(doc, baseUrl)
    }

    private static func parseRss(_ doc: Document, _ baseUrl: String) -> ParsedFeed {
        let channel = first(doc, "channel")
        let title = channel.flatMap { childText($0, "title") } ?? ""
        let site = channel.flatMap { ch in kids(ch).first { $0.tagName() == "link" && !text($0).isBlank }.map { text($0) } }
        var out: [ParsedItem] = []
        for it in all(doc, "item") {
            let t = clean(childText(it, "title") ?? "")
            var link = kids(it).first { $0.tagName() == "link" }.map { l in text(l).nilIfBlank ?? attr(l, "href") } ?? ""
            if link.isBlank, let guid = kids(it).first(where: { $0.tagName() == "guid" }),
               attr(guid, "isPermaLink") != "false", text(guid).hasPrefix("http") { link = text(guid) }
            if link.isBlank { link = kids(it).first { $0.tagName() == "enclosure" }.map { attr($0, "url") } ?? "" }
            guard let resolved = URLs.resolve(baseUrl, link.trimmed) else { continue }
            let date = parseDate(childText(it, "pubDate") ?? childText(it, "dc:date") ?? childText(it, "published") ?? childText(it, "updated"))
            let desc = childText(it, "description") ?? childText(it, "content:encoded") ?? ""
            let content = childText(it, "content:encoded") ?? desc
            out.append(ParsedItem(
                title: t.isBlank ? (snippet(desc).take(90).nilIfBlank ?? resolved) : t,
                url: resolved, publishedAt: date, snippet: snippet(desc),
                thumbnailUrl: thumbnail(it, content, baseUrl), type: itemType(it, resolved)))
            if out.count >= maxItems { break }
        }
        return ParsedFeed(title: clean(title), siteUrl: site?.trimmed, items: out)
    }

    private static func parseAtom(_ doc: Document, _ baseUrl: String) -> ParsedFeed {
        guard let feed = first(doc, "feed") else { return .empty }
        let title = childText(feed, "title") ?? ""
        let site = kids(feed).first { $0.tagName() == "link" && (attr($0, "rel").isEmpty || attr($0, "rel") == "alternate") }.map { attr($0, "href") }
        var out: [ParsedItem] = []
        for e in all(doc, "entry") {
            let links = kids(e).filter { $0.tagName() == "link" }
            let href = (links.first { attr($0, "rel").isEmpty || attr($0, "rel") == "alternate" } ?? links.first).map { attr($0, "href") } ?? ""
            guard let link = URLs.resolve(baseUrl, href.trimmed) else { continue }
            let mediaDesc = all(e, "media:description").first.map { text($0) }
            let summary = childText(e, "summary") ?? childText(e, "content") ?? mediaDesc ?? ""
            let content = childText(e, "content") ?? summary
            out.append(ParsedItem(
                title: clean(childText(e, "title") ?? "").nilIfBlank ?? link, url: link,
                publishedAt: parseDate(childText(e, "published") ?? childText(e, "updated")),
                snippet: snippet(summary), thumbnailUrl: thumbnail(e, content, baseUrl), type: itemType(e, link)))
            if out.count >= maxItems { break }
        }
        return ParsedFeed(title: clean(title), siteUrl: site, items: out)
    }

    // MARK: JSON Feed

    private static func parseJsonFeed(_ body: String, _ baseUrl: String) -> ParsedFeed {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else { return .empty }
        var out: [ParsedItem] = []
        for it in (o["items"] as? [[String: Any]]) ?? [] {
            let s = { (k: String) -> String in (it[k] as? String) ?? "" }
            guard let link = URLs.resolve(baseUrl, s("url").nilIfBlank ?? s("external_url")) else { continue }
            let html = s("content_html")
            let text = s("summary").nilIfBlank ?? s("content_text").nilIfBlank ?? html
            let video = ((it["attachments"] as? [[String: Any]]) ?? []).contains { (($0["mime_type"] as? String) ?? "").hasPrefix("video/") }
            out.append(ParsedItem(
                title: clean(s("title")).nilIfBlank ?? (snippet(text).take(90).nilIfBlank ?? link), url: link,
                publishedAt: parseDate(s("date_published").nilIfBlank ?? s("date_modified")),
                snippet: snippet(text),
                thumbnailUrl: s("image").nilIfBlank ?? s("banner_image").nilIfBlank ?? firstImage(html, baseUrl),
                type: video || looksLikeVideo(link) ? .VIDEO : .ARTICLE))
            if out.count >= maxItems { break }
        }
        return ParsedFeed(title: clean((o["title"] as? String) ?? ""), siteUrl: (o["home_page_url"] as? String)?.nilIfBlank, items: out)
    }

    // MARK: HTML fallback

    /// Headline links from a page that has no feed. No scripts run, nothing rendered.
    public static func scrapeHeadlines(_ html: String, _ pageUrl: String) -> ParsedFeed {
        guard let doc = try? SwiftSoup.parse(html, pageUrl) else { return .empty }
        _ = try? doc.select("script, style, noscript, nav, footer, form, iframe, svg, aside").remove()
        let host = URLs.host(pageUrl)?.removingPrefix("www.")
        var seen = Set<String>()
        var out: [ParsedItem] = []
        var headed: [Element] = []
        for sel in ["article h1 a[href]", "article h2 a[href]", "article h3 a[href]", "h2 a[href]", "h3 a[href]", "article a[href]"] {
            for e in (try? doc.select(sel).array()) ?? [] where !headed.contains(where: { $0 === e }) {
                if sel == "article a[href]" {
                    // only article links that wrap a heading
                    if ((try? e.select("h2, h3").array()) ?? []).isEmpty { continue }
                }
                headed.append(e)
            }
        }
        var candidates = headed
        if headed.count < 5 {
            // Text-only sites (lite.cnn.com, text.npr.org…) list stories as plain links.
            for a in (try? doc.select("a[href]").array()) ?? [] {
                let words = text(a).trimmed.split(whereSeparator: { $0.isWhitespace }).count
                let path = URLs.path(URLs.resolve(pageUrl, attr(a, "href")) ?? "")
                if words >= 5 && path.filter({ $0 == "/" }).count >= 2 && !candidates.contains(where: { $0 === a }) { candidates.append(a) }
            }
        }
        for a in candidates {
            guard let url = URLs.resolve(pageUrl, attr(a, "href")) else { continue }
            let h = URLs.host(url)?.removingPrefix("www.")
            if let host, let h, h != host && !h.hasSuffix(".\(host)") { continue }
            let t = clean(text(a))
            if t.count < 18 || t.split(separator: " ").count < 3 { continue }
            if !seen.insert(url.before("#")).inserted { continue }
            let art = closest(a, "article")
            let snip = art.flatMap { try? $0.select("p").first() }.map { snippet(text($0)) } ?? ""
            let time = art.flatMap { try? $0.select("time[datetime]").first() }.map { parseDate(attr($0, "datetime")) } ?? 0
            out.append(ParsedItem(title: t, url: url, publishedAt: time, snippet: snip, thumbnailUrl: nil, type: looksLikeVideo(url) ? .VIDEO : .ARTICLE))
            if out.count >= 30 { break }
        }
        return ParsedFeed(title: siteName(doc), siteUrl: pageUrl, items: out)
    }

    private static func siteName(_ doc: Document) -> String {
        if let og = try? doc.select("meta[property=og:site_name]").first(), let c = try? og.attr("content"), !c.isBlank { return c.trimmed }
        let title = (try? doc.title()) ?? ""
        let parts = splitBrand(title)
        if parts.count >= 2, let last = parts.last, last.count <= 30 { return last }
        return parts.first ?? ""
    }

    static func splitBrand(_ s: String) -> [String] {
        var parts = [s]
        for sep in [" | ", " – ", " — ", " - "] { parts = parts.flatMap { $0.components(separatedBy: sep) } }
        return parts.map { $0.trimmed }.filter { !$0.isEmpty }
    }

    /// `<link rel="alternate" type="application/rss+xml|atom+xml|feed+json">` on an HTML page.
    public static func discoverFeeds(_ html: String, _ pageUrl: String) -> [String] {
        guard let doc = try? SwiftSoup.parse(html, pageUrl) else { return [] }
        var out: [String] = []
        for l in (try? doc.select("link[href]").array()) ?? [] {
            let rel = attr(l, "rel").lowercased()
            guard rel.split(separator: " ").contains("alternate") else { continue }
            let t = attr(l, "type").lowercased()
            guard t.contains("rss") || t.contains("atom") || t.contains("feed+json") || t == "application/json+feed" else { continue }
            if let r = URLs.resolve(pageUrl, attr(l, "href")), !out.contains(r) { out.append(r) }
        }
        return out
    }

    // MARK: helpers

    static func first(_ e: Element, _ tag: String) -> Element? { (try? e.getElementsByTag(tag).first()) ?? nil }
    static func all(_ e: Element, _ tag: String) -> [Element] { (try? e.getElementsByTag(tag).array()) ?? [] }
    static func kids(_ e: Element) -> [Element] { e.children().array() }
    static func text(_ e: Element) -> String { (try? e.text()) ?? "" }
    static func attr(_ e: Element, _ a: String) -> String { (try? e.attr(a)) ?? "" }

    static func closest(_ e: Element, _ tag: String) -> Element? {
        var p = e.parent()
        while let cur = p { if cur.tagName() == tag { return cur }; p = cur.parent() }
        return nil
    }

    private static func childText(_ e: Element, _ tag: String) -> String? {
        guard let el = kids(e).first(where: { $0.tagName().caseInsensitiveCompare(tag) == .orderedSame }) else { return nil }
        // CDATA and escaped HTML both arrive as text here
        var raw = ""
        for n in el.getChildNodes() {
            if let t = n as? TextNode { raw += t.getWholeText() }
            else if let d = n as? DataNode { raw += d.getWholeData() }
            else if let el2 = n as? Element { raw += (try? el2.outerHtml()) ?? "" }
        }
        if raw.isBlank { raw = text(el) }
        return raw.trimmed.nilIfBlank
    }

    static func clean(_ s: String) -> String {
        guard s.contains("<") || s.contains("&") else { return s.collapsedSpaces }
        let t = (try? SwiftSoup.parse(s).text()) ?? s
        return t.collapsedSpaces
    }

    public static func snippet(_ html: String) -> String {
        if html.isBlank { return "" }
        let text = (html.contains("<") || html.contains("&") ? ((try? SwiftSoup.parse(html).text()) ?? html) : html).collapsedSpaces
        if text.count <= snippetMax { return text }
        let cut = text.take(snippetMax)
        let base = cut.contains(" ") ? cut.beforeLast(" ") : cut
        return base.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:")) + "…"
    }

    private static func thumbnail(_ item: Element, _ html: String, _ baseUrl: String) -> String? {
        if let t = all(item, "media:thumbnail").first(where: { !attr($0, "url").isBlank }) { return URLs.resolve(baseUrl, attr(t, "url")) }
        if let c = all(item, "media:content").first(where: { !attr($0, "url").isBlank && (attr($0, "medium") == "image" || attr($0, "type").hasPrefix("image/")) }) {
            return URLs.resolve(baseUrl, attr(c, "url"))
        }
        if let e = all(item, "enclosure").first(where: { attr($0, "type").hasPrefix("image/") && !attr($0, "url").isBlank }) { return URLs.resolve(baseUrl, attr(e, "url")) }
        if let i = all(item, "itunes:image").first(where: { !attr($0, "href").isBlank }) { return URLs.resolve(baseUrl, attr(i, "href")) }
        return firstImage(html, baseUrl)
    }

    private static func firstImage(_ html: String, _ baseUrl: String) -> String? {
        guard html.range(of: "<img", options: .caseInsensitive) != nil, let doc = try? SwiftSoup.parse(html, baseUrl) else { return nil }
        let img = ((try? doc.select("img[src]").array()) ?? []).first { el in
            let w = Int(attr(el, "width"))
            let src = attr(el, "src")
            return (w == nil || w! > 60) && !src.contains("feedburner") && !src.contains("pixel")
        }
        return img.flatMap { URLs.resolve(baseUrl, attr($0, "src")) }
    }

    private static func itemType(_ item: Element, _ link: String) -> ItemType {
        if !all(item, "yt:videoId").isEmpty { return .VIDEO }
        if all(item, "media:content").contains(where: { attr($0, "medium") == "video" || attr($0, "type").hasPrefix("video/") }) { return .VIDEO }
        if all(item, "enclosure").contains(where: { attr($0, "type").hasPrefix("video/") }) { return .VIDEO }
        if !all(item, "media:player").isEmpty { return .VIDEO }
        return looksLikeVideo(link) ? .VIDEO : .ARTICLE
    }

    public static func looksLikeVideo(_ url: String) -> Bool {
        let u = url.lowercased()
        return u.contains("youtube.com/watch") || u.contains("youtu.be/") || u.contains("youtube.com/shorts/") ||
            u.contains("vimeo.com/") || u.contains("/videos/watch/") || (u.contains("/w/") && u.contains("peertube")) ||
            u.contains("dailymotion.com/video") || u.contains("twitch.tv/videos") || u.contains("odysee.com/@") || u.contains("rumble.com/v")
    }

    // MARK: dates

    private static let zones: [String: String] = [
        "UT": "+0000", "UTC": "+0000", "GMT": "+0000", "Z": "+0000",
        "EST": "-0500", "EDT": "-0400", "CST": "-0600", "CDT": "-0500", "MST": "-0700", "MDT": "-0600", "PST": "-0800", "PDT": "-0700",
        "BST": "+0100", "CET": "+0100", "CEST": "+0200", "IST": "+0530", "JST": "+0900", "AEST": "+1000"
    ]

    private static let rfcFormats = ["d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm Z", "d MMM yy HH:mm:ss Z", "d MMM yyyy HH:mm:ss", "d MMMM yyyy HH:mm:ss Z", "d MMM yyyy"]
    private static let isoFormats = ["yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mmXXXXX",
                                     "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"]

    private static let formatters: [String: DateFormatter] = {
        var m: [String: DateFormatter] = [:]
        for f in rfcFormats + isoFormats {
            let d = DateFormatter()
            d.locale = Locale(identifier: "en_US_POSIX")
            d.timeZone = TimeZone(identifier: "UTC")
            d.dateFormat = f
            m[f] = d
        }
        return m
    }()
    private static let lock = NSLock()

    /// Epoch millis, or 0 when the date is missing or unreadable.
    public static func parseDate(_ raw: String?) -> Int64 {
        guard let s0 = raw?.collapsedSpaces, !s0.isEmpty else { return 0 }
        lock.lock(); defer { lock.unlock() }
        let iso = s0.replacingOccurrences(of: "Z", with: "+00:00", options: [.anchored, .backwards])
        for f in isoFormats { if let d = formatters[f]!.date(from: iso) { return Int64(d.timeIntervalSince1970 * 1000) } }
        // RFC 822: drop the weekday (feeds often get it wrong), normalise named zones.
        var s = Rx("^[A-Za-z]{3,9},?\\s+").replace(s0, with: "")
        let last = s.afterLast(" ")
        if let z = zones[last.uppercased()] { s = String(s.dropLast(last.count)) + z }
        for f in rfcFormats { if let d = formatters[f]!.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) } }
        if let d = formatters["yyyy-MM-dd"]!.date(from: s0.take(10)) { return Int64(d.timeIntervalSince1970 * 1000) }
        return 0
    }
}
