import Foundation
import SwiftSoup

public enum LiveState: String, Codable, Sendable { case UNKNOWN, LIVE, OFFLINE }

public struct LiveStatus: Codable, Equatable, Sendable {
    public var state: LiveState
    public var title: String = ""
    /// What the viewer loads: an embed page, or a direct HLS URL when [hls] is true.
    public var playUrl: String? = nil
    public var hls: Bool = false
    public var thumbnailUrl: String? = nil
    public var viewers: Int64? = nil
    /// Link to the stream on its own site (for "open in browser").
    public var pageUrl: String? = nil
    public var checkedAt: Int64 = Clock.now

    public init(_ state: LiveState, title: String = "", playUrl: String? = nil, hls: Bool = false, thumbnailUrl: String? = nil,
                viewers: Int64? = nil, pageUrl: String? = nil, checkedAt: Int64 = Clock.now) {
        self.state = state; self.title = title; self.playUrl = playUrl; self.hls = hls; self.thumbnailUrl = thumbnailUrl
        self.viewers = viewers; self.pageUrl = pageUrl; self.checkedAt = checkedAt
    }
}

/// Which sources can go live, and how to check them. Uses each platform's public pages or open APIs —
/// no API keys, no accounts.
public enum Live {
    public static let minInterval: Int64 = 3 * 60_000

    /// Channel-type sources, plus news sites with a live channel linked automatically. A linked channel the user
    /// also added directly is only counted once.
    public static func channels(_ sources: [MediaSource]) -> [MediaSource] {
        let all = sources.filter(\.enabled)
        let direct = Set(all.map(\.feedUrl))
        return all.filter { s in
            switch s.kind {
            case .YOUTUBE: return s.feedUrl.contains("channel_id=")
            case .PEERTUBE, .TWITCH, .OWNCAST, .STREAM, .RUMBLE: return true
            case .FEED, .WEB: return s.liveLink != nil && !direct.contains(s.liveLink!)
            }
        }
    }

    /// What to actually check for a source: itself, or the live channel linked to it.
    public static func target(_ s: MediaSource) -> MediaSource {
        guard s.kind.isSite, let link = s.liveLink, let k = s.liveLinkKind else { return s }
        var t = s
        t.kind = k; t.feedUrl = link; t.siteUrl = link
        return t
    }

    public static func probe(_ s: MediaSource, fetch: FetchFn = defaultFetch) async -> LiveStatus {
        do {
            switch s.kind {
            case .YOUTUBE: return try await youtube(s)
            case .PEERTUBE: return try await peertube(s, fetch)
            case .TWITCH: return try await twitch(s)
            case .OWNCAST: return try await owncast(s, fetch)
            case .STREAM: return try await hls(s, fetch)
            case .RUMBLE: return try await rumble(s)
            default: return LiveStatus(.OFFLINE)
            }
        } catch {
            return LiveStatus(.UNKNOWN)
        }
    }

    // MARK: Rumble

    static func rumble(_ s: MediaSource) async throws -> LiveStatus {
        let vids = try await Rumble.channel(s.feedUrl)
        guard let on = vids.first(where: \.live), let embed = try? await Rumble.embedFor(on.pageUrl) else { return LiveStatus(.OFFLINE) }
        return LiveStatus(.LIVE, title: on.title, playUrl: embed, thumbnailUrl: on.thumbnailUrl, pageUrl: on.pageUrl)
    }

    // MARK: YouTube

    static let videoId = Rx("\"videoId\":\"([A-Za-z0-9_-]{11})\"")
    /// The stream's own count is the one labelled "watching now"; recommended streams only say "watching".
    static let watchingNow = Rx("(?:\\\\x22|\")([0-9][0-9,.]*) watching now")

