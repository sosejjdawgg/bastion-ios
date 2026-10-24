import Foundation

/// Removes click-tracking parameters (utm_*, fbclid, gclid, …) from URLs before they load.
public enum UrlCleaner {
    static let exact: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid", "mc_eid", "yclid",
        "_hsenc", "_hsmi", "igshid", "igsh", "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id", "vero_conv",
        "__s", "ref_src", "ref_url", "s_cid", "twclid", "ttclid", "li_fat_id", "epik", "_openstat", "srsltid",
        "rb_clickid", "wickedid", "_gl", "_ga", "irclickid", "sc_cid", "scid", "ss_source", "zanpid", "gad_source"
    ]
    static let prefixes = ["utm_", "pk_", "mtm_", "hsa_", "matomo_", "at_"]
    static let hostSpecific: [String: Set<String>] = [
        "youtube.com": ["si", "pp"], "youtu.be": ["si"], "spotify.com": ["si"], "instagram.com": ["igsh"],
        "twitter.com": ["t", "s"], "x.com": ["t", "s"]
    ]

    public struct Result { public let url: String; public let removed: Int }

    public static func clean(_ url: String) -> Result {
        guard let qStart = url.firstIndex(of: "?") else { return Result(url: url, removed: 0) }
        let fragIdx = url[qStart...].firstIndex(of: "#")
        let query = String(url[url.index(after: qStart)..<(fragIdx ?? url.endIndex)])
        let fragment = fragIdx.map { String(url[$0...]) } ?? ""
        let host = URLs.host(url) ?? ""
        let hostParams = hostSpecific[Domains.base(host)] ?? []
        var removed = 0
        let kept = query.split(separator: "&", omittingEmptySubsequences: false).filter { part in
            if part.isEmpty { return false }
            let key = (String(part.before("=")).removingPercentEncoding ?? String(part.before("="))).lowercased()
            let drop = exact.contains(key) || hostParams.contains(key) || prefixes.contains { key.hasPrefix($0) }
            if drop { removed += 1 }
            return !drop
        }
        if removed == 0 { return Result(url: url, removed: 0) }
        let base = String(url[..<qStart])
        return Result(url: base + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&")) + fragment, removed: removed)
    }
}

private extension Substring {
    func before(_ s: String) -> Substring { guard let r = range(of: s) else { return self }; return self[..<r.lowerBound] }
}

public enum Domains {
    static let secondLevel: Set<String> = ["co", "com", "org", "net", "gov", "ac", "edu", "ne", "or", "go", "gob", "mil", "nic", "ltd", "plc", "sch"]

    /// Approximate registrable domain ("eTLD+1") without shipping the full public-suffix list.
    public static func base(_ host: String) -> String {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        if h.allSatisfy({ $0.isNumber || $0 == "." }) || h.contains(":") { return h }
        let parts = h.split(separator: ".").map(String.init)
        if parts.count <= 2 { return h }
        let tld = parts[parts.count - 1], sld = parts[parts.count - 2]
        if tld.count == 2 && secondLevel.contains(sld) { return parts.suffix(3).joined(separator: ".") }
        return parts.suffix(2).joined(separator: ".")
    }
}
