import XCTest
@testable import BastionCore

func fixture(_ name: String) -> String {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
        ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    return try! String(contentsOf: url, encoding: .utf8)
}

final class FeedParserTests: XCTestCase {
    func check(_ name: String, _ base: String, minItems: Int = 5, since: Int64 = 1_700_000_000_000) -> ParsedFeed {
        let body = fixture(name)
        let f = FeedParser.parse(body, base)
        print("\(name): '\(f.title)' \(f.items.count) items; first='\(f.items.first?.title.take(60) ?? "")' date=\(f.items.first?.publishedAt ?? 0) thumb=\(f.items.first?.thumbnailUrl?.take(60) ?? "-") type=\(f.items.first?.type.rawValue ?? "")")
        XCTAssertTrue(FeedParser.isFeed(body), name)
        XCTAssertGreaterThanOrEqual(f.items.count, minItems, name)
        XCTAssertFalse(f.title.isBlank, name)
        for it in f.items {
            XCTAssertTrue(it.url.hasPrefix("http"), it.url)
            XCTAssertFalse(it.title.isBlank)
            XCTAssertFalse(it.snippet.contains("<p") || it.snippet.contains("<img"), it.snippet)
        }
        XCTAssertGreaterThanOrEqual(f.items.filter { $0.publishedAt > since }.count, f.items.count / 2, "\(name) dated")
        return f
    }

    func testBBC() { let f = check("bbc.xml", "https://feeds.bbci.co.uk/news/rss.xml"); XCTAssertNotNil(f.items.first?.thumbnailUrl) }
    func testGuardian() { _ = check("guardian.xml", "https://www.theguardian.com/world/rss") }
    func testAlJazeera() { _ = check("aljazeera.xml", "https://www.aljazeera.com/xml/rss/all.xml") }
    func testVerge() { _ = check("verge.atom", "https://www.theverge.com/rss/index.xml") }
    func testYouTube() {
        let f = check("youtube.xml", "https://www.youtube.com/feeds/videos.xml?channel_id=x")
        XCTAssertEqual(f.items.first?.type, .VIDEO)
        XCTAssertNotNil(f.items.first?.thumbnailUrl)
    }
    func testPeerTube() { _ = check("peertube.xml", "https://framatube.org/feeds/videos.xml", minItems: 3) }
    func testJsonFeed() { _ = check("jsonfeed.json", "https://example.org/feed.json", minItems: 2, since: 1_500_000_000_000) }

    func testDiscoverFeeds() {
        let feeds = FeedParser.discoverFeeds(fixture("bbc-page.html"), "https://www.bbc.co.uk/news")
        print("feeds: \(feeds)")
        XCTAssertFalse(feeds.isEmpty)
    }

    func testScrapeHeadlines() {
        let html = """
        <html><head><title>Example Times</title></head><body><nav><a href="/x">Nav link that should be ignored by scraper</a></nav>
        <article><h2><a href="/news/world-1">Leaders meet in Geneva to discuss the ceasefire plan</a></h2><p>Talks resumed on Friday.</p></article>
        <article><h2><a href="/news/world-2">Storm brings heavy rain and flooding to the coast</a></h2></article>
        <h3><a href="https://other.com/a">Off-site link should be skipped entirely by scraper</a></h3>
        <h3><a href="/news/uk-3">Rail strike called off after last-minute agreement</a></h3></body></html>
        """
        let f = FeedParser.scrapeHeadlines(html, "https://example.com/")
        XCTAssertEqual(f.items.map(\.url), ["https://example.com/news/world-1", "https://example.com/news/world-2", "https://example.com/news/uk-3"])
        XCTAssertEqual(f.items.first?.snippet, "Talks resumed on Friday.")
        XCTAssertEqual(f.title, "Example Times")
    }

    func testDates() {
        XCTAssertEqual(FeedParser.parseDate("Thu, 23 Oct 2026 18:04:11 GMT"), 1792778651000)
        XCTAssertEqual(FeedParser.parseDate("Mon, 23 Oct 2026 18:04:11 +0000"), 1792778651000) // wrong weekday tolerated
        XCTAssertEqual(FeedParser.parseDate("2026-10-23T18:04:11Z"), 1792778651000)
        XCTAssertEqual(FeedParser.parseDate("2026-10-23T19:04:11+01:00"), 1792778651000)
        XCTAssertEqual(FeedParser.parseDate("garbage"), 0)
    }
}
