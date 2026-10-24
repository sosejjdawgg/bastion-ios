import Foundation

public enum Category: String, Codable, CaseIterable, Sendable {
    case AD, ANALYTICS, SOCIAL, FINGERPRINT, CRYPTOMINER, MALICIOUS

    public var label: String {
        ["Ads", "Analytics trackers", "Social trackers", "Fingerprinters", "Cryptominers", "Malicious"][Category.allCases.firstIndex(of: self)!]
    }
    public var blurb: String {
        switch self {
        case .AD: return "Ad networks and ad servers that follow you between sites"
        case .ANALYTICS: return "Scripts that record what you do and build a profile of you"
        case .SOCIAL: return "Share buttons and embeds that tell social networks where you browse"
        case .FINGERPRINT: return "Identity services that recognise your device without cookies"
        case .CRYPTOMINER: return "Scripts that use your phone's battery to mine cryptocurrency"
        case .MALICIOUS: return "Known malware, phishing and scam hosts"
        }
    }
    public var color: UInt32 { [0xF6AD55, 0x63B3ED, 0xB794F4, 0xF687B3, 0xFC8181, 0xE53E3E][Category.allCases.firstIndex(of: self)!] }
    public var severity: Int { self == .FINGERPRINT ? 2 : (self == .CRYPTOMINER || self == .MALICIOUS) ? 3 : 1 }
}

public struct TrackerInfo: Hashable, Sendable {
    public let domain: String
    public let category: Category
    public let company: String
    public init(domain: String, category: Category, company: String) { self.domain = domain; self.category = category; self.company = company }
}

public enum BlockLevel: String, Codable, CaseIterable, Sendable { case OFF, BALANCED, STRICT }

public struct FilterListDef: Sendable {
    public let id: String, name: String, url: String, category: Category, abp: Bool
}

public struct ListStatus: Sendable, Identifiable {
    public let id: String, name: String, rules: Int, source: String
}

// MARK: - Engine

/// EasyList / uBlock Origin syntax engine: network rules (for the privacy report and for building Safari content
/// rules), cosmetic rules and scriptlets (applied by shields.js).
public final class AdblockEngine: @unchecked Sendable {
    public struct Stats: Sendable { public let network, exceptions, cosmetic, scriptlets: Int }

    public enum ReqType {
        public static let SCRIPT = 1, IMAGE = 2, CSS = 4, XHR = 8, FRAME = 16, MEDIA = 32, FONT = 64, WEBSOCKET = 128
        public static let PING = 256, OTHER = 512, OBJECT = 1024, ALL = 2047
        public static let AMBIGUOUS = SCRIPT | XHR | OTHER | PING | MEDIA
    }

    public static let FLAG_DOCUMENT = 1, FLAG_GENERICHIDE = 2, FLAG_ELEMHIDE = 4

    public final class NetRule: @unchecked Sendable {
        public let raw: String
        public let pattern: String
        public let category: Category
        public let types: Int
        public let thirdParty: Int // 0 any, 1 third-party only, -1 first-party only
        public let include: [String]?
        public let exclude: [String]?
        public let important: Bool
        public let pageFlags: Int
        public let exception: Bool
        private var compiled: Any?
        private let lock = NSLock()

        init(raw: String, pattern: String, category: Category, types: Int, thirdParty: Int, include: [String]?, exclude: [String]?,
             important: Bool, pageFlags: Int, exception: Bool) {
            self.raw = raw; self.pattern = pattern; self.category = category; self.types = types; self.thirdParty = thirdParty
            self.include = include; self.exclude = exclude; self.important = important; self.pageFlags = pageFlags; self.exception = exception
        }

        func matchesUrl(_ url: String) -> Bool {
            lock.lock()
            if compiled == nil { compiled = NetRule.compile(pattern) }
            let c = compiled
            lock.unlock()
            if let s = c as? String { return url.contains(s) }
            if let r = c as? Rx { return r.contains(url) }
            return false
        }

        func matchesContext(_ type: Int, _ third: Bool, _ pageHost: String?) -> Bool {
            if types != 0 && (types & type) == 0 { return false }
            if thirdParty == 1 && !third { return false }
            if thirdParty == -1 && third { return false }
            if let inc = include { guard let h = pageHost, inc.contains(where: { AdblockEngine.hostMatches(h, $0) }) else { return false } }
            if let exc = exclude, let h = pageHost, exc.contains(where: { AdblockEngine.hostMatches(h, $0) }) { return false }
            return true
        }