    /// A channel's /live address points at its current broadcast when it has one. "SOCS=CAI" is YouTube's
    /// "reject all" consent answer: no consent wall, no tracking cookies.
    static func youtube(_ s: MediaSource) async throws -> LiveStatus {
        guard let id = Rx("channel_id=([A-Za-z0-9_-]+)").group1(s.feedUrl) else { return LiveStatus(.OFFLINE) }
        let page = try await Http.shared.fetch("https://www.youtube.com/channel/\(id)/live",
                                               headers: ["Cookie": "SOCS=CAI", "Accept-Language": "en", "User-Agent": Http.desktopUA], accept: "text/html")
        if page.code >= 400 { return LiveStatus(.UNKNOWN) }
        let upcoming = page.body.contains("\"upcomingEventData\"") || page.body.contains("\"isUpcoming\":true")
        guard let vid = videoId.group1(page.body), !upcoming, page.body.contains("\"isLiveNow\":true") || page.body.contains("\"isLive\":true") || page.body.contains("watching now") else {
            return LiveStatus(.OFFLINE)
        }
        var title = ""
        if let o = try? await Http.shared.fetch("https://www.youtube.com/oembed?format=json&url=" + "https://www.youtube.com/watch?v=\(vid)".urlQueryEncoded),
           let j = JSON.object(o.body), let t = j["title"] as? String { title = t }
        let viewers = watchingNow.group1(page.body).flatMap(parseCount)
        return LiveStatus(.LIVE, title: title.nilIfBlank ?? s.name,
                          playUrl: "https://www.youtube-nocookie.com/embed/\(vid)?autoplay=1&playsinline=1&rel=0&modestbranding=1",
                          thumbnailUrl: "https://i.ytimg.com/vi/\(vid)/hqdefault_live.jpg", viewers: viewers,
                          pageUrl: "https://www.youtube.com/watch?v=\(vid)")
    }

    // MARK: PeerTube

    static func peertubeApi(_ s: MediaSource, live: Bool) -> String {
        let base = URLs.root(s.feedUrl)
        let q = live ? "isLive=true&count=5&sort=-publishedAt" : "count=25&sort=-publishedAt"
        guard let m = Rx("/(c|a|video-channels|accounts)/([^/?#]+)").find(s.siteUrl) else { return "\(base)/api/v1/videos?\(q)" }
        let kind = (m[1] == "c" || m[1] == "video-channels") ? "video-channels" : "accounts"
        return "\(base)/api/v1/\(kind)/\(m[2])/videos?\(q)"
    }

    /// Embeds with P2P off, so your IP isn't shared with other viewers.
    static func peertube(_ s: MediaSource, _ fetch: FetchFn) async throws -> LiveStatus {
        let base = URLs.root(s.feedUrl)
        let f = try await fetch(peertubeApi(s, live: true))
        if f.code >= 400 { return LiveStatus(.UNKNOWN) }
        guard let arr = JSON.object(f.body)?["data"] as? [[String: Any]] else { return LiveStatus(.OFFLINE) }
        for v in arr {
            let published = (JSON.at(v, "state", "id") as? NSNumber)?.intValue == 1
            guard (v["isLive"] as? Bool) == true, published, let uuid = (v["uuid"] as? String)?.nilIfBlank else { continue }
            return LiveStatus(.LIVE, title: (v["name"] as? String)?.nilIfBlank ?? s.name,
                              playUrl: "\(base)/videos/embed/\(uuid)?autoplay=1&p2p=0&peertubeLink=0&warningTitle=0&title=0",
                              thumbnailUrl: (v["thumbnailPath"] as? String)?.nilIfBlank.map { base + $0 },
                              viewers: (v["viewers"] as? NSNumber)?.int64Value, pageUrl: "\(base)/w/\(uuid)")
        }
        return LiveStatus(.OFFLINE)
    }

    // MARK: Twitch

    static func twitchLogin(_ s: MediaSource) -> String {
        URLs.path(s.siteUrl).trimmingCharacters(in: CharacterSet(charactersIn: "/")).before("/").lowercased()
    }

    /// The channel page's structured data says "isLiveBroadcast": true while the channel is live.
    static func twitch(_ s: MediaSource) async throws -> LiveStatus {
        let name = twitchLogin(s)
        let f = try await Http.shared.fetch("https://www.twitch.tv/\(name)", headers: ["User-Agent": Http.desktopUA], accept: "text/html")
        if f.code >= 400 { return LiveStatus(.UNKNOWN) }
        guard f.body.contains("\"isLiveBroadcast\":true") else { return LiveStatus(.OFFLINE) }
        let title = Rx("\"description\":\"([^\"]{1,200})\"").group1(f.body).map { (try? Entities.unescape($0)) ?? $0 }
        return LiveStatus(.LIVE, title: title ?? s.name,
                          playUrl: "https://player.twitch.tv/?channel=\(name)&parent=bastion.local&autoplay=true",
                          thumbnailUrl: "https://static-cdn.jtvnw.net/previews-ttv/live_user_\(name)-640x360.jpg",
                          pageUrl: "https://www.twitch.tv/\(name)")
    }

