import SwiftUI
import BastionCore

enum Severity: String, Codable { case INFO, WARNING, DANGER }

struct PrivacyAlert: Codable, Identifiable, Hashable {
    var time: Int64
    var severity: Severity
    var title: String
    var detail: String
    var site: String
    var id: String { "\(time)-\(title)" }
}

struct BlockedItem: Identifiable, Hashable {
    let domain: String
    let category: TrackerCategory
    let company: String
    var count: Int
    let blocked: Bool
    var id: String { domain }
}

/// What happened on one page.
struct PageSnapshot {
    let host: String
    let items: [BlockedItem]
    let fingerprinting: [String]
    let httpsUpgraded: Bool
    let paramsStripped: Int
    let permissionsDenied: [String]
    let secure: Bool
    let youtubeAds: Int
    let wallsRemoved: Int
    let cosmeticHidden: Int

    var blockedCount: Int { items.filter(\.blocked).reduce(0) { $0 + $1.count } }

    /// How hard the site *tried* to track you (before Bastion stepped in).
    var grade: Character {
        if items.contains(where: { $0.category == .MALICIOUS || $0.category == .CRYPTOMINER }) { return "F" }
        let n = items.count + fingerprinting.count * 3
        var g = n == 0 ? 0 : n <= 4 ? 1 : n <= 12 ? 2 : n <= 25 ? 3 : 4
        if !secure { g = min(4, g + 1) }
        return Array("ABCDF")[g]
    }
}

/// Everything Bastion learns about trackers, kept on this device only.
@MainActor
final class PrivacyStats: ObservableObject {
    static let shared = PrivacyStats()

    private struct Persisted: Codable {
        var since: Int64
        var categories: [String: Int64] = [:]
        var companies: [String: Int64] = [:]
        var sites: [String: Int64] = [:]
        var daily: [String: Int64] = [:]
        var httpsUpgrades: Int64 = 0, paramsStripped: Int64 = 0, fingerprintAttempts: Int64 = 0, permissionsDenied: Int64 = 0
        var youtubeAds: Int64 = 0, wallsRemoved: Int64 = 0, cosmeticHidden: Int64 = 0
        var alerts: [PrivacyAlert] = []
    }

    private final class PageReport {
        let host: String
        var httpsUpgraded: Bool
        var paramsStripped: Int
        let secure: Bool
        var items: [String: BlockedItem] = [:]
        var order: [String] = []
        var fingerprinting: [String] = []
        var permissions: [String] = []
        var alerted = Set<String>()
        var youtubeAds = 0, walls = 0, cosmetic = 0
        init(host: String, httpsUpgraded: Bool, paramsStripped: Int, secure: Bool) {
            self.host = host; self.httpsUpgraded = httpsUpgraded; self.paramsStripped = paramsStripped; self.secure = secure
        }
    }

    @Published private var p: Persisted
    @Published var liveAlert: (tab: UUID, alert: PrivacyAlert)? = nil
    @Published private(set) var version = 0
    private var pages: [UUID: PageReport] = [:]
    private var saveTask: Task<Void, Never>?

    private init() {
        p = Files.load("privacy_stats.json", as: Persisted.self) ?? Persisted(since: Clock.now)
    }

    // MARK: recording

    func startPage(_ tab: UUID, host: String, secure: Bool, upgraded: Bool, stripped: Int) {
        pages[tab] = PageReport(host: host, httpsUpgraded: upgraded, paramsStripped: stripped, secure: secure)
        bump()
    }

    func endTab(_ tab: UUID) { pages[tab] = nil }

    func recordRequest(_ tab: UUID, pageHost: String?, info: TrackerInfo, blocked: Bool) {
        let page = pages[tab]
        if let page {
            if page.items[info.domain] == nil { page.order.append(info.domain) }
            let prev = page.items[info.domain]?.count ?? 0
            page.items[info.domain] = BlockedItem(domain: info.domain, category: info.category, company: info.company, count: prev + 1, blocked: blocked)
        }
        if blocked {
            p.categories[info.category.rawValue, default: 0] += 1
            p.companies[info.company, default: 0] += 1
            if let h = pageHost { p.sites[Domains.base(h), default: 0] += 1 }
            p.daily[PrivacyStats.dayKey(Date()), default: 0] += 1
            if info.category == .MALICIOUS || info.category == .CRYPTOMINER, let page, page.alerted.insert("danger:" + info.domain).inserted {
                push(tab, PrivacyAlert(time: Clock.now, severity: .DANGER,
                                       title: info.category == .MALICIOUS ? "Blocked a malicious server" : "Blocked a cryptominer",
                                       detail: "\(page.host) tried to load \(info.domain). Bastion stopped it.", site: page.host))
            }
        }
        bump(); scheduleSave()
    }