        static func compile(_ p: String) -> Any {
            if !p.contains(where: { $0 == "*" || $0 == "^" || $0 == "|" }) { return p }
            var sb = ""
            var s = Substring(p)
            if s.hasPrefix("||") { sb += "^[a-z][a-z0-9+.-]*://(?:[^/?#]*\\.)?"; s = s.dropFirst(2) }
            else if s.hasPrefix("|") { sb += "^"; s = s.dropFirst() }
            var end = false
            if s.hasSuffix("|") { end = true; s = s.dropLast() }
            for ch in s {
                switch ch {
                case "*": sb += ".*"
                case "^": sb += "(?:[^\\w\\-.%]|$)"
                default:
                    if "\\.+?()[]{}$|/".contains(ch) { sb += "\\" }
                    sb.append(ch)
                }
            }
            if end { sb += "$" }
            return Rx(sb)
        }
    }

    let blockIndex: [String: [NetRule]], blockUntokened: [NetRule]
    let allowIndex: [String: [NetRule]], allowUntokened: [NetRule]
    let genericSimple: [String: String]
    let genericComplexCss: String
    let specificHide: [String: [String]], specificUnhide: [String: Set<String>]
    let scriptlets: [String: [String]], scriptletExceptions: [String: Set<String>]
    public let stats: Stats
    /// Every network rule, in list order (exceptions included) — the input for Safari content rules.
    public let allNetRules: [NetRule]

    init(blockIndex: [String: [NetRule]], blockUntokened: [NetRule], allowIndex: [String: [NetRule]], allowUntokened: [NetRule],
         genericSimple: [String: String], genericComplexCss: String, specificHide: [String: [String]], specificUnhide: [String: Set<String>],
         scriptlets: [String: [String]], scriptletExceptions: [String: Set<String>], stats: Stats, allNetRules: [NetRule]) {
        self.blockIndex = blockIndex; self.blockUntokened = blockUntokened; self.allowIndex = allowIndex; self.allowUntokened = allowUntokened
        self.genericSimple = genericSimple; self.genericComplexCss = genericComplexCss; self.specificHide = specificHide
        self.specificUnhide = specificUnhide; self.scriptlets = scriptlets; self.scriptletExceptions = scriptletExceptions
        self.stats = stats; self.allNetRules = allNetRules
    }

    public static let empty = Builder().build()

    /// The blocking rule that applies after exceptions, or nil.
    public func matchBlock(_ url: String, type: Int, thirdParty: Bool, pageHost: String?) -> NetRule? {
        let lower = url.lowercased()
        let tokens = AdblockEngine.tokenize(lower)
        guard let block = find(blockIndex, blockUntokened, tokens, lower, type, thirdParty, pageHost) else { return nil }
        if block.important { return block }
        if let allow = find(allowIndex, allowUntokened, tokens, lower, type, thirdParty, pageHost), allow.pageFlags == 0 { return nil }
        return block
    }

    public func isExcepted(_ url: String, type: Int, thirdParty: Bool, pageHost: String?) -> Bool {
        let lower = url.lowercased()
        guard let r = find(allowIndex, allowUntokened, AdblockEngine.tokenize(lower), lower, type, thirdParty, pageHost) else { return false }
        return r.pageFlags == 0
    }

    /// Page-level exceptions: DOCUMENT disables all filtering; GENERICHIDE / ELEMHIDE disable cosmetics.
    public func pageFlags(_ pageUrl: String) -> Int {
        let lower = pageUrl.lowercased()
        var flags = 0
        var seen = Set<ObjectIdentifier>()
        func check(_ r: NetRule) { if r.pageFlags != 0, seen.insert(ObjectIdentifier(r)).inserted, r.matchesUrl(lower) { flags |= r.pageFlags } }
        for t in AdblockEngine.tokenize(lower) { allowIndex[t]?.forEach(check) }
        allowUntokened.forEach(check)
        return flags
    }

    private func find(_ index: [String: [NetRule]], _ untokened: [NetRule], _ tokens: Set<String>, _ url: String,
                      _ type: Int, _ third: Bool, _ pageHost: String?) -> NetRule? {
        var best: NetRule? = nil
        for t in tokens {
            guard let bucket = index[t] else { continue }
            for r in bucket where r.matchesContext(type, third, pageHost) && r.matchesUrl(url) {
                if r.important { return r }
                if best == nil { best = r }
            }
        }
        if let best { return best }
        return untokened.first { $0.matchesContext(type, third, pageHost) && $0.matchesUrl(url) }
    }

    /// CSS for a page: site-specific selectors + complex generic selectors (unless generichide).
    public func cosmeticCss(host: String, flags: Int) -> String {
        if flags & (AdblockEngine.FLAG_DOCUMENT | AdblockEngine.FLAG_ELEMHIDE) != 0 { return "" }
        var unhide = Set<String>()
        AdblockEngine.forEachHostKey(host) { k in if let u = specificUnhide[k] { unhide.formUnion(u) } }
        var sels: [String] = []
        var seen = Set<String>()
        AdblockEngine.forEachHostKey(host) { k in specificHide[k]?.forEach { if !unhide.contains($0) && seen.insert($0).inserted { sels.append($0) } } }
        var sb = sels.isEmpty ? "" : sels.joined(separator: ",\n") + "{display:none!important}\n"
        if flags & AdblockEngine.FLAG_GENERICHIDE == 0 { sb += genericComplexCss }
        return sb
    }

