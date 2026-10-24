import XCTest
@testable import BastionCore

final class CurationTests: XCTestCase {
    func src(_ id: String, _ name: String, _ feed: String, _ kind: SourceKind, site: String? = nil, live: String? = nil, section: String? = nil) -> MediaSource {
        MediaSource(id: id, name: name, feedUrl: feed, siteUrl: site ?? feed, kind: kind, liveLink: live, section: section)
    }

    func testMergesSiteAndChannel() {
        let yt = "https://www.youtube.com/feeds/videos.xml?channel_id="
        let s = [
            src("a", "GB News", "https://www.gbnews.com/feeds/news.rss", .FEED, site: "https://www.gbnews.com"),
            src("b", "GB News", yt + "UC0vn8ISa4LKMunLbzaXLnOQ", .YOUTUBE),
            src("c", "BBC News - World", "https://feeds.bbci.co.uk/news/world/rss.xml", .FEED, site: "https://www.bbc.co.uk/news"),
            src("d", "BBC News", yt + "UC16niRr50-MSBwiO3YDb3RA", .YOUTUBE),
            src("e", "World news | The Guardian", "https://www.theguardian.com/world/rss", .FEED, site: "https://www.theguardian.com", live: yt + "UCHpw8xwDNhU9gdohEcJu4aA"),
            src("f", "Guardian News", yt + "UCHpw8xwDNhU9gdohEcJu4aA", .YOUTUBE),
            src("g", "Veritasium", yt + "g", .YOUTUBE),
            src("h", "Film Theory", yt + "h", .YOUTUBE, section: "c:ent")
        ]
        let outlets = Outlets.group(s)
        XCTAssertEqual(outlets.count, 5)
        XCTAssertEqual(Set(outlets.first { $0.sourceIds.contains("a") }!.sourceIds), ["a", "b"])
        XCTAssertEqual(Set(outlets.first { $0.sourceIds.contains("c") }!.sourceIds), ["c", "d"])
        XCTAssertEqual(Set(outlets.first { $0.sourceIds.contains("e") }!.sourceIds), ["e", "f"])
        let byId = Dictionary(uniqueKeysWithValues: s.map { ($0.id, $0) })
        var outletOf: [String: Outlet] = [:]
        for o in outlets { for id in o.sourceIds { outletOf[id] = o } }
        func sec(_ id: String, exists: Bool = true) -> Section { Sections.of(byId[id]!, outlet: outletOf[id], all: byId, customExists: { _ in exists }) }
        XCTAssertEqual(sec("b"), .NEWS); XCTAssertEqual(sec("d"), .NEWS); XCTAssertEqual(sec("g"), .MEDIA)
        XCTAssertEqual(sec("h"), Section("c:ent"))
        XCTAssertEqual(sec("h", exists: false), .MEDIA, "deleted module falls back to auto")
    }

    func testClustersLiveNews() throws {
        let data = fixture("news-today.json").data(using: .utf8)!
        let arr = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        let items = arr.map { o in
            MediaItem(id: o["id"] as! String, sourceId: o["s"] as! String, title: o["t"] as! String, url: o["u"] as! String,
                      publishedAt: (o["p"] as! NSNumber).int64Value, snippet: o["d"] as? String ?? "", thumbnailUrl: (o["i"] as? String)?.nilIfBlank,
                      type: (o["v"] as? Bool) == true ? .VIDEO : .ARTICLE)
        }
        let stories = Stories.cluster(items)
        let multi = stories.filter { Set($0.items.map(\.sourceId)).count >= 2 }
        print("\(items.count) items -> \(stories.count) stories, \(multi.count) cross-outlet")
        XCTAssertGreaterThanOrEqual(multi.count, 8)
        XCTAssertTrue(multi.contains { st in st.items.contains { $0.title.contains("Kompany") } && Set(st.items.map(\.sourceId)).count >= 3 })
        let topics = Topics.trending(items)
        print("topics: " + topics.map { "\($0.label)(\($0.count))" }.joined(separator: ", "))
        XCTAssertFalse(topics.isEmpty)
    }