    // MARK: Owncast

    static func owncast(_ s: MediaSource, _ fetch: FetchFn) async throws -> LiveStatus {
        var root = s.siteUrl
        while root.hasSuffix("/") { root.removeLast() }
        let f = try await fetch("\(root)/api/status")
        if f.code >= 400 { return LiveStatus(.UNKNOWN) }
        guard let o = JSON.object(f.body), (o["online"] as? Bool) == true else { return LiveStatus(.OFFLINE) }
        return LiveStatus(.LIVE, title: (o["streamTitle"] as? String)?.nilIfBlank ?? s.name, playUrl: "\(root)/embed/video",
                          thumbnailUrl: "\(root)/thumbnail.jpg", viewers: (o["viewerCount"] as? NSNumber)?.int64Value, pageUrl: root)
    }

    // MARK: HLS

    /// A live HLS playlist has no #EXT-X-ENDLIST tag.
    static func hls(_ s: MediaSource, _ fetch: FetchFn) async throws -> LiveStatus {
        let f = try await fetch(s.feedUrl)
        guard f.code < 400, f.body.hasPrefix("#EXTM3U"), !f.body.contains("#EXT-X-ENDLIST") else { return LiveStatus(.OFFLINE) }
        return LiveStatus(.LIVE, title: s.name, playUrl: s.feedUrl, hls: true, pageUrl: s.feedUrl)
    }

    public static func parseCount(_ raw: String) -> Int64? {
        let t = raw.trimmed.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
        guard let last = t.last?.lowercased() else { return nil }
        let mult: Double = last == "k" ? 1_000 : last == "m" ? 1_000_000 : 1
        guard let num = Double(mult > 1 ? String(t.dropLast()) : t) else { return nil }
        return Int64(num * mult)
    }

    /// One-tap starter pack of 24/7 news channels (verified live on 23 Oct 2026).
    public static let newsPack = [
        "https://www.youtube.com/channel/UCNye-wNBqNL5ZzHSJj3l8Bg", // Al Jazeera English
        "https://www.youtube.com/channel/UCknLrEdhRCp1aegoMqRaCZg", // DW News
        "https://www.youtube.com/channel/UCQfwfsi5VrQ8yKZ-UWmAEFg", // France 24 English
        "https://www.youtube.com/channel/UCoMdktPbSTixAyNGwb-UYkQ", // Sky News
        "https://www.youtube.com/channel/UCLA_DiR1FfKNvjuUpBHmylQ"  // NASA
    ]
}

// MARK: - Episodes

/// A past broadcast or upload you can watch while a channel is off air.
public struct Episode: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let pageUrl: String
    /// Embed to play; nil when it has to be looked up first (Rumble).
    public let playUrl: String?
    public let thumbnailUrl: String?
    public let publishedAt: Int64
    public var durationSec: Int64? = nil
    public var durationText: String? = nil
    public var wasLive: Bool = false
}

/// Old episodes for every kind of channel, newest first, each playable in Bastion's sandboxed player.
public enum Episodes {
    public struct Unsupported: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func load(_ source: MediaSource, hideShorts: Bool = false, fetch: FetchFn = defaultFetch) async throws -> [Episode] {
        let s = Live.target(source)
        var list: [Episode]
        switch s.kind {
        case .YOUTUBE: list = try await youtube(s, hideShorts, fetch)
        case .PEERTUBE: list = try await peertube(s, fetch)
        case .TWITCH: list = try await twitch(s)
        case .RUMBLE:
            list = try await Rumble.channel(s.feedUrl).filter { !$0.live && !$0.upcoming }.enumerated().map { i, v in
                Episode(id: "r\(i)" + v.pageUrl.stableHash, title: v.title, pageUrl: v.pageUrl, playUrl: nil, thumbnailUrl: v.thumbnailUrl,
                        publishedAt: v.publishedAt, durationText: v.duration)
            }
        case .OWNCAST: throw Unsupported(message: "Owncast servers don't keep past broadcasts.")
        case .STREAM: throw Unsupported(message: "This stream doesn't publish past episodes.")
        default: throw Unsupported(message: "No video channel is linked to this source yet.")
        }
        list.sort { $0.publishedAt > $1.publishedAt }
        return list
    }