    /// Given classes/ids seen on a page (".foo", "#bar"), CSS hiding the ones that are ad containers.
    public func genericCss(for keys: [String], host: String, flags: Int) -> (css: String, count: Int) {
        if flags & (AdblockEngine.FLAG_DOCUMENT | AdblockEngine.FLAG_ELEMHIDE | AdblockEngine.FLAG_GENERICHIDE) != 0 { return ("", 0) }
        var unhide = Set<String>()
        AdblockEngine.forEachHostKey(host) { k in if let u = specificUnhide[k] { unhide.formUnion(u) } }
        let hits = keys.compactMap { genericSimple[$0] }.filter { !unhide.contains($0) }
        return hits.isEmpty ? ("", 0) : (hits.joined(separator: ",") + "{display:none!important}", hits.count)
    }

    /// Scriptlet calls ("set-constant, foo.bar, false") that apply to this host.
    public func scriptlets(for host: String, flags: Int) -> [String] {
        if flags & AdblockEngine.FLAG_DOCUMENT != 0 { return [] }
        var except = Set<String>()
        AdblockEngine.forEachHostKey(host) { k in if let e = scriptletExceptions[k] { except.formUnion(e) } }
        if except.contains("") { return [] }
        var out: [String] = []
        AdblockEngine.forEachHostKey(host) { k in scriptlets[k]?.forEach { if !except.contains($0) && !out.contains($0) { out.append($0) } } }
        return out
    }

    static let badTokens: Set<String> = ["http", "https", "www", "com", "net", "org", "js", "html", "php", "css", "png", "jpg", "gif", "min", "static", "cdn"]

    static func isWord(_ c: Character) -> Bool { ("a"..."z").contains(c) || ("0"..."9").contains(c) || c == "%" }

    public static func tokenize(_ url: String) -> Set<String> {
        var out = Set<String>()
        var cur = ""
        for c in url {
            if isWord(c) { cur.append(c) } else { if cur.count >= 2 { out.insert(cur) }; cur = "" }
        }
        if cur.count >= 2 { out.insert(cur) }
        return out
    }

    /// The best token to index a pattern by: a full word guaranteed to appear as a token in matching URLs.
    static func indexToken(_ pattern: String) -> String? {
        var p = Array(pattern)
        var leftSafe = false
        if pattern.hasPrefix("||") { p.removeFirst(2); leftSafe = true } else if pattern.hasPrefix("|") { p.removeFirst(); leftSafe = true }
        var rightSafe = false
        if p.last == "|" { p.removeLast(); rightSafe = true }
        var best: String? = nil
        var i = 0
        while i < p.count {
            if isWord(p[i]) {
                let s = i
                while i < p.count && isWord(p[i]) { i += 1 }
                let before: Character = s == 0 ? (leftSafe ? " " : "*") : p[s - 1]
                let after: Character = i == p.count ? (rightSafe ? " " : "*") : p[i]
                let tok = String(p[s..<i])
                if before != "*" && after != "*" && tok.count >= 2 && !badTokens.contains(tok) && tok.count > (best?.count ?? 0) { best = tok }
            } else { i += 1 }
        }
        return best
    }

    public static func hostMatches(_ host: String, _ domain: String) -> Bool {
        if domain.hasSuffix(".*") {
            let stem = String(domain.dropLast(2))
            let base = Domains.base(host)
            let entity = base.before(".")
            let hostNoTld = host.removingSuffix(String(base.dropFirst(entity.count)))
            return hostNoTld == stem || hostNoTld.hasSuffix(".\(stem)")
        }
        return host == domain || host.hasSuffix(".\(domain)")
    }

    /// Calls [f] with every key a host can be listed under: each suffix, and its entity form (example.*).
    public static func forEachHostKey(_ host: String, _ f: (String) -> Void) {
        var h = host.lowercased()
        let base = Domains.base(h)
        let tld = base.after(".")
        while true {
            f(h)
            if h.hasSuffix(".\(tld)") || h == base { f(h.removingSuffix(".\(tld)") + ".*") }
            guard let i = h.firstIndex(of: ".") else { break }
            h = String(h[h.index(after: i)...])
            if !h.contains(".") { break }
        }
    }

    // MARK: Builder

    public final class Builder {
        var blockIndex: [String: [NetRule]] = [:], blockUntokened: [NetRule] = []
        var allowIndex: [String: [NetRule]] = [:], allowUntokened: [NetRule] = []
        var genericSimple: [String: String] = [:]
        var genericComplex: [String] = [], genericComplexSeen = Set<String>(), genericUnhide = Set<String>()
        var specificHide: [String: [String]] = [:], specificUnhide: [String: Set<String>] = [:]
        var scriptlets: [String: [String]] = [:], scriptletExceptions: [String: Set<String>] = [:]
        var seenNet = Set<String>()
        var all: [NetRule] = []
        var net = 0, exc = 0, cos = 0, scr = 0