    func testFiltersAndFacets() {
        let now = Clock.now, h: Int64 = 3_600_000
        func item(_ id: String, _ s: String, _ t: String, _ at: Int64, _ type: ItemType = .ARTICLE) -> MediaItem {
            MediaItem(id: id, sourceId: s, title: t, url: "https://x/\(id)", publishedAt: at, snippet: "", thumbnailUrl: nil, type: type)
        }
        let items = [item("1", "a", "Budget row deepens", now - h), item("2", "b", "Budget explained", now - 2 * h, .VIDEO),
                     item("3", "g", "Why the sky is blue", now - 200 * h, .VIDEO), item("4", "a", "Rail strike called off", now - 3 * h)]
        let kind: [String: SourceKind] = ["a": .FEED, "b": .YOUTUBE, "g": .YOUTUBE]
        let group = ["a": "o:a", "b": "o:a", "g": "o:g"]
        func run(_ f: FeedFilter, _ read: Set<String> = []) -> [String] {
            Filtering.apply(items, f, FilterContext(read: read, kindOf: { kind[$0] }, groupOf: { group[$0]! }, nameOf: { $0 }), now: now).map(\.id)
        }
        XCTAssertEqual(run(FeedFilter()), ["1", "2", "4", "3"])
        var f = FeedFilter(); f.sources = ["o:a"]; XCTAssertEqual(run(f), ["1", "2", "4"])
        f = FeedFilter(); f.type = .VIDEO; XCTAssertEqual(run(f), ["2", "3"])
        f = FeedFilter(); f.query = "budget"; XCTAssertEqual(run(f), ["1", "2"])
        f = FeedFilter(); f.unreadOnly = true; XCTAssertEqual(run(f, ["1"]), ["2", "4", "3"])
    }
}

final class BlockingTests: XCTestCase {
    func testEngineMatches() {
        let b = AdblockEngine.Builder()
        b.add("||doubleclick.net^", .AD)
        b.add("/ads/banner*", .AD)
        b.add("||example.com/ad.js^$script,3p", .AD)
        b.add("@@||example.com/ad.js^$script,domain=good.com", .AD)
        b.add("example.com##.promo", .AD)
        b.add("##.ad-box", .AD)
        b.add("example.com##+js(set-constant, foo.bar, false)", .AD)
        let e = b.build()
        XCTAssertNotNil(e.matchBlock("https://ad.doubleclick.net/x", type: AdblockEngine.ReqType.SCRIPT, thirdParty: true, pageHost: "news.com"))
        XCTAssertNotNil(e.matchBlock("https://cdn.site.com/ads/banner1.png", type: AdblockEngine.ReqType.IMAGE, thirdParty: true, pageHost: "news.com"))
        XCTAssertNotNil(e.matchBlock("https://example.com/ad.js", type: AdblockEngine.ReqType.SCRIPT, thirdParty: true, pageHost: "news.com"))
        XCTAssertNil(e.matchBlock("https://example.com/ad.js", type: AdblockEngine.ReqType.SCRIPT, thirdParty: true, pageHost: "good.com"))
        XCTAssertTrue(e.cosmeticCss(host: "www.example.com", flags: 0).contains(".promo"))
        XCTAssertEqual(e.genericCss(for: [".ad-box", ".fine"], host: "x.com", flags: 0).count, 1)
        XCTAssertEqual(e.scriptlets(for: "example.com", flags: 0), ["set-constant, foo.bar, false"])
    }