    /// Fills in the player address for episodes that need a lookup.
    public static func playable(_ ep: Episode) async -> String? {
        if let p = ep.playUrl { return p }
        if ep.pageUrl.contains("rumble.com/") { return try? await Rumble.embedFor(ep.pageUrl) }
        return nil
    }

    static let ytId = Rx("(?:v=|/shorts/|youtu\\.be/)([A-Za-z0-9_-]{11})")

    static func youtube(_ s: MediaSource, _ hideShorts: Bool, _ fetch: FetchFn) async throws -> [Episode] {
        let f = try await fetch(s.feedUrl)
        if f.code >= 400 { throw HTTPError("YouTube didn't answer (HTTP \(f.code))") }
        return FeedParser.parse(f.body, f.finalUrl).items.compactMap { it in
            guard let id = ytId.group1(it.url) else { return nil }
            if hideShorts && it.url.contains("/shorts/") { return nil }
            return Episode(id: id, title: it.title, pageUrl: "https://www.youtube.com/watch?v=\(id)",
                           playUrl: "https://www.youtube-nocookie.com/embed/\(id)?autoplay=1&playsinline=1&rel=0&modestbranding=1",
                           thumbnailUrl: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg", publishedAt: it.publishedAt,
                           wasLive: Rx.ci("\\b(live|livestream|stream)\\b").contains(it.title))
        }
    }

    static func peertube(_ s: MediaSource, _ fetch: FetchFn) async throws -> [Episode] {
        let base = URLs.root(s.feedUrl)
        let f = try await fetch(Live.peertubeApi(s, live: false))
        guard let arr = JSON.object(f.body)?["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { v in
            if (v["isLive"] as? Bool) == true && (JSON.at(v, "state", "id") as? NSNumber)?.intValue == 1 { return nil } // on air now
            guard let uuid = (v["uuid"] as? String)?.nilIfBlank else { return nil }
            let d = (v["duration"] as? NSNumber)?.int64Value
            return Episode(id: uuid, title: v["name"] as? String ?? "", pageUrl: "\(base)/w/\(uuid)",
                           playUrl: "\(base)/videos/embed/\(uuid)?autoplay=1&p2p=0&peertubeLink=0&warningTitle=0&title=0",
                           thumbnailUrl: (v["thumbnailPath"] as? String)?.nilIfBlank.map { base + $0 },
                           publishedAt: FeedParser.parseDate(v["publishedAt"] as? String),
                           durationSec: (d ?? 0) > 0 ? d : nil, wasLive: (v["isLive"] as? Bool) == true)
        }
    }

    /// Twitch past broadcasts via the public web client (no login, the same requests twitch.tv makes).
    static func twitch(_ s: MediaSource) async throws -> [Episode] {
        let login = Live.twitchLogin(s)
        let q = "{\"query\":\"query{user(login:\\\"\(login)\\\"){videos(first:25,sort:TIME){edges{node{id title publishedAt lengthSeconds previewThumbnailURL(width:640,height:360)}}}}}\"}"
        let f = try await Http.shared.fetch("https://gql.twitch.tv/gql", headers: ["Client-Id": "kimne78kx3ncx6brgo4mv6wki5h1ko", "Content-Type": "application/json"],
                                            method: "POST", body: Data(q.utf8), accept: "application/json")
        guard let edges = JSON.at(JSON.object(f.body), "data", "user", "videos", "edges") as? [[String: Any]] else { return [] }
        return edges.compactMap { e in
            guard let n = e["node"] as? [String: Any], let id = n["id"] as? String else { return nil }
            let len = (n["lengthSeconds"] as? NSNumber)?.int64Value
            return Episode(id: id, title: (n["title"] as? String)?.nilIfBlank ?? "Past broadcast", pageUrl: "https://www.twitch.tv/videos/\(id)",
                           playUrl: "https://player.twitch.tv/?video=v\(id)&parent=bastion.local&autoplay=true",
                           thumbnailUrl: (n["previewThumbnailURL"] as? String)?.nilIfBlank,
                           publishedAt: FeedParser.parseDate(n["publishedAt"] as? String), durationSec: (len ?? 0) > 0 ? len : nil, wasLive: true)
        }
    }

    public static func formatDuration(_ sec: Int64?) -> String? {
        guard let sec else { return nil }
        let h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