        public init() {}

        static let simple = Rx("^[.#][A-Za-z_][\\w-]*$")
        static let procedural = [":has-text(", ":-abp-contains(", ":contains(", ":xpath(", ":upward(", ":style(", ":matches-css",
                                 ":min-text-length(", ":watch-attr(", ":matches-path(", ":matches-attr(", ":matches-prop(",
                                 ":others(", ":if(", ":if-not(", ":remove-attr(", ":remove-class(", ":-abp-properties(", ":nth-ancestor("]

        /// Adds one filter line. Returns true if it was understood.
        @discardableResult
        public func add(_ raw: String, _ category: Category) -> Bool {
            let line = raw.trimmed
            guard let f = line.first, f != "!", f != "[" else { return false }
            if line.hasPrefix("#") && !line.hasPrefix("##") && !line.hasPrefix("#@#") { return false }
            if let (idx, sep) = cosmeticSeparator(line) { return addCosmetic(line, idx, sep) }
            return addNetwork(line, category)
        }

        func cosmeticSeparator(_ line: String) -> (String.Index, String)? {
            for sep in ["#@#", "##", "#?#", "#$#", "#%#", "#@?#", "#@$#"] {
                if let r = line.range(of: sep) {
                    if line.hasPrefix("|") || line.hasPrefix("@@") || line[..<r.lowerBound].contains("/") { return nil }
                    return (r.lowerBound, sep)
                }
            }
            return nil
        }

        func addCosmetic(_ line: String, _ idx: String.Index, _ sep: String) -> Bool {
            let domainsPart = String(line[..<idx])
            var body = String(line[line.index(idx, offsetBy: sep.count)...]).trimmed
            let exception = sep.hasPrefix("#@")
            if sep == "#$#" || sep == "#%#" || sep == "#@$#" { return false }
            if body.hasPrefix("^") { return false }
            var includes: [String] = [], excludes: [String] = []
            for d in domainsPart.split(separator: ",") {
                let t = d.trimmed.lowercased()
                if t.isEmpty || t.contains("/") { continue }
                if t.hasPrefix("~") { excludes.append(String(t.dropFirst())) } else { includes.append(t) }
            }
            if body.hasPrefix("+js("), body.hasSuffix(")") {
                let call = String(body.dropFirst(4).dropLast()).trimmed
                if exception {
                    for d in includes.isEmpty ? ["*"] : includes { scriptletExceptions[d, default: []].insert(call) }
                    return true
                }
                if includes.isEmpty || call.hasPrefix("trusted-") { return false }
                for d in includes { scriptlets[d, default: []].append(call) }
                scr += 1
                return true
            }
            body = body.replacingOccurrences(of: ":-abp-has(", with: ":has(")
            if body.hasSuffix(":remove()") { body = String(body.dropLast(9)) }
            if Builder.procedural.contains(where: { body.contains($0) }) { return false }
            if body.isEmpty || body.contains("{") || body.contains("}") { return false }
            if exception {
                if includes.isEmpty { genericUnhide.insert(body) }
                for d in includes { specificUnhide[d, default: []].insert(body) }
                cos += 1
                return true
            }
            if includes.isEmpty {
                for d in excludes { specificUnhide[d, default: []].insert(body) }
                if Builder.simple.matches(body) { genericSimple[body] = body }
                else if genericComplexSeen.insert(body).inserted { genericComplex.append(body) }
            } else {
                for d in includes { specificHide[d, default: []].append(body) }
                for d in excludes { specificUnhide[d, default: []].insert(body) }
            }
            cos += 1
            return true
        }