    func testContentRulesAreValidAndOrdered() throws {
        let set = FilterSet.build(
            texts: ["easylist": ("||ads.example^\n/banner/ads/*$image\n@@||ok.example^$document\n||t.co/track^$important\n||x.y/z^$script,domain=a.com|~b.a.com\n/^regex$/\n", "bundled"),
                    "urlhaus": ("0.0.0.0 evil.example\n", "bundled")],
            own: "", curated: "ANALYTICS|Google|google-analytics.com\nSOCIAL|Meta|facebook.net\n")
        let out = ContentRules.build(set, level: .BALANCED)
        XCTAssertEqual(out.malware.count, 1)
        let ads = try JSONSerialization.jsonObject(with: out.ads[0].data(using: .utf8)!) as! [[String: Any]]
        let malware = try JSONSerialization.jsonObject(with: out.malware[0].data(using: .utf8)!) as! [[String: Any]]
        XCTAssertTrue((JSON.at(malware[0], "trigger", "url-filter") as! String).contains("evil\\.example"))
        // social isn't blocked at Balanced; analytics is
        let filters = ads.compactMap { JSON.at($0, "trigger", "url-filter") as? String }
        XCTAssertTrue(filters.contains { $0.contains("google-analytics") })
        XCTAssertFalse(filters.contains { $0.contains("facebook") })
        // exceptions come after blocks, important after exceptions
        let actions = ads.map { JSON.at($0, "action", "type") as! String }
        let firstIgnore = actions.firstIndex(of: "ignore-previous-rules")!
        XCTAssertTrue(actions[..<firstIgnore].allSatisfy { $0 == "block" })
        XCTAssertTrue((JSON.at(ads.last!, "trigger", "url-filter") as! String).contains("t\\.co"))
        // every url-filter only uses WebKit's regex subset
        for f in filters {
            XCTAssertFalse(f.contains("|") || f.contains("\\w") || f.contains("{") || f.contains("(?"), f)
            XCTAssertNoThrow(try NSRegularExpression(pattern: f))
        }
        XCTAssertEqual(ContentRules.urlFilter("||ads.example^"), "^[^:]+://+([^:/]+\\.)?ads\\.example")
        XCTAssertEqual(ContentRules.urlFilter("/banner/ads/*"), "/banner/ads/")
        // the domain= rule keeps its include list
        let scoped = ads.first { (JSON.at($0, "trigger", "url-filter") as? String)?.contains("x\\.y/z") == true }
        XCTAssertEqual(JSON.at(scoped, "trigger", "if-domain") as? [String], ["*a.com"])
    }

    func testVerdicts() {
        let set = FilterSet.build(texts: ["peterlowe": ("0.0.0.0 tracker.example\n", "bundled"), "urlhaus": ("0.0.0.0 evil.example\n", "bundled")],
                                  own: "", curated: "SOCIAL|Meta|connect.facebook.net\n")
        XCTAssertTrue(set.check("https://evil.example/x", requestHost: "evil.example", pageHost: "a.com", type: 1, pageFlags: 0, level: .OFF, allowlisted: true).block)
        XCTAssertTrue(set.check("https://tracker.example/p", requestHost: "tracker.example", pageHost: "a.com", type: 1, pageFlags: 0, level: .BALANCED, allowlisted: false).block)
        XCTAssertFalse(set.check("https://tracker.example/p", requestHost: "tracker.example", pageHost: "tracker.example", type: 1, pageFlags: 0, level: .BALANCED, allowlisted: false).block)
        XCTAssertFalse(set.check("https://connect.facebook.net/sdk.js", requestHost: "connect.facebook.net", pageHost: "a.com", type: 1, pageFlags: 0, level: .BALANCED, allowlisted: false).block)
        XCTAssertTrue(set.check("https://connect.facebook.net/sdk.js", requestHost: "connect.facebook.net", pageHost: "a.com", type: 1, pageFlags: 0, level: .STRICT, allowlisted: false).block)
    }

    func testUrlCleaner() {
        let r = UrlCleaner.clean("https://www.youtube.com/watch?v=abc&si=xyz&utm_source=x#t=1")
        XCTAssertEqual(r.url, "https://www.youtube.com/watch?v=abc#t=1")
        XCTAssertEqual(r.removed, 2)
    }
}