    func recordFingerprint(_ tab: UUID, _ technique: String, frameHost: String) {
        guard let page = pages[tab], !page.fingerprinting.contains(technique) else { return }
        page.fingerprinting.append(technique)
        p.fingerprintAttempts += 1
        let strong = technique == "WebGL" || technique == "Audio" || page.fingerprinting.count >= 2
        if strong && page.alerted.insert("fp").inserted {
            let by = !frameHost.isEmpty && Domains.base(frameHost) != Domains.base(page.host) ? " (via \(frameHost))" : ""
            push(tab, PrivacyAlert(time: Clock.now, severity: .WARNING, title: "Fingerprinting attempt",
                                   detail: "\(page.host)\(by) probed \(page.fingerprinting.joined(separator: ", ")) to identify your device." +
                                    (Settings.shared.fingerprint ? " Bastion fed it noise." : " Protection is off."), site: page.host))
        }
        bump(); scheduleSave()
    }

    func countUpgrade() { p.httpsUpgrades += 1; scheduleSave() }
    func countStripped(_ n: Int) { p.paramsStripped += Int64(n); scheduleSave() }

    func recordPermissionDenied(_ tab: UUID, host: String, what: String) {
        p.permissionsDenied += 1
        pages[tab]?.permissions.append(what)
        push(tab, PrivacyAlert(time: Clock.now, severity: .INFO, title: "Blocked \(what) access",
                               detail: "\(host) asked for your \(what). Bastion denies device permissions by default.", site: host))
        bump(); scheduleSave()
    }

    func recordCosmetic(_ tab: UUID, _ n: Int) {
        pages[tab]?.cosmetic += n
        p.cosmeticHidden += Int64(n)
        bump(); scheduleSave()
    }

    /// Events from the YouTube shield: "pruned" (ads stripped from page data), "skipped" (in-player ad), "wall".
    func recordYouTube(_ tab: UUID, _ kind: String) {
        let page = pages[tab]
        let company = "YouTube (Google)"
        if kind == "sitewall" {
            p.wallsRemoved += 1
            page?.walls += 1
            if let page, page.alerted.insert("sitewall").inserted {
                push(tab, PrivacyAlert(time: Clock.now, severity: .WARNING, title: "Removed an ad-blocker wall",
                                       detail: "\(page.host) covered the page because ads were blocked. Bastion removed the pop-up and gave you back scrolling.", site: page.host))
            }
            bump(); scheduleSave()
            return
        }
        if kind == "wall" {
            p.wallsRemoved += 1
            page?.walls += 1
            if let page, page.alerted.insert("ytwall").inserted {
                push(tab, PrivacyAlert(time: Clock.now, severity: .WARNING, title: "Removed YouTube's ad-blocker wall",
                                       detail: "YouTube tried to block playback because ads were missing. Bastion removed the pop-up and resumed the video.", site: page.host))
            }
        } else {
            p.youtubeAds += 1
            page?.youtubeAds += 1
            let domain = kind == "skipped" ? "YouTube in-player ad (skipped)" : "YouTube ad slots (removed from page data)"
            if let page {
                if page.items[domain] == nil { page.order.append(domain) }
                page.items[domain] = BlockedItem(domain: domain, category: .AD, company: company, count: (page.items[domain]?.count ?? 0) + 1, blocked: true)
            }
            p.categories[TrackerCategory.AD.rawValue, default: 0] += 1
            p.companies[company, default: 0] += 1
            p.sites["youtube.com", default: 0] += 1
            p.daily[PrivacyStats.dayKey(Date()), default: 0] += 1
            if kind == "skipped", let page, page.alerted.insert("ytskip").inserted {
                push(tab, PrivacyAlert(time: Clock.now, severity: .INFO, title: "Skipped a YouTube ad",
                                       detail: "An ad reached the player anyway (likely inserted server-side). Bastion muted, covered and skipped it.", site: page.host))
            }
        }
        bump(); scheduleSave()
    }

