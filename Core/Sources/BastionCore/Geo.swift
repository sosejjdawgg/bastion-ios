import Foundation

/// A named place from the bundled Natural Earth gazetteer.
public struct Place: Hashable, Sendable {
    public let name: String
    public let lat: Double
    public let lon: Double
    public let kind: Character
    public let country: String
    public let weight: Int

    /// Cities, US states and named regions are more specific than whole countries.
    public var specific: Bool { kind != "C" }

    static let short: [String: String] = [
        "United States of America": "United States", "Dem. Rep. Congo": "DR Congo", "Central African Rep.": "Central African Republic",
        "Bosnia and Herz.": "Bosnia and Herzegovina", "S. Sudan": "South Sudan", "Dominican Rep.": "Dominican Republic",
        "W. Sahara": "Western Sahara", "Solomon Is.": "Solomon Islands", "Falkland Is.": "Falkland Islands", "eSwatini": "Eswatini"
    ]

    /// "UK", "Britain" and "British" all display as "United Kingdom".
    public var display: String { kind == "C" ? (Place.short[country] ?? country.nilIfBlank ?? name) : name }
}

/// Finds where a headline is about, entirely on the phone: matches capitalised words and phrases (up to 4 words)
/// against ~1,300 place names, country names and demonyms ("Ukrainian" → Ukraine).
public final class Gazetteer: @unchecked Sendable {
    let byName: [String: Place]
    public var size: Int { byName.count }

    public init(_ byName: [String: Place]) { self.byName = byName }

    public struct Match { public let place: Place; public let inTitle: Bool; public let position: Int }

    public func locate(_ title: String, _ snippet: String = "") -> Place? {
        let t = matches(title, true)
        let pool = t.isEmpty ? matches(snippet, false) : t
        return pool.sorted { a, b in
            if a.place.specific != b.place.specific { return a.place.specific }
            return a.position < b.position
        }.first?.place
    }

    public func matches(_ text: String, _ inTitle: Bool) -> [Match] {
        if text.isBlank { return [] }
        let words = Gazetteer.tokenize(text)
        var out: [Match] = []
        var i = 0
        while i < words.count {
            var matched = 0
            var n = min(4, words.count - i)
            while n >= 1 {
                guard let c = words[i].first, c.isUppercase else { break }
                if let p = byName[words[i..<(i + n)].joined(separator: " ")] {
                    out.append(Match(place: p, inTitle: inTitle, position: i))
                    matched = n
                    break
                }
                n -= 1
            }
            i += matched > 0 ? matched : 1
        }
        return out
    }

    public static func load(_ text: String) -> Gazetteer {
        var map: [String: Place] = [:]
        for line in text.split(separator: "\n") {
            if line.hasPrefix("#") || line.isEmpty { continue }
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 6, let lat = Double(p[1]), let lon = Double(p[2]), let k = p[3].first, let w = Int(p[5].trimmed) else { continue }
            map[p[0]] = Place(name: p[0], lat: lat, lon: lon, kind: k, country: p[4], weight: w)
        }
        return Gazetteer(map)
    }

    static let splitter = Rx("[\\s—–/(),:;!?\"“”]+")

    /// Words with trailing punctuation and possessives removed; keeps dotted abbreviations like "U.S.".
    public static func tokenize(_ text: String) -> [String] {
        splitter.split(text.replacingOccurrences(of: "’", with: "'")).map { w -> String in
            var s = w.trimmed
            if s.hasSuffix("'s") { s = String(s.dropLast(2)) }
            if s.hasSuffix("'") { s = String(s.dropLast()) }
            while let f = s.first, "'‘[-".contains(f) { s.removeFirst() }
            if !((3...5).contains(s.count) && s.filter({ $0 == "." }).count >= 2) {
                while let l = s.last, ".']-".contains(l) { s.removeLast() }
            }
            return s
        }.filter { !$0.isEmpty }
    }
}

public enum Sphere {
    public static func distanceDeg(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = Double.pi / 180
        let c = sin(lat1 * r) * sin(lat2 * r) + cos(lat1 * r) * cos(lat2 * r) * cos((lon2 - lon1) * r)
        return acos(c.clamped(-1, 1)) / r
    }
}

/// A hotspot on the globe: one or more nearby places and the stories about them.
public struct Cluster<T>: Identifiable {
    public let lat: Double
    public let lon: Double
    public let label: String
    public var places: [(Place, [T])]
    public var count: Int { places.reduce(0) { $0 + $1.1.count } }
    public var id: String { "\(label)@\(lat),\(lon)" }
}