        func addNetwork(_ raw: String, _ category: Category) -> Bool {
            var line = raw
            if line.contains(" ") || line.contains("\t") { return false }
            let exception = line.hasPrefix("@@")
            if exception { line = String(line.dropFirst(2)) }
            if line.hasPrefix("/") && line.count > 2 && (line.hasSuffix("/") || line.contains("/$")) { return false } // regex rules
            var pattern = line, opts = ""
            if let d = optionsStart(line) { pattern = String(line[..<d]); opts = String(line[line.index(after: d)...]) }
            pattern = pattern.lowercased()
            if pattern == "*" { pattern = "" }
            var types = 0, negTypes = 0, third = 0, important = false, pageFlags = 0
            var include: [String]? = nil, exclude: [String]? = nil
            if !opts.isEmpty {
                for o0 in opts.split(separator: ",") {
                    let o = o0.trimmed
                    let neg = o.hasPrefix("~")
                    let name = o.removingPrefix("~").before("=").lowercased()
                    let t = Builder.typeBit(name)
                    if t != 0 { if neg { negTypes |= t } else { types |= t }; continue }
                    switch name {
                    case "third-party", "3p": third = neg ? -1 : 1
                    case "first-party", "1p": third = neg ? 1 : -1
                    case "domain", "from":
                        for d in o.after("=").split(separator: "|") {
                            let dd = d.trimmed.lowercased()
                            if dd.isEmpty { continue }
                            if dd.hasPrefix("~") { exclude = (exclude ?? []) + [String(dd.dropFirst())] } else { include = (include ?? []) + [dd] }
                        }
                    case "important": important = true
                    case "match-case", "all", "empty", "mp4", "redirect": break
                    case "document", "doc": if exception { pageFlags |= AdblockEngine.FLAG_DOCUMENT } else { return false }
                    case "generichide", "ghide": if exception { pageFlags |= AdblockEngine.FLAG_GENERICHIDE } else { return false }
                    case "elemhide", "ehide": if exception { pageFlags |= AdblockEngine.FLAG_ELEMHIDE } else { return false }
                    default: return false
                    }
                }
            }
            if types == 0 && negTypes != 0 { types = ReqType.ALL & ~negTypes }
            if pattern.isEmpty && include == nil && pageFlags == 0 { return false }
            if pattern.count < 3 && include == nil && pageFlags == 0 { return false }
            guard seenNet.insert((exception ? "@@" : "") + raw).inserted else { return false }
            let rule = NetRule(raw: raw, pattern: pattern.isEmpty ? "*" : pattern, category: category, types: types, thirdParty: third,
                               include: include, exclude: exclude, important: important, pageFlags: pageFlags, exception: exception)
            all.append(rule)
            let token = AdblockEngine.indexToken(pattern)
            if exception {
                if let token { allowIndex[token, default: []].append(rule) } else { allowUntokened.append(rule) }
                exc += 1
            } else {
                if let token { blockIndex[token, default: []].append(rule) } else { blockUntokened.append(rule) }
                net += 1
            }
            return true
        }

        func optionsStart(_ line: String) -> String.Index? {
            guard let i = line.lastIndex(of: "$") else { return nil }
            let after = line[line.index(after: i)...]
            guard let f = after.first, f.isLetter || f == "~" || f == "_" else { return nil }
            return i
        }

        static func typeBit(_ n: String) -> Int {
            switch n {
            case "script": return ReqType.SCRIPT
            case "image": return ReqType.IMAGE
            case "stylesheet", "css": return ReqType.CSS
            case "xmlhttprequest", "xhr", "fetch": return ReqType.XHR
            case "subdocument", "frame": return ReqType.FRAME
            case "media": return ReqType.MEDIA
            case "font": return ReqType.FONT
            case "websocket": return ReqType.WEBSOCKET
            case "ping", "beacon": return ReqType.PING
            case "other": return ReqType.OTHER
            case "object", "object-subrequest": return ReqType.OBJECT
            default: return 0
            }
        }

        public func build() -> AdblockEngine {
            let complex = genericComplex.filter { !genericUnhide.contains($0) }
            for u in genericUnhide { genericSimple.removeValue(forKey: u) }
            var css = ""
            var i = 0
            while i < complex.count {
                css += complex[i..<min(i + 400, complex.count)].joined(separator: ",") + "{display:none!important}\n"
                i += 400
            }
            return AdblockEngine(blockIndex: blockIndex, blockUntokened: blockUntokened, allowIndex: allowIndex, allowUntokened: allowUntokened,
                                 genericSimple: genericSimple, genericComplexCss: css, specificHide: specificHide, specificUnhide: specificUnhide,
                                 scriptlets: scriptlets, scriptletExceptions: scriptletExceptions,
                                 stats: Stats(network: net, exceptions: exc, cosmetic: cos, scriptlets: scr), allNetRules: all)
        }
    }
}

// MARK: - Filter set (domains + engine)