    func pageFinished(_ tab: UUID) {
        guard let page = pages[tab] else { return }
        let blocked = page.items.values.filter(\.blocked)
        if Settings.shared.alertHeavy && blocked.count >= 15 && page.alerted.insert("heavy").inserted {
            push(tab, PrivacyAlert(time: Clock.now, severity: .WARNING, title: "Heavy tracking on \(page.host)",
                                   detail: "\(blocked.count) tracking domains from \(Set(blocked.map(\.company)).count) companies were blocked on this page.", site: page.host))
        }
    }

    func alert(_ tab: UUID, _ a: PrivacyAlert) { push(tab, a) }

    private func push(_ tab: UUID, _ a: PrivacyAlert) {
        p.alerts.insert(a, at: 0)
        if p.alerts.count > 200 { p.alerts.removeLast(p.alerts.count - 200) }
        scheduleSave()
        if Settings.shared.alertsEnabled { liveAlert = (tab, a) }
    }

    // MARK: reading

    func page(_ tab: UUID) -> PageSnapshot? {
        guard let r = pages[tab] else { return nil }
        var items: [BlockedItem] = r.order.compactMap { r.items[$0] }
        items.sort { (a: BlockedItem, b: BlockedItem) -> Bool in
            if a.category.severity != b.category.severity { return a.category.severity > b.category.severity }
            return a.count > b.count
        }
        return PageSnapshot(host: r.host, items: items, fingerprinting: r.fingerprinting, httpsUpgraded: r.httpsUpgraded, paramsStripped: r.paramsStripped,
                            permissionsDenied: r.permissions, secure: r.secure, youtubeAds: r.youtubeAds, wallsRemoved: r.walls, cosmeticHidden: r.cosmetic)
    }

    func blockedForSite(_ base: String) -> Int64 { p.sites[base] ?? 0 }

    struct Summary {
        let totalBlocked: Int64
        let byCategory: [(TrackerCategory, Int64)]
        let topCompanies: [(String, Int64)]
        let topSites: [(String, Int64)]
        let last7Days: [(String, Int64)]
        let weekTotal: Int64
        let httpsUpgrades, paramsStripped, fingerprintAttempts, permissionsDenied, youtubeAds, wallsRemoved, cosmeticHidden: Int64
        let alerts: [PrivacyAlert]
        let since: Int64
    }

    var summary: Summary {
        let cal = Calendar.current
        var days: [(String, Int64)] = []
        for i in stride(from: 6, through: 0, by: -1) {
            let d = cal.date(byAdding: .day, value: -i, to: Date()) ?? Date()
            let k = PrivacyStats.dayKey(d)
            days.append((k, p.daily[k] ?? 0))
        }
        var byCategory: [(TrackerCategory, Int64)] = []
        for c in TrackerCategory.allCases { byCategory.append((c, p.categories[c.rawValue] ?? 0)) }
        let companies: [(String, Int64)] = p.companies.sorted { $0.value > $1.value }.prefix(10).map { ($0.key, $0.value) }
        let sites: [(String, Int64)] = p.sites.sorted { $0.value > $1.value }.prefix(10).map { ($0.key, $0.value) }
        var total: Int64 = 0
        for v in p.categories.values { total += v }
        var week: Int64 = 0
        for d in days { week += d.1 }
        return Summary(totalBlocked: total, byCategory: byCategory, topCompanies: companies, topSites: sites, last7Days: days, weekTotal: week,
                       httpsUpgrades: p.httpsUpgrades, paramsStripped: p.paramsStripped, fingerprintAttempts: p.fingerprintAttempts,
                       permissionsDenied: p.permissionsDenied, youtubeAds: p.youtubeAds, wallsRemoved: p.wallsRemoved, cosmeticHidden: p.cosmeticHidden,
                       alerts: p.alerts, since: p.since)
    }

    func clearAlerts() { p.alerts = []; bump(); scheduleSave() }

    func reset() { p = Persisted(since: Clock.now); bump(); scheduleSave() }

    func exportJSON() -> Any { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(p))) ?? [:] }

    // MARK: persistence

    private func bump() { version &+= 1 }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            Files.save("privacy_stats.json", self.p)
        }
    }

    func saveNow() { Files.save("privacy_stats.json", p) }

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