final class MiscTests: XCTestCase {
    func testGazetteer() {
        let g = Gazetteer.load("Ukraine\t49\t32\tC\tUkraine\t5\nUkrainian\t49\t32\tC\tUkraine\t5\nKyiv\t50.45\t30.5\tT\tUkraine\t3\nUnited Kingdom\t54\t-2\tC\tUnited Kingdom\t5\n")
        XCTAssertEqual(g.locate("Ukrainian drones hit refinery")?.display, "Ukraine")
        XCTAssertEqual(g.locate("Blasts heard in Kyiv as Ukraine braces")?.name, "Kyiv")
        XCTAssertNil(g.locate("Markets steady"))
        let tagged = [("a", g.locate("Kyiv attack")!), ("b", g.locate("Ukraine talks")!)]
        let c = Clusterer.cluster(tagged)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].label, "Ukraine")
    }

    func testWayback() {
        XCTAssertTrue(Wayback.isArchived("https://web.archive.org/web/20190101000000/https://strangeland.com/"))
        XCTAssertEqual(Wayback.originalUrl("https://web.archive.org/web/2019/http:/strangeland.com/"), "http://strangeland.com/")
        XCTAssertEqual(Wayback.requestTimestamp(2012, 3), "20120315")
        XCTAssertTrue(Parking.looksParked("https://www.godaddy.com/domainsearch/find?domainToCheck=strangeland.com"))
        XCTAssertTrue(Parking.looksParked("https://strangeland.com/lander"))
        XCTAssertFalse(Parking.looksParked("https://bbc.co.uk/news"))
    }

    func testRumbleParse() {
        let html = """
        <div class="videostream thumbnail__grid--item"><a class="videostream__link link" href="/v6abc-live-show.html?e9s=x"></a>
        <img class="thumbnail__image" src="https://1a-1791.com/thumb.jpg"><h3 class="thumbnail__title">Live: the show</h3>
        <div class="videostream__status videostream__status--live">LIVE</div><time datetime="2026-10-23T18:00:00+00:00"></time></div>
        <div class="videostream thumbnail__grid--item"><a class="videostream__link link" href="/v6def-episode.html"></a>
        <h3 class="thumbnail__title">Episode 12</h3><span class="videostream__time">1:02:03</span></div>
        """
        let v = Rumble.parseChannel(html, "https://rumble.com/c/Show")
        XCTAssertEqual(v.count, 2)
        XCTAssertTrue(v[0].live)
        XCTAssertEqual(v[1].duration, "1:02:03")
        XCTAssertEqual(v[0].pageUrl, "https://rumble.com/v6abc-live-show.html")
    }

    func testOpmlRoundTrip() {
        let s = [MediaSource(id: "a", name: "BBC & co", feedUrl: "https://feeds.bbci.co.uk/news/rss.xml", siteUrl: "https://bbc.co.uk", kind: .FEED),
                 MediaSource(id: "b", name: "Page", feedUrl: "https://x.com", siteUrl: "https://x.com", kind: .WEB)]
        let text = Opml.write(s)
        XCTAssertEqual(Opml.parse(text).map(\.xmlUrl), ["https://feeds.bbci.co.uk/news/rss.xml"])
        XCTAssertEqual(Opml.parse(text).first?.title, "BBC & co")
        XCTAssertEqual(Opml.parseLinks(text).map(\.xmlUrl), ["https://x.com"])
    }

    func testReader() {
        let p = String(repeating: "This is a long paragraph of article text that should be kept by reader view. ", count: 4)
        let html = "<html><head><meta property='og:title' content='Headline'></head><body><nav>menu</nav><article><p>\(p)</p><h2>Section</h2><p>\(p)</p><div class='share'>share</div></article></body></html>"
        let a = Reader.extract(html, "https://x.com/a")
        XCTAssertEqual(a?.title, "Headline")
        XCTAssertEqual(a?.blocks.map(\.kind), [.PARAGRAPH, .HEADING, .PARAGRAPH])
    }
}
