import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP response, trimmed to what Bastion needs.
public struct Fetched: Sendable {
    public var finalUrl: String
    public var code: Int
    public var body: String
    public var contentType: String
    public var etag: String?
    public var lastModified: String?
    public init(finalUrl: String, code: Int, body: String, contentType: String = "", etag: String? = nil, lastModified: String? = nil) {
        self.finalUrl = finalUrl; self.code = code; self.body = body; self.contentType = contentType; self.etag = etag; self.lastModified = lastModified
    }
}

public struct ChallengeError: Error, LocalizedError {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

public struct HTTPError: Error, LocalizedError {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// All network access goes through here: no cookie storage, no cache, privacy headers on every request.
public final class Http: @unchecked Sendable {
    public static let shared = Http()

    /// Safari on iPhone, without device-specific detail.
    public static var userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"
    public static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"
    public static let maxBytes = 3 * 1024 * 1024

    private let session: URLSession

    public init() {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        session = URLSession(configuration: c)
    }

    /// GET (or POST when [body] is set). Never throws for HTTP status codes; check `code`.
    public func fetch(_ url: String, etag: String? = nil, lastModified: String? = nil, headers: [String: String] = [:],
                      method: String = "GET", body: Data? = nil, accept: String? = nil) async throws -> Fetched {
        guard let u = URL(string: url) else { throw HTTPError("Bad address") }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.httpBody = body
        req.setValue(Http.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        req.setValue("1", forHTTPHeaderField: "DNT")
        req.setValue("1", forHTTPHeaderField: "Sec-GPC")
        req.setValue(accept ?? "application/rss+xml, application/atom+xml, application/feed+json, application/xml;q=0.9, text/xml;q=0.9, text/html;q=0.8, */*;q=0.5",
                     forHTTPHeaderField: "Accept")
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { req.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let (data, response): (Data, URLResponse?) = try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: req) { d, r, e in
                if let e { cont.resume(throwing: e) } else { cont.resume(returning: (d ?? Data(), r)) }
            }
            task.resume()
        }
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        let trimmed = data.count > Http.maxBytes ? data.prefix(Http.maxBytes) : data
        let ct = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let text = code == 304 ? "" : Http.decode(Data(trimmed), contentType: ct)
        return Fetched(finalUrl: response?.url?.absoluteString ?? url, code: code, body: text, contentType: ct,
                       etag: http?.value(forHTTPHeaderField: "ETag"), lastModified: http?.value(forHTTPHeaderField: "Last-Modified"))
    }

    /// Body text or a thrown error for 4xx/5xx (403/429 are reported as bot checks).
    public func get(_ url: String, referer: String? = nil, userAgent: String? = nil) async throws -> String {
        var h: [String: String] = [:]
        if let referer { h["Referer"] = referer }
        if let userAgent { h["User-Agent"] = userAgent }
        let f = try await fetch(url, headers: h, accept: "*/*")
        if f.code == 403 || f.code == 429 { throw ChallengeError("rate limited (HTTP \(f.code))") }
        if f.code >= 400 { throw HTTPError("HTTP \(f.code)") }
        return f.body
    }

    static func decode(_ data: Data, contentType: String) -> String {
        if let cs = Rx.ci("charset=\"?([A-Za-z0-9_-]+)").group1(contentType), let enc = encoding(cs), let s = String(data: data, encoding: enc) {
            return s
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        let head = String(decoding: data.prefix(400), as: UTF8.self)
        if let cs = Rx("encoding=[\"']([A-Za-z0-9_-]+)[\"']").group1(head) ?? Rx.ci("charset=[\"']?([A-Za-z0-9_-]+)").group1(head),
           let enc = encoding(cs), let s = String(data: data, encoding: enc) { return s }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    private static func encoding(_ name: String) -> String.Encoding? {
        switch name.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "iso-8859-1", "latin1", "iso8859-1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        case "utf-16": return .utf16
        case "ascii", "us-ascii": return .ascii
        default: return nil
        }
    }
}

/// Lets tests and the app swap the network (e.g. a hidden WebView for Cloudflare-checked pages).
public typealias FetchFn = @Sendable (String) async throws -> Fetched

public let defaultFetch: FetchFn = { try await Http.shared.fetch($0) }