public enum Clusterer {
    /// Greedy clustering: the busiest place seeds a cluster and absorbs places within [radiusDeg]. The cluster is
    /// drawn at its busiest place, so a flare always sits on a real location.
    public static func cluster<T>(_ tagged: [(T, Place)], radiusDeg: Double = 4.5) -> [Cluster<T>] {
        var groups: [String: (Place, [T])] = [:]
        var order: [String] = []
        for (item, p) in tagged {
            if groups[p.display] == nil { groups[p.display] = (p, []); order.append(p.display) }
            groups[p.display]!.1.append(item)
        }
        let byPlace = order.map { groups[$0]! }.enumerated().sorted { a, b in
            a.element.1.count != b.element.1.count ? a.element.1.count > b.element.1.count : a.offset < b.offset
        }.map(\.element)
        var clusters: [[(Place, [T])]] = []
        for entry in byPlace {
            if let i = clusters.firstIndex(where: { c in Sphere.distanceDeg(c[0].0.lat, c[0].0.lon, entry.0.lat, entry.0.lon) <= radiusDeg }) {
                clusters[i].append(entry)
            } else { clusters.append([entry]) }
        }
        return clusters.map { c in Cluster(lat: c[0].0.lat, lon: c[0].0.lon, label: label(c.map(\.0)), places: c) }
            .sorted { $0.count > $1.count }
    }

    static func label(_ places: [Place]) -> String {
        let first = places[0]
        // a city clustered with its own country reads better as the country
        if first.kind == "T", places.count > 1, let c = places.first(where: { $0.kind == "C" && $0.country == first.country }) { return c.display }
        return first.display
    }
}

public enum EventWindow: String, CaseIterable, Sendable {
    case H6, H24, D3
    public var label: String { self == .H6 ? "6H" : self == .H24 ? "24H" : "3D" }
    public var hours: Int { self == .H6 ? 6 : self == .H24 ? 24 : 72 }
}

/// Turns headlines already on the phone into globe hotspots. No extra requests, no third-party geo service.
public final class WorldEvents: @unchecked Sendable {
    public let gazetteer: Gazetteer
    /// Land as unit vectors (x, y, z interleaved).
    public let landDots: [Float]
    private var cache: [String: Place?] = [:]
    private let lock = NSLock()

    public init(gazetteer: Gazetteer, landDots: [Float]) { self.gazetteer = gazetteer; self.landDots = landDots }

    /// land_dots.bin: little-endian Int16 pairs (lat×100, lon×100).
    public static func decodeDots(_ data: Data) -> [Float] {
        let n = data.count / 4
        var out = [Float](repeating: 0, count: n * 3)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<n {
                let la = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: Int16.self))
                let lo = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4 + 2, as: Int16.self))
                let lat = Double(la) / 100 * .pi / 180, lon = Double(lo) / 100 * .pi / 180
                out[i * 3] = Float(cos(lat) * sin(lon))
                out[i * 3 + 1] = Float(sin(lat))
                out[i * 3 + 2] = Float(cos(lat) * cos(lon))
            }
        }
        return out
    }

    public func locate(_ item: MediaItem) -> Place? {
        lock.lock()
        if let c = cache[item.id] { lock.unlock(); return c }
        lock.unlock()
        let p = gazetteer.locate(item.title, item.snippet)
        lock.lock()
        if cache.count > 5000 { cache.removeAll() }
        cache[item.id] = p
        lock.unlock()
        return p
    }

    public func clusters(_ items: [MediaItem], window: EventWindow, now: Int64 = Clock.now) -> [Cluster<MediaItem>] {
        let cutoff = now - Int64(window.hours) * 3_600_000
        let tagged = items.filter { $0.publishedAt >= cutoff }.compactMap { i in locate(i).map { (i, $0) } }
        return Clusterer.cluster(tagged).map { c in
            var c = c
            c.places = c.places.map { ($0.0, $0.1.sorted { $0.publishedAt > $1.publishedAt }) }
            return c
        }
    }
}

// MARK: - Parked domains

/// Recognises parked / "domain for sale" pages, where expired domains get forwarded (GoDaddy, Afternic, Sedo…).
public enum Parking {
    static let sites: Set<String> = [
        "godaddy.com", "afternic.com", "dan.com", "sedo.com", "sedoparking.com", "bodis.com", "parkingcrew.net",
        "above.com", "hugedomains.com", "buydomains.com", "domainmarket.com", "undeveloped.com", "atom.com",
        "squadhelp.com", "brandbucket.com", "uniregistry.com", "namebright.com", "smartname.com", "parklogic.com",
        "domainnamesales.com", "efty.com", "dynadot.com", "sav.com", "domainagents.com", "perfectdomain.com",
        "parkingpage.namecheap.com", "domainlore.uk"
    ]
    static let path = Rx.ci("^/(lander|forsale|for-sale|domain-for-sale|parked|buy-domain)(/|$)")

    public static func isParkingSite(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return sites.contains(h) || sites.contains(Domains.base(h))
    }

    public static func looksParked(_ url: String) -> Bool {
        if isParkingSite(URLs.host(url)) { return true }
        let p = URLs.path(url)
        return path.contains(p) || p.containsCI("/forsale/")
    }

