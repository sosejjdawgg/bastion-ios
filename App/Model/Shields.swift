import SwiftUI
import WebKit
import BastionCore

typealias TrackerCategory = BastionCore.Category

/// Loads Bastion's filter lists, compiles them into Safari content rules (the only way to block requests on iOS),
/// and assembles the page scripts. Compiled rule lists are cached by WebKit, so this is slow only the first time
/// and after a list update.
@MainActor
final class Shields: ObservableObject {
    static let shared = Shields()

    @Published private(set) var set: FilterSet = .empty
    @Published private(set) var ready = false
    @Published private(set) var preparing = false
    @Published private(set) var status = "Preparing shields…"
    @Published private(set) var ruleCount = 0
    @Published private(set) var safariRules = 0
    private(set) var malwareLists: [WKContentRuleList] = []
    private(set) var adLists: [WKContentRuleList] = []
    /// Called when rule lists change, so open tabs pick them up.
    var onChange: (() -> Void)?

    private let sessionSeed = Int.random(in: 1..<Int(Int32.max))
    private var shieldsTemplate: String?

    private init() {}

    // MARK: loading

    func start() {
        guard !preparing else { return }
        preparing = true
        let level = Settings.shared.blockLevel
        Task.detached(priority: .userInitiated) {
            let set = Shields.buildSet()
            await MainActor.run { self.set = set; self.ruleCount = set.ruleCount; self.status = "Compiling \(formatCount(Int64(set.ruleCount))) rules…" }
            await self.compile(set, level: level)
        }
    }

    /// Recompile for a new block level (or after a list update).
    func rebuild() {
        let level = Settings.shared.blockLevel
        let set = self.set
        preparing = true
        Task.detached(priority: .userInitiated) { await self.compile(set, level: level) }
    }

    nonisolated static func listText(_ id: String) -> (String, String)? {
        let dl = Files.url("lists/\(id).txt")
        if let t = try? String(contentsOf: dl, encoding: .utf8) { return (t, "updated") }
        if let u = Bundle.main.url(forResource: id, withExtension: "txt", subdirectory: "lists") ?? Bundle.main.url(forResource: id, withExtension: "txt"),
           let t = try? String(contentsOf: u, encoding: .utf8) { return (t, "bundled") }
        return nil
    }

    nonisolated static func buildSet() -> FilterSet {
        var texts: [String: (String, String)] = [:]
        for l in FilterSet.lists { if let t = listText(l.id) { texts[l.id] = t } }
        return FilterSet.build(texts: texts, own: Files.bundled("bastion-filters.txt") ?? "", curated: Files.bundled("trackers.txt") ?? "")
    }

    private nonisolated func compile(_ set: FilterSet, level: BlockLevel) async {
        let out = ContentRules.build(set, level: level)
        // identifiers change with the content, so WebKit's cache is reused when nothing changed
        let fingerprint = String((out.malware + out.ads).joined().stableHash.prefix(10))
        let store = WKContentRuleListStore.default()!
        var malware: [WKContentRuleList] = [], ads: [WKContentRuleList] = []
        for (i, json) in out.malware.enumerated() { if let l = await Shields.lookupOrCompile(store, "bastion-malware-\(i)-\(fingerprint)", json) { malware.append(l) } }
        for (i, json) in out.ads.enumerated() { if let l = await Shields.lookupOrCompile(store, "bastion-ads-\(i)-\(fingerprint)", json) { ads.append(l) } }
        // tidy up lists from earlier versions
        let keep = Set((0..<out.malware.count).map { "bastion-malware-\($0)-\(fingerprint)" } + (0..<out.ads.count).map { "bastion-ads-\($0)-\(fingerprint)" })
        let ids: [String] = await withCheckedContinuation { c in store.getAvailableContentRuleListIdentifiers { c.resume(returning: $0 ?? []) } }
        for id in ids where !keep.contains(id) { store.removeContentRuleList(forIdentifier: id) { _ in } }
        await MainActor.run {
            self.malwareLists = malware; self.adLists = ads
            self.safariRules = out.ruleCount
            self.ready = true; self.preparing = false
            self.status = "\(formatCount(Int64(self.ruleCount))) blocking rules active"
            self.onChange?()
        }
    }

    private nonisolated static func lookupOrCompile(_ store: WKContentRuleListStore, _ id: String, _ json: String) async -> WKContentRuleList? {
        if let l: WKContentRuleList = await withCheckedContinuation({ c in store.lookUpContentRuleList(forIdentifier: id) { l, _ in c.resume(returning: l) } }) { return l }
        return await withCheckedContinuation { c in
            store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { l, e in
                if let e { print("rule list \(id) failed: \(e)") }
                c.resume(returning: l)
            }
        }
    }

    /// Downloads every list, validates it, swaps it in.
    func updateLists() async -> String {
        try? FileManager.default.createDirectory(at: Files.url("lists"), withIntermediateDirectories: true)
        var ok = 0
        var failed: [String] = []
        for l in FilterSet.lists {
            do {
                let text = try await Http.shared.get(l.url)
                let valid = text.split(whereSeparator: \.isNewline).filter { !$0.isEmpty && !$0.hasPrefix("!") && !$0.hasPrefix("#") }.count
                guard valid >= 20 else { throw HTTPError("list looked empty") }
                try text.write(to: Files.url("lists/\(l.id).txt"), atomically: true, encoding: .utf8)
                ok += 1
            } catch { failed.append(l.name) }
        }
        let set = await Task.detached { Shields.buildSet() }.value
        self.set = set; ruleCount = set.ruleCount
        rebuild()
        Settings.shared.listsUpdatedAt = Date().timeIntervalSince1970
        return failed.isEmpty ? "Updated \(ok) lists · \(formatCount(Int64(ruleCount))) blocking rules"
            : "Updated \(ok) of \(FilterSet.lists.count) lists. Couldn't reach: \(failed.joined(separator: ", "))"
    }

