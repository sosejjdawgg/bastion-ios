import XCTest
@testable import BastionCore

final class RealListsTests: XCTestCase {
    func testRealLists() throws {
        let dir = "/home/claude/bastion/app/src/main/assets/"
        guard FileManager.default.fileExists(atPath: dir) else { throw XCTSkip("no lists") }
        var texts: [String: (String, String)] = [:]
        for l in FilterSet.lists { if let t = try? String(contentsOfFile: dir + "lists/\(l.id).txt", encoding: .utf8) { texts[l.id] = (t, "bundled") } }
        let t0 = Date()
        let set = FilterSet.build(texts: texts, own: (try? String(contentsOfFile: dir + "bastion-filters.txt", encoding: .utf8)) ?? "",
                                  curated: (try? String(contentsOfFile: dir + "trackers.txt", encoding: .utf8)) ?? "")
        print("built in \(Date().timeIntervalSince(t0))s: domains=\(set.domains.count) stats=\(set.engine.stats) total=\(set.ruleCount)")
        let t1 = Date()
        let out = ContentRules.build(set, level: .BALANCED)
        print("content rules in \(Date().timeIntervalSince(t1))s: \(out.ruleCount) rules, ads lists=\(out.ads.count) malware lists=\(out.malware.count), bytes=\(out.ads.reduce(0) { $0 + $1.count })")
        var bad = 0
        for j in out.ads + out.malware {
            let rules = try JSONSerialization.jsonObject(with: j.data(using: .utf8)!) as! [[String: Any]]
            for r in rules {
                let f = JSON.at(r, "trigger", "url-filter") as! String
                if f.contains("|") || f.contains("\\w") || f.contains("{") || f.contains("(?") || (try? NSRegularExpression(pattern: f)) == nil || !f.allSatisfy({ $0.isASCII }) {
                    bad += 1; if bad < 10 { print("BAD: \(f)") }
                }
            }
        }
        XCTAssertEqual(bad, 0)
        XCTAssertGreaterThan(out.ruleCount, 50_000)
        // YouTube ads still caught by the engine (for the report)
        XCTAssertNotNil(set.engine.matchBlock("https://www.youtube.com/pagead/viewthroughconversion/1", type: AdblockEngine.ReqType.XHR, thirdParty: false, pageHost: "www.youtube.com"))
        XCTAssertTrue(set.check("https://www.google-analytics.com/analytics.js", requestHost: "www.google-analytics.com", pageHost: "bbc.co.uk", type: 1, pageFlags: 0, level: .BALANCED, allowlisted: false).block)
    }
}