    /// Short pages only, so an article that merely mentions domain sales isn't flagged.
    public static let detectJS = """
    (function(){try{var b=document.body?document.body.innerText||'':'';
    var t=(document.title+' '+b.slice(0,4000)).toLowerCase();
    var hit=/(this|the) domain( name)? (is|may be|might be) (for sale|available)|buy this domain|domain is parked|parked (free|domain)|make an offer on this domain|get this domain|domain for sale|is for sale!|inquire about this domain|this domain has expired/.test(t);
    return hit&&(b.length<6000);}catch(e){return false}})()
    """
}

// MARK: - Wayback Machine

/// Internet Archive lookups: the capture of a page closest to a month, preferring captures that were real pages.
public enum Wayback {
    public struct Snapshot: Sendable { public let url: String; public let timestamp: String; public let original: String }

    public enum Result: Sendable {
        case found(Snapshot, daysFromRequest: Int)
        /// The APIs had nothing; the Wayback Machine may still redirect to something close.
        case tryDirect(String)
        case failed(String)
    }

    static let wayback = Rx.ci("^https?://web\\.archive\\.org/web/(\\d{4,14})[a-z_]*/(.+)$")

    public static func isArchived(_ url: String) -> Bool { wayback.matches(url) }

    /// The live address behind a Wayback URL (or the URL itself).
    public static func originalUrl(_ url: String) -> String {
        guard let m = wayback.find(url) else { return url }
        let orig = m[2]
        if orig.hasPrefix("http") { return Rx("^(https?):/(?!/)").replace(orig, with: "$1://") }
        return "https://\(orig)"
    }

    public static func captureDate(_ url: String) -> DateComponents? { wayback.find(url).map { parse($0[1]) } }

    public static func requestTimestamp(_ year: Int, _ month: Int) -> String { String(format: "%04d%02d15", year, month) }

    public static func closest(_ pageUrl: String, year: Int, month: Int) async -> Result {
        let original = originalUrl(pageUrl)
        let ts = requestTimestamp(year, month)
        let requested = parse(ts)
        let candidates = variants(original)

        // 1. CDX index: nearest *successful* capture (a capture that was a redirect would just replay it).
        for c in candidates.prefix(3) {
            let api = "https://web.archive.org/cdx/search/cdx?url=\(c.urlQueryEncoded)&output=json&fl=timestamp,original&filter=statuscode:200&sort=closest&closest=\(ts)000000&limit=1"
            guard let body = try? await Http.shared.get(api) else { break }
            if let rows = JSON.array(body.nilIfBlank ?? "[]"), rows.count >= 2, let row = rows[1] as? [String], row.count >= 2 {
                let snap = Snapshot(url: "https://web.archive.org/web/\(row[0])/\(row[1])", timestamp: row[0], original: original)
                return .found(snap, daysFromRequest: days(requested, parse(row[0])))
            }
        }
        // 2. Availability API.
        for c in candidates {
            guard let body = try? await Http.shared.get("https://archive.org/wayback/available?url=\(c.urlQueryEncoded)&timestamp=\(ts)") else { break }
            if let closest = JSON.at(JSON.object(body), "archived_snapshots", "closest") as? [String: Any],
               (closest["available"] as? Bool) ?? true, !((closest["status"] as? String) ?? "").hasPrefix("3"),
               let u = closest["url"] as? String, let t = closest["timestamp"] as? String, t.count >= 8 {
                return .found(Snapshot(url: u.replacingOccurrences(of: "http://", with: "https://"), timestamp: t, original: original),
                              daysFromRequest: days(requested, parse(t)))
            }
        }
        // 3. Let the Wayback Machine redirect to whatever is nearest.
        return .tryDirect("https://web.archive.org/web/\(ts)/\(original)")
    }

    /// Address variants, most specific first: as-is, without query, www toggled, bare host.
    static func variants(_ url: String) -> [String] {
        var out: [String] = [url]
        guard let c = URLComponents(string: url), let host = c.host else { return out }
        let scheme = c.scheme ?? "https"
        let path = c.percentEncodedPath
        let toggled = host.hasPrefix("www.") ? String(host.dropFirst(4)) : "www.\(host)"
        for v in ["\(scheme)://\(host)\(path)", "\(scheme)://\(toggled)\(path)", host, toggled] where !out.contains(v) { out.append(v) }
        return out
    }

    public static func parse(_ ts: String) -> DateComponents {
        let y = Int(ts.take(4)) ?? 1996
        let m = Int(String(ts.dropFirst(4).prefix(2))) ?? 1
        let d = Int(String(ts.dropFirst(6).prefix(2))) ?? 1
        return DateComponents(year: y, month: m.clamped(1, 12), day: d.clamped(1, 31))
    }

    static func days(_ a: DateComponents, _ b: DateComponents) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let da = cal.date(from: a), let db = cal.date(from: b) else { return 0 }
        return Int(abs(da.timeIntervalSince(db)) / 86400)
    }

    public static func formatDate(_ c: DateComponents) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMMM yyyy"
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        f.timeZone = cal.timeZone
        return cal.date(from: c).map { f.string(from: $0) } ?? ""
    }

    public static func formatMonth(_ year: Int, _ month: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: 1)).map { f.string(from: $0) } ?? "\(month)/\(year)"
    }
}
