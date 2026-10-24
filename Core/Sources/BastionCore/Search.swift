import Foundation
import SwiftSoup

public struct SearchResult: Sendable {
    public let title: String
    public let url: String
    public let snippet: String
    public let source: String
    public let position: Int
}

public struct RankedResult: Identifiable, Sendable {
    public let title: String
    public let url: String
    public let host: String
    public let snippet: String
    public let sources: [String]
    public let score: Double
    public let flagged: TrackerInfo?
    public let pastBlocked: Int64
    public var id: String { url }
}

public struct SourceStatus: Sendable, Identifiable {
    public let name: String
    public let count: Int
    public let error: String?
    public let millis: Int
    public var id: String { name }
}

public struct SearchOutcome: Sendable {
    public let query: String
    public let results: [RankedResult]
    public let statuses: [SourceStatus]
}

public protocol SearchSource: Sendable {
    var id: String { get }
    var name: String { get }
    var weight: Double { get }
    func search(_ query: String) async throws -> [SearchResult]
}

/// DuckDuckGo's no-JavaScript HTML endpoint (then the lite endpoint on a bot check). Ads are dropped.
public struct DuckDuckGoSource: SearchSource {
    public let id = "ddg", name = "DuckDuckGo", weight = 1.0
    public init() {}

    public func search(_ query: String) async throws -> [SearchResult] {
        do { return try await html(query) } catch is ChallengeError { return try await lite(query) }
    }

    func post(_ url: String, _ query: String) async throws -> String {
        let body = "q=\(query.urlQueryEncoded)&kl=wt-wt"
        let f = try await Http.shared.fetch(url, headers: ["Referer": url, "Content-Type": "application/x-www-form-urlencoded"],
                                            method: "POST", body: Data(body.utf8), accept: "text/html")
        if f.code == 403 || f.code == 429 { throw ChallengeError("bot check") }
        if f.code >= 400 { throw HTTPError("HTTP \(f.code)") }
        if f.body.contains("anomaly-modal") || f.body.contains("challenge-form") { throw ChallengeError("bot check") }
        return f.body
    }

    func html(_ query: String) async throws -> [SearchResult] {
        guard let doc = Soup.doc(try await post("https://html.duckduckgo.com/html/", query), "https://html.duckduckgo.com/") else { return [] }
        var out: [SearchResult] = []
        for el in Soup.select(doc, "div.result") {
            if el.hasClass("result--ad") || Soup.first(el, ".badge--ad") != nil { continue }
            guard let a = Soup.first(el, "a.result__a"), let url = decode(Soup.attr(a, "href")) else { continue }
            out.append(SearchResult(title: Soup.text(a), url: url, snippet: Soup.text(Soup.first(el, ".result__snippet")), source: name, position: out.count))
        }
        return out
    }

    func lite(_ query: String) async throws -> [SearchResult] {
        guard let doc = Soup.doc(try await post("https://lite.duckduckgo.com/lite/", query), "https://lite.duckduckgo.com/") else { return [] }
        var out: [SearchResult] = []
        for a in Soup.select(doc, "a.result-link") {
            let row = Soup.parents(a).first { $0.tagName() == "tr" }
            if let row, row.hasClass("result-sponsored") || Soup.parents(row).contains(where: { $0.hasClass("result-sponsored") }) { continue }
            guard let url = decode(Soup.attr(a, "href")) else { continue }
            let snippet = (try? row?.nextElementSibling()).flatMap { $0 }.map { Soup.text(Soup.first($0, "td.result-snippet")) } ?? ""
            out.append(SearchResult(title: Soup.text(a), url: url, snippet: snippet, source: name, position: out.count))
        }
        return out
    }

    func decode(_ href: String) -> String? {
        let full = href.hasPrefix("//") ? "https:\(href)" : href
        var target: String? = full
        if let h = URLs.host(full), h.hasSuffix("duckduckgo.com"), URLs.path(full).hasPrefix("/l/") { target = URLs.queryParam(full, "uddg") }
        guard let t = target, t.hasPrefix("http") else { return nil }
        if URLs.host(t)?.hasSuffix("duckduckgo.com") == true { return nil } // DDG's own ad redirects
        return t
    }
}

/// Mojeek: an independent crawler-based index with a no-tracking policy.
public struct MojeekSource: SearchSource {
    public let id = "mojeek", name = "Mojeek", weight = 0.85
    public init() {}
    public func search(_ query: String) async throws -> [SearchResult] {
        let body = try await Http.shared.get("https://www.mojeek.com/search?q=\(query.urlQueryEncoded)")
        guard let doc = Soup.doc(body, "https://www.mojeek.com/") else { return [] }
        var out: [SearchResult] = []
        for li in Soup.select(doc, "ul.results-standard > li") {
            guard let a = Soup.first(li, "h2 a[href]") ?? Soup.first(li, "a.title[href]") else { continue }
            let link = Soup.absUrl(a, "href")
            guard link.hasPrefix("http") else { continue }
            let snippet = Soup.text(Soup.first(li, "p.s")).nilIfBlank ?? Soup.text(Soup.first(li, "p"))
            out.append(SearchResult(title: Soup.text(a), url: link, snippet: snippet, source: name, position: out.count))
        }
        return out
    }
}

