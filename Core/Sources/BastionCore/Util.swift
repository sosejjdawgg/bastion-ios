import Foundation

// MARK: - Regex

/// A small, cached wrapper over NSRegularExpression with Kotlin-like helpers.
public final class Rx: @unchecked Sendable {
    public let re: NSRegularExpression

    public init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        // Patterns are compile-time constants; a bad one is a programming error, but never crash in production.
        re = (try? NSRegularExpression(pattern: pattern, options: options)) ?? (try! NSRegularExpression(pattern: "(?!)"))
    }

    public static func ci(_ pattern: String) -> Rx { Rx(pattern, [.caseInsensitive]) }

    public func matches(_ s: String) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: r) else { return false }
        return m.range.location == 0 && m.range.length == r.length
    }

    public func contains(_ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Groups of the first match: [0] = whole match. Missing groups are "".
    public func find(_ s: String) -> [String]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return Rx.groups(m, in: s)
    }

    /// First capture group of the first match.
    public func group1(_ s: String) -> String? { find(s).flatMap { $0.count > 1 ? $0[1] : nil } }

    public func findAll(_ s: String) -> [(groups: [String], range: Range<String.Index>)] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            guard let r = Range(m.range, in: s) else { return nil }
            return (Rx.groups(m, in: s), r)
        }
    }

    public func replace(_ s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    public func split(_ s: String) -> [String] {
        var out: [String] = []
        var last = s.startIndex
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s) else { continue }
            out.append(String(s[last..<r.lowerBound]))
            last = r.upperBound
        }
        out.append(String(s[last...]))
        return out
    }

    private static func groups(_ m: NSTextCheckingResult, in s: String) -> [String] {
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let rr = Range(r, in: s) else { return "" }
            return String(s[rr])
        }
    }
}

// MARK: - String helpers

public extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfBlank: String? { trimmed.isEmpty ? nil : self }
    var isBlank: Bool { trimmed.isEmpty }

    func before(_ s: String) -> String {
        guard let r = range(of: s) else { return self }
        return String(self[..<r.lowerBound])
    }
    func after(_ s: String) -> String {
        guard let r = range(of: s) else { return self }
        return String(self[r.upperBound...])
    }
    func beforeLast(_ s: String) -> String {
        guard let r = range(of: s, options: .backwards) else { return self }
        return String(self[..<r.lowerBound])
    }
    func afterLast(_ s: String) -> String {
        guard let r = range(of: s, options: .backwards) else { return self }
        return String(self[r.upperBound...])
    }
    func removingPrefix(_ p: String) -> String { hasPrefix(p) ? String(dropFirst(p.count)) : self }
    func removingSuffix(_ p: String) -> String { hasSuffix(p) ? String(dropLast(p.count)) : self }
    func take(_ n: Int) -> String { String(prefix(max(0, n))) }
    func containsCI(_ s: String) -> Bool { range(of: s, options: .caseInsensitive) != nil }

    /// Collapses runs of whitespace into one space.
    var collapsedSpaces: String {
        split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Escapes for HTML text and attributes.
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Percent-encoded for a query value.
    var urlQueryEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }

    /// Stable 64-bit FNV-1a hash as hex — used for item and source ids.
    var stableHash: String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }

    var javaHash: Int32 {
        var h: Int32 = 0
        for u in utf16 { h = h &* 31 &+ Int32(u) }
        return h
    }
}

// MARK: - URLs

public enum URLs {
    /// Lowercased host without a leading "www.", or nil.
    public static func host(_ url: String) -> String? {
        URLComponents(string: url)?.host?.lowercased()
    }

    public static func scheme(_ url: String) -> String? { URLComponents(string: url)?.scheme?.lowercased() }

    public static func path(_ url: String) -> String { URLComponents(string: url)?.path ?? "" }

    /// "https://host[:port]" for a URL.
    public static func root(_ url: String) -> String {
        guard let c = URLComponents(string: url), let s = c.scheme, let h = c.host else { return url }
        return "\(s)://\(h)" + (c.port.map { ":\($0)" } ?? "")
    }

    /// Resolves [href] against [base]; returns only http(s) results.
    public static func resolve(_ base: String, _ href: String) -> String? {
        let h = href.trimmed
        if h.isEmpty || h.hasPrefix("javascript:") || h.hasPrefix("mailto:") || h.hasPrefix("#") { return nil }
        let fixed = h.replacingOccurrences(of: " ", with: "%20")
        let resolved: String?
        if let b = URL(string: base), let u = URL(string: fixed, relativeTo: b) { resolved = u.absoluteString }
        else if fixed.hasPrefix("http") { resolved = fixed } else { resolved = nil }
        guard let r = resolved, r.hasPrefix("http://") || r.hasPrefix("https://") else { return nil }
        return r
    }

    public static func queryParam(_ url: String, _ name: String) -> String? {
        URLComponents(string: url)?.queryItems?.first(where: { $0.name == name })?.value
    }
}

// MARK: - Time

public enum Clock {
    /// Epoch milliseconds, like the Android build (stored values are interchangeable).
    public static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

public func timeAgo(_ t: Int64, now: Int64 = Clock.now) -> String {
    let s = (now - t) / 1000
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86400 { return "\(s / 3600)h ago" }
    return "\(s / 86400)d ago"
}

public func formatCount(_ n: Int64) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 10_000 { return String(format: "%.1fk", Double(n) / 1000) }
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

public extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}

public extension Substring {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