    // MARK: what applies to a page

    /// Content rule lists for a page: malware always; the rest unless shields are down for the site or blocking is off.
    func ruleLists(for host: String?) -> [WKContentRuleList] {
        let s = Settings.shared
        if s.blockLevel == .OFF { return malwareLists }
        if let h = host, s.isAllowlisted(h) { return malwareLists }
        return malwareLists + adLists
    }

    func cosmeticsJSON(for url: String) -> String? {
        guard Settings.shared.blockLevel != .OFF, let host = URLs.host(url) else { return nil }
        if Settings.shared.isAllowlisted(host) { return nil }
        let e = set.engine
        let flags = e.pageFlags(url)
        let o: [String: Any] = ["css": e.cosmeticCss(host: host, flags: flags), "sl": e.scriptlets(for: host, flags: flags),
                                "g": flags & (AdblockEngine.FLAG_DOCUMENT | AdblockEngine.FLAG_GENERICHIDE | AdblockEngine.FLAG_ELEMHIDE) == 0]
        return JSON.string(o)
    }

    func genericCss(keysJSON: String, href: String) -> (String, Int) {
        guard Settings.shared.blockLevel != .OFF, let host = URLs.host(href), !Settings.shared.isAllowlisted(host) else { return ("", 0) }
        let keys = (JSON.array(keysJSON) as? [String] ?? []).prefix(5000)
        return set.engine.genericCss(for: Array(keys), host: host, flags: set.engine.pageFlags(href))
    }

    static let youtubeHosts = ["youtube.com", "youtube-nocookie.com", "youtubekids.com"]
    static func isYouTube(_ host: String?) -> Bool { guard let h = host else { return false }; return youtubeHosts.contains { h == $0 || h.hasSuffix(".\($0)") } }

    /// The page scripts for a navigation to [url]: bridge + (YouTube shield) + shields with scriptlets + reporter.
    func userScripts(for url: String?) -> [WKUserScript] {
        let s = Settings.shared
        var out: [WKUserScript] = []
        var pre = "window.__bastionCos={};"
        if let url, let h = URLs.host(url), let c = cosmeticsJSON(for: url) { pre = "window.__bastionCos=" + JSON.string([h: c]) + ";" }
        out.append(WKUserScript(source: pre + (Files.bundled("bridge.js") ?? ""), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if s.youtubeShield && s.blockLevel != .OFF && !Shields.youtubeHosts.contains(where: { s.isAllowlisted($0) }), let yt = Files.bundled("youtube.js") {
            let guarded = "if (/(^|\\.)(youtube|youtube-nocookie|youtubekids)\\.com$/.test(location.hostname)) {\n" + yt + "\n}"
            out.append(WKUserScript(source: guarded, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        out.append(WKUserScript(source: shieldsScript(), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        out.append(WKUserScript(source: Files.bundled("report.js") ?? "", injectionTime: .atDocumentStart, forMainFrameOnly: false))
        return out
    }

    private func shieldsScript() -> String {
        let template = shieldsTemplate ?? {
            var shields = Files.bundled("shields.js") ?? ""
            // WebKit's bridge answers generic cosmetics asynchronously
            shields = shields.replacingOccurrences(of: "try { addCss(bridge.generic(stringify(batch), location.href)); } catch (e) {}",
                                                   with: "try { var r = bridge.generic(stringify(batch), location.href); if (r && r.then) r.then(addCss); else addCss(r); } catch (e) {}")
            let t = shields.replacingOccurrences(of: "/*__SCRIPTLETS__*/", with: Files.bundled("scriptlets.js") ?? "")
            shieldsTemplate = t
            return t
        }()
        let s = Settings.shared
        let cfg: [String: Any] = ["fp": s.fingerprint, "strict": s.blockLevel == .STRICT && s.fingerprint, "gpc": s.gpc,
                                  "cosmetic": s.blockLevel != .OFF, "seed": sessionSeed, "allow": s.allowlist]
        return template.replacingOccurrences(of: "__BASTION_CFG__", with: JSON.string(cfg))
    }

    // MARK: report

    static let typeBits: [Int: Int] = [1: AdblockEngine.ReqType.SCRIPT, 2: AdblockEngine.ReqType.IMAGE, 4: AdblockEngine.ReqType.CSS,
                                       8: AdblockEngine.ReqType.XHR, 16: AdblockEngine.ReqType.FRAME, 32: AdblockEngine.ReqType.MEDIA,
                                       256: AdblockEngine.ReqType.PING]

    /// Scores what a page tried to load with the same engine the Safari rules come from, for the privacy report.
    func classify(_ items: [[Any]], pageHost: String?, pageUrl: String) -> [(TrackerInfo, Bool)] {
        let s = Settings.shared
        let flags = set.engine.pageFlags(pageUrl)
        let allow = pageHost.map { s.isAllowlisted($0) } ?? false
        var out: [(TrackerInfo, Bool)] = []
        for it in items.prefix(300) {
            guard let url = it.first as? String, let host = URLs.host(url) else { continue }
            let t = (it.count > 1 ? (it[1] as? NSNumber)?.intValue : nil).flatMap { Shields.typeBits[$0] } ?? AdblockEngine.ReqType.AMBIGUOUS
            let v = set.check(url, requestHost: host, pageHost: pageHost, type: t, pageFlags: flags, level: s.blockLevel, allowlisted: allow)
            if let info = v.info { out.append((info, v.block)) }
        }
        return out
    }
}