/// Everything Bastion blocks with: a domain map (hosts lists + the curated tracker map with company names) and the
/// EasyList / uBlock engine. Built once from list texts; read-only afterwards.
public final class FilterSet: @unchecked Sendable {
    public static let lists: [FilterListDef] = [
        FilterListDef(id: "easylist", name: "EasyList (ads)", url: "https://easylist.to/easylist/easylist.txt", category: .AD, abp: true),
        FilterListDef(id: "easyprivacy", name: "EasyPrivacy (trackers)", url: "https://easylist.to/easylist/easyprivacy.txt", category: .ANALYTICS, abp: true),
        FilterListDef(id: "ublock", name: "uBlock filters (ads, anti-adblock)", url: "https://ublockorigin.github.io/uAssets/filters/filters.txt", category: .AD, abp: true),
        FilterListDef(id: "ublock-quick", name: "uBlock quick fixes", url: "https://ublockorigin.github.io/uAssets/filters/quick-fixes.txt", category: .AD, abp: true),
        FilterListDef(id: "ublock-badware", name: "uBlock badware risks", url: "https://ublockorigin.github.io/uAssets/filters/badware.txt", category: .MALICIOUS, abp: true),
        FilterListDef(id: "peterlowe", name: "Peter Lowe's ad & tracking servers", url: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext", category: .AD, abp: false),
        FilterListDef(id: "urlhaus", name: "URLhaus malware hosts", url: "https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-hosts.txt", category: .MALICIOUS, abp: false),
        FilterListDef(id: "nocoin", name: "NoCoin cryptominer list", url: "https://raw.githubusercontent.com/hoshsadiq/adblock-nocoin-list/master/hosts.txt", category: .CRYPTOMINER, abp: false)
    ]

    public let domains: [String: TrackerInfo]
    public let engine: AdblockEngine
    public let statuses: [ListStatus]
    public var ruleCount: Int { domains.count + engine.stats.network + engine.stats.exceptions + engine.stats.cosmetic + engine.stats.scriptlets }

    public init(domains: [String: TrackerInfo], engine: AdblockEngine, statuses: [ListStatus]) {
        self.domains = domains; self.engine = engine; self.statuses = statuses
    }

    public static let empty = FilterSet(domains: [:], engine: .empty, statuses: [])

    /// [texts] maps list id → contents (with "source" label); [own] is Bastion's bundled rules; [curated] the tracker map.
    public static func build(texts: [String: (String, String)], own: String, curated: String) -> FilterSet {
        var map: [String: TrackerInfo] = [:]
        map.reserveCapacity(120_000)
        var statuses: [ListStatus] = []
        let b = AdblockEngine.Builder()
        for line in own.split(whereSeparator: \.isNewline) { b.add(String(line), .AD) }
        for l in lists {
            guard let (text, source) = texts[l.id] else { statuses.append(ListStatus(id: l.id, name: l.name, rules: 0, source: "missing")); continue }
            var count = 0
            for sub in text.split(whereSeparator: \.isNewline) {
                let line = String(sub)
                if let d = parseRule(line) {
                    if let e = map[d], e.category.severity >= l.category.severity {} else { map[d] = TrackerInfo(domain: d, category: l.category, company: d) }
                    count += 1
                } else if l.abp && b.add(line, l.category) { count += 1 }
            }
            statuses.append(ListStatus(id: l.id, name: l.name, rules: count, source: source))
        }
        // Curated entries win (they carry company names), but never downgrade a malware verdict.
        var curatedCount = 0
        for sub in curated.split(whereSeparator: \.isNewline) {
            let line = sub.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3, let cat = Category(rawValue: parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let company = parts[1].trimmingCharacters(in: .whitespaces)
            for d in parts[2].split(separator: ",") {
                let dom = d.trimmingCharacters(in: .whitespaces).lowercased()
                if dom.isEmpty { continue }
                if let e = map[dom], e.category == .MALICIOUS, cat != .MALICIOUS { continue }
                map[dom] = TrackerInfo(domain: dom, category: cat, company: company)
                curatedCount += 1
            }
        }
        statuses.append(ListStatus(id: "curated", name: "Bastion curated tracker map", rules: curatedCount, source: "bundled"))
        return FilterSet(domains: map, engine: b.build(), statuses: statuses)
    }

    static let okOptions: Set<String> = ["third-party", "3p", "important", "all"]
    static let hostsPrefix: Set<String> = ["0.0.0.0", "127.0.0.1", "::", "::1"]

    /// A plain domain from an ABP rule (||d^), a hosts-file line or a bare domain line.
    public static func parseRule(_ raw: String) -> String? {
        let line = raw.trimmed
        guard let c = line.first, c != "!", c != "#", c != "[", !line.hasPrefix("@@") else { return nil }
        if line.contains("##") || line.contains("#@#") || line.contains("#?#") || line.contains("#$#") { return nil }
        if line.hasPrefix("||") {
            var rest = String(line.dropFirst(2))
            if let d = rest.firstIndex(of: "$") {
                let opts = rest[rest.index(after: d)...].split(separator: ",")
                if opts.contains(where: { !okOptions.contains($0.trimmingCharacters(in: .whitespaces)) }) { return nil }
                rest = String(rest[..<d])
            }
            if rest.hasSuffix("^") { rest.removeLast() }
            let d = rest.lowercased()
            return isDomain(d) ? d : nil
        }
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if parts.count >= 2 && hostsPrefix.contains(parts[0]) {
            let d = parts[1].lowercased()
            if d == "localhost" || d == "0.0.0.0" || d.hasSuffix(".localdomain") { return nil }
            return isDomain(d) ? d : nil
        }
        if parts.count == 1 { let d = line.lowercased(); return isDomain(d) ? d : nil }
        return nil
    }

    static func isDomain(_ s: String) -> Bool {
        if s.count < 4 || !s.contains(".") || s.hasPrefix(".") || s.hasSuffix(".") { return false }
        return s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" || $0 == "_" }
    }

    public func lookup(_ host: String) -> TrackerInfo? {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        while true {
            if let r = domains[h] { return r }
            guard let i = h.firstIndex(of: ".") else { return nil }
            h = String(h[h.index(after: i)...])
            if !h.contains(".") { return nil }
        }
    }

    static let companyHints: [String: String] = [
        "youtube.com": "YouTube (Google)", "googlevideo.com": "YouTube (Google)", "youtube-nocookie.com": "YouTube (Google)",
        "google.com": "Google", "googleapis.com": "Google", "gstatic.com": "Google"
    ]

    public func companyFor(_ host: String) -> String {
        let base = Domains.base(host)
        return FilterSet.companyHints[base] ?? lookup(host)?.company ?? base
    }

    public struct Verdict { public let block: Bool; public let info: TrackerInfo? }

    /// Would Bastion block this sub-resource? (Mirrors what the compiled Safari rules do; used for the report.)
    public func check(_ url: String, requestHost: String, pageHost: String?, type: Int, pageFlags: Int, level: BlockLevel, allowlisted: Bool) -> Verdict {
        let info = lookup(requestHost)
        if info?.category == .MALICIOUS { return Verdict(block: true, info: info) }
        let pageBase = pageHost.map(Domains.base)
        let third = pageBase == nil || pageBase != Domains.base(requestHost)
        if pageFlags & AdblockEngine.FLAG_DOCUMENT != 0 || allowlisted { return Verdict(block: false, info: third ? info : nil) }
        if let info, third || info.category == .CRYPTOMINER {
            let blocked: Bool
            switch level { case .OFF: blocked = false; case .BALANCED: blocked = info.category != .SOCIAL; case .STRICT: blocked = true }
            if !blocked { return Verdict(block: false, info: info) }
            return Verdict(block: !engine.isExcepted(url, type: type, thirdParty: third, pageHost: pageHost), info: info)
        }
        guard let rule = engine.matchBlock(url, type: type, thirdParty: third, pageHost: pageHost) else { return Verdict(block: false, info: nil) }
        if level == .OFF && rule.category != .MALICIOUS { return Verdict(block: false, info: nil) }
        return Verdict(block: true, info: TrackerInfo(domain: requestHost, category: rule.category, company: companyFor(requestHost)))
    }
}

// MARK: - Safari content rules

/// Converts Bastion's filter set into WebKit content-blocker JSON (the only way to block requests on iOS).
/// WebKit's url-filter is a small regex subset (no alternation, no \w, no {n}), so patterns are translated with care
/// and anything that can't be expressed exactly is skipped rather than over-blocking.
public enum ContentRules {
    public struct Output: Sendable {
        /// Separate lists so each compiles fast and the malware list can stay on when shields are down.
        public let malware: [String]
        public let ads: [String]
        public var ruleCount: Int
    }

    static let chunk = 40_000

    public static func build(_ set: FilterSet, level: BlockLevel) -> Output {
        var malware: [[String: Any]] = []
        var blocks: [[String: Any]] = []
        var exceptions: [[String: Any]] = []
        var important: [[String: Any]] = []

        // 1. Domains (third-party, like Android: a site's own subdomains still load).
        let sorted = set.domains.values.sorted { $0.domain < $1.domain }
        for info in sorted {
            let filter = "^[^:]+://+([^:/]+\\.)?" + escape(info.domain) + "[:/]"
            switch info.category {
            case .MALICIOUS:
                malware.append(rule(filter, action: "block"))
            case .CRYPTOMINER:
                if level != .OFF { blocks.append(rule(filter, action: "block")) }
            case .SOCIAL:
                if level == .STRICT { blocks.append(rule(filter, action: "block", trigger: ["load-type": ["third-party"]])) }
            default:
                if level != .OFF { blocks.append(rule(filter, action: "block", trigger: ["load-type": ["third-party"]])) }
            }
        }

        // 2. URL-pattern rules from the lists.
        if level != .OFF {
            for r in set.engine.allNetRules {
                if r.exception {
                    if r.pageFlags & AdblockEngine.FLAG_DOCUMENT != 0 {
                        // @@||site.com^$document → everything allowed on that site
                        if let host = plainHost(r.pattern) { exceptions.append(rule(".*", action: "ignore-previous-rules", trigger: ["if-domain": ["*" + host]])) }
                        continue
                    }
                    if r.pageFlags != 0 { continue }
                    if let j = convert(r) { exceptions.append(j(["type": "ignore-previous-rules"])) }
                } else if let j = convert(r) {
                    let out = j(["type": "block"])
                    if r.category == .MALICIOUS { malware.append(out) } else if r.important { important.append(out) } else { blocks.append(out) }
                }
            }
        }
        let ads = blocks + exceptions + important
        return Output(malware: chunks(malware), ads: chunks(ads), ruleCount: malware.count + ads.count)
    }

    static func chunks(_ rules: [[String: Any]]) -> [String] {
        if rules.isEmpty { return [] }
        var out: [String] = []
        var i = 0
        while i < rules.count {
            out.append(JSON.string(Array(rules[i..<min(i + chunk, rules.count)])))
            i += chunk
        }
        return out
    }

    static func rule(_ filter: String, action: String, trigger extra: [String: Any] = [:]) -> [String: Any] {
        var t: [String: Any] = ["url-filter": filter]
        for (k, v) in extra { t[k] = v }
        return ["trigger": t, "action": ["type": action]]
    }

    static func plainHost(_ p: String) -> String? {
        guard p.hasPrefix("||") else { return nil }
        var h = String(p.dropFirst(2))
        if h.hasSuffix("^") { h.removeLast() }
        return FilterSet.isDomain(h) ? h : nil
    }

    /// Escapes a literal for WebKit's regex subset.
    static func escape(_ s: String) -> String {
        var o = ""
        for c in s {
            if "\\.+?()[]{}$^*|".contains(c) { o += "\\" }
            o.append(c)
        }
        return o
    }

    /// uBO pattern → url-filter, or nil when it can't be expressed safely.
    public static func urlFilter(_ pattern: String) -> String? {
        if pattern == "*" { return ".*" }
        guard pattern.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 }) else { return nil }
        var s = Substring(pattern)
        var out = ""
        if s.hasPrefix("||") { out = "^[^:]+://+([^:/]+\\.)?"; s = s.dropFirst(2) }
        else if s.hasPrefix("|") { out = "^"; s = s.dropFirst() }
        var end = false
        if s.hasSuffix("|") { end = true; s = s.dropLast() }
        // a stray "|" or "$" inside means options that weren't understood — skip rather than guess
        if s.contains("|") || s.contains("$") { return nil }
        while s.hasPrefix("*") { s = s.dropFirst() }
        while s.hasSuffix("*") { s = s.dropLast() }
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            switch c {
            case "*": out += ".*"
            case "^":
                // separator; at the very end it may also be end-of-URL, which the subset can't say — so just stop there
                if i == chars.count - 1 { if !end { break } else { out += "[^a-zA-Z0-9_.%-]" } } else { out += "[^a-zA-Z0-9_.%-]" }
            default:
                if "\\.+?()[]{}$|".contains(c) { out += "\\" }
                out.append(c)
            }
        }
        if end { out += "$" }
        return out.count >= 3 ? out : nil
    }

    static let typeNames: [(Int, [String])] = [
        (AdblockEngine.ReqType.SCRIPT, ["script"]), (AdblockEngine.ReqType.IMAGE, ["image"]), (AdblockEngine.ReqType.CSS, ["style-sheet"]),
        (AdblockEngine.ReqType.XHR, ["raw"]), (AdblockEngine.ReqType.FRAME, ["document"]), (AdblockEngine.ReqType.MEDIA, ["media"]),
        (AdblockEngine.ReqType.FONT, ["font"]), (AdblockEngine.ReqType.WEBSOCKET, ["raw"]), (AdblockEngine.ReqType.PING, ["ping"]),
        (AdblockEngine.ReqType.OTHER, ["raw"]), (AdblockEngine.ReqType.OBJECT, ["raw"])
    ]

    /// A rule's trigger, as a function of its action.
    static func convert(_ r: AdblockEngine.NetRule) -> (([String: Any]) -> [String: Any])? {
        guard let filter = urlFilter(r.pattern) else { return nil }
        var trigger: [String: Any] = ["url-filter": filter]
        if r.types != 0 && r.types != AdblockEngine.ReqType.ALL {
            var names: [String] = []
            for (bit, n) in typeNames where r.types & bit != 0 { for x in n where !names.contains(x) { names.append(x) } }
            trigger["resource-type"] = names
            if r.types & AdblockEngine.ReqType.FRAME != 0 && r.types == AdblockEngine.ReqType.FRAME { trigger["load-context"] = ["child-frame"] }
        } else if !r.exception {
            // never block the page you asked for with a list rule
            trigger["resource-type"] = ["script", "image", "style-sheet", "raw", "media", "font", "ping", "svg-document", "popup"]
        }
        if r.thirdParty == 1 { trigger["load-type"] = ["third-party"] } else if r.thirdParty == -1 { trigger["load-type"] = ["first-party"] }
        if let inc = r.include {
            let ds = inc.filter { !$0.hasSuffix(".*") && FilterSet.isDomain($0) }.map { "*" + $0 }
            if ds.isEmpty { return nil }
            trigger["if-domain"] = ds
        } else if let exc = r.exclude {
            let ds = exc.filter { !$0.hasSuffix(".*") && FilterSet.isDomain($0) }.map { "*" + $0 }
            if !ds.isEmpty { trigger["unless-domain"] = ds }
        }
        return { action in ["trigger": trigger, "action": action] }
    }
}