/// Wikipedia's official search API — reliable, no scraping, no tracking.
public struct WikipediaSource: SearchSource {
    public let id = "wiki", name = "Wikipedia", weight = 0.7
    public init() {}
    public func search(_ query: String) async throws -> [SearchResult] {
        let url = "https://en.wikipedia.org/w/api.php?action=query&list=search&format=json&srlimit=4&srprop=snippet&srsearch=\(query.urlQueryEncoded)"
        let body = try await Http.shared.get(url, userAgent: "BastionBrowser/0.7 (iOS; privacy browser)")
        guard let arr = JSON.at(JSON.object(body), "query", "search") as? [[String: Any]] else { return [] }
        return arr.enumerated().compactMap { i, o in
            guard let title = o["title"] as? String else { return nil }
            let snippet = FeedParser.snippet(o["snippet"] as? String ?? "")
            return SearchResult(title: "\(title) – Wikipedia", url: "https://en.wikipedia.org/wiki/" + title.replacingOccurrences(of: " ", with: "_").urlQueryEncoded,
                                snippet: snippet, source: name, position: i)
        }
    }
}

/// Meta-search across private sources, ranked on the phone.
public actor SearchEngine {
    public static let shared = SearchEngine()
    public static let allSources: [any SearchSource] = [DuckDuckGoSource(), MojeekSource(), WikipediaSource()]
    private var cache: [String: (Int64, SearchOutcome)] = [:]

    public func search(_ query: String, enabled: Set<String>, lookup: @escaping @Sendable (String) -> TrackerInfo?,
                       pastBlocked: @escaping @Sendable (String) -> Int64) async -> SearchOutcome {
        let active = SearchEngine.allSources.filter { enabled.contains($0.id) }
        let key = query.trimmed.lowercased() + "|" + active.map(\.id).joined(separator: ",")
        if let (t, o) = cache[key], Clock.now - t < 5 * 60_000 { return o }
        if active.isEmpty {
            return SearchOutcome(query: query, results: [], statuses: [SourceStatus(name: "No sources", count: 0, error: "Turn on a source in Controls → Search", millis: 0)])
        }
        let fetched: [(any SearchSource, [SearchResult], SourceStatus)] = await withTaskGroup(of: (Int, [SearchResult], SourceStatus).self) { g in
            for (i, src) in active.enumerated() {
                g.addTask {
                    let t0 = Clock.now
                    var problem: String? = nil
                    var list: [SearchResult] = []
                    do { list = try await src.search(query) }
                    catch let e as ChallengeError { problem = e.message }
                    catch { problem = "unavailable" }
                    return (i, list, SourceStatus(name: src.name, count: list.count, error: problem, millis: Int(Clock.now - t0)))
                }
            }
            var out: [(Int, [SearchResult], SourceStatus)] = []
            for await r in g { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map { (active[$0.0], $0.1, $0.2) }
        }
        let ranked = Ranker.rank(query, fetched.map { ($0.0.name, $0.0.weight, $0.1) }, lookup: lookup, pastBlocked: pastBlocked)
        let outcome = SearchOutcome(query: query, results: ranked, statuses: fetched.map(\.2))
        if !ranked.isEmpty { cache[key] = (Clock.now, outcome); if cache.count > 20 { cache.removeAll() } }
        return outcome
    }
}

/// On-device ranking: weighted position score, agreement bonus across independent sources, query-term overlap,
/// and penalties for known ad / malware domains.
public enum Ranker {
    public static func normalize(_ url: String) -> String {
        let clean = UrlCleaner.clean(url).url
        guard let c = URLComponents(string: clean) else { return clean }
        let host = (c.host ?? "").lowercased().removingPrefix("www.").removingPrefix("m.")
        var path = c.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }
        return host + path + (c.percentEncodedQuery.map { "?\($0)" } ?? "")
    }

    public static func rank(_ query: String, _ lists: [(String, Double, [SearchResult])], lookup: (String) -> TrackerInfo?, pastBlocked: (String) -> Int64) -> [RankedResult] {
        let terms = Array(Set(Rx("[^\\p{L}\\p{N}]+").split(query.lowercased()).filter { $0.count > 1 }))
        var order: [String] = []
        var acc: [String: (best: SearchResult, sources: [String], score: Double)] = [:]
        for (name, weight, results) in lists {
            for r in results {
                let key = normalize(r.url)
                let pos = 10.0 / (1.0 + 0.25 * Double(r.position)) * weight
                if var a = acc[key] {
                    a.score += pos
                    if !a.sources.contains(name) { a.sources.append(name) }
                    if a.best.snippet.count < r.snippet.count { a.best = SearchResult(title: a.best.title, url: a.best.url, snippet: r.snippet, source: a.best.source, position: a.best.position) }
                    acc[key] = a
                } else { acc[key] = (r, [name], pos); order.append(key) }
            }
        }
        return order.compactMap { acc[$0] }.map { a in
            let r = a.best
            let title = r.title.lowercased(), snippet = r.snippet.lowercased()
            let tf = terms.isEmpty ? 0 : (Double(terms.filter { title.contains($0) }.count) * 2 + Double(terms.filter { snippet.contains($0) }.count)) / Double(terms.count)
            let agreement = Double(a.sources.count - 1) * 4
            let host = (URLs.host(r.url) ?? "").removingPrefix("www.")
            let flagged = lookup(host)
            let penalty: Double = flagged.map { $0.category == .MALICIOUS || $0.category == .CRYPTOMINER ? -100 : $0.category == .AD ? -6 : 0 } ?? 0
            return RankedResult(title: r.title.nilIfBlank ?? host, url: UrlCleaner.clean(r.url).url, host: host, snippet: r.snippet, sources: a.sources,
                                score: a.score + tf * 3 + agreement + penalty,
                                flagged: (flagged?.category == .MALICIOUS || flagged?.category == .CRYPTOMINER) ? flagged : nil,
                                pastBlocked: pastBlocked(Domains.base(host)))
        }.sorted { $0.score > $1.score }
    }
}
