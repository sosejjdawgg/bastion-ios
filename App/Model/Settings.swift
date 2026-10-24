import SwiftUI
import BastionCore

/// Every user setting, stored in UserDefaults on this device only.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }

    // Protection
    @Published var blockLevel: BlockLevel { didSet { d.set(blockLevel.rawValue, forKey: "block_level") } }
    @Published var youtubeShield: Bool { didSet { d.set(youtubeShield, forKey: "yt_shield") } }
    @Published var httpsOnly: Bool { didSet { d.set(httpsOnly, forKey: "https_only") } }
    @Published var stripParams: Bool { didSet { d.set(stripParams, forKey: "strip_params") } }
    @Published var fingerprint: Bool { didSet { d.set(fingerprint, forKey: "fp") } }
    @Published var block3pCookies: Bool { didSet { d.set(block3pCookies, forKey: "block_3p_cookies") } }
    @Published var gpc: Bool { didSet { d.set(gpc, forKey: "gpc") } }
    @Published var javascript: Bool { didSet { d.set(javascript, forKey: "js") } }
    @Published var alertsEnabled: Bool { didSet { d.set(alertsEnabled, forKey: "alerts") } }
    @Published var alertHeavy: Bool { didSet { d.set(alertHeavy, forKey: "alert_heavy") } }
    @Published var allowlist: [String] { didSet { d.set(allowlist, forKey: "allowlist") } }
    @Published var listsUpdatedAt: Double { didSet { d.set(listsUpdatedAt, forKey: "lists_updated") } }

    // Search
    @Published var srcDdg: Bool { didSet { d.set(srcDdg, forKey: "src_ddg") } }
    @Published var srcMojeek: Bool { didSet { d.set(srcMojeek, forKey: "src_mojeek") } }
    @Published var srcWiki: Bool { didSet { d.set(srcWiki, forKey: "src_wiki") } }

    // Media
    @Published var mediaReader: Bool { didSet { d.set(mediaReader, forKey: "media_reader") } }
    @Published var mediaThumbnails: Bool { didSet { d.set(mediaThumbnails, forKey: "media_thumbs") } }
    @Published var mediaHideShorts: Bool { didSet { d.set(mediaHideShorts, forKey: "media_hide_shorts") } }
    @Published var mediaAutoRefresh: Bool { didSet { d.set(mediaAutoRefresh, forKey: "media_auto_refresh") } }
    @Published var readerTextScale: Int { didSet { d.set(readerTextScale, forKey: "reader_scale") } }

    // Home layout
    @Published var homeOrder: [String] { didSet { d.set(homeOrder, forKey: "home_order") } }
    @Published var homeHidden: [String] { didSet { d.set(homeHidden, forKey: "home_hidden") } }
    @Published var savedViews: [SavedView] { didSet { d.set(try? JSONEncoder().encode(savedViews), forKey: "saved_views") } }

    private init() {
        blockLevel = BlockLevel(rawValue: d.string(forKey: "block_level") ?? "") ?? .BALANCED
        youtubeShield = d.object(forKey: "yt_shield") as? Bool ?? true
        httpsOnly = d.object(forKey: "https_only") as? Bool ?? true
        stripParams = d.object(forKey: "strip_params") as? Bool ?? true
        fingerprint = d.object(forKey: "fp") as? Bool ?? true
        block3pCookies = d.object(forKey: "block_3p_cookies") as? Bool ?? true
        gpc = d.object(forKey: "gpc") as? Bool ?? true
        javascript = d.object(forKey: "js") as? Bool ?? true
        alertsEnabled = d.object(forKey: "alerts") as? Bool ?? true
        alertHeavy = d.object(forKey: "alert_heavy") as? Bool ?? true
        allowlist = d.stringArray(forKey: "allowlist") ?? []
        listsUpdatedAt = d.double(forKey: "lists_updated")
        srcDdg = d.object(forKey: "src_ddg") as? Bool ?? true
        srcMojeek = d.object(forKey: "src_mojeek") as? Bool ?? true
        srcWiki = d.object(forKey: "src_wiki") as? Bool ?? true
        mediaReader = d.object(forKey: "media_reader") as? Bool ?? true
        mediaThumbnails = d.object(forKey: "media_thumbs") as? Bool ?? true
        mediaHideShorts = d.object(forKey: "media_hide_shorts") as? Bool ?? false
        mediaAutoRefresh = d.object(forKey: "media_auto_refresh") as? Bool ?? true
        readerTextScale = d.object(forKey: "reader_scale") as? Int ?? 100
        homeOrder = d.stringArray(forKey: "home_order") ?? []
        homeHidden = d.stringArray(forKey: "home_hidden") ?? []
        savedViews = (d.data(forKey: "saved_views")).flatMap { try? JSONDecoder().decode([SavedView].self, from: $0) } ?? []
    }

    var enabledSearchSources: Set<String> {
        var s = Set<String>()
        if srcDdg { s.insert("ddg") }
        if srcMojeek { s.insert("mojeek") }
        if srcWiki { s.insert("wiki") }
        return s
    }

    func isAllowlisted(_ host: String) -> Bool {
        let base = Domains.base(host)
        return allowlist.contains(base)
    }

    func setAllowlisted(_ base: String, _ on: Bool) {
        if on { if !allowlist.contains(base) { allowlist.append(base) } } else { allowlist.removeAll { $0 == base } }
    }

    func resetAll() {
        for k in d.dictionaryRepresentation().keys { d.removeObject(forKey: k) }
    }
}

/// App-private storage: JSON files in Application Support (excluded from backups).
enum Files {
    static let dir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bastion", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        var uu = u; try? uu.setResourceValues(v)
        return u
    }()
    private static let queue = DispatchQueue(label: "bastion.files", qos: .utility)

    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    static func load<T: Decodable>(_ name: String, as: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ name: String, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        queue.async { try? data.write(to: url(name), options: .atomic) }
    }

    static func delete(_ name: String) { try? FileManager.default.removeItem(at: url(name)) }

    static func bundled(_ name: String) -> String? {
        let parts = name.split(separator: "/")
        let file = String(parts.last!)
        let sub = parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
        let ext = (file as NSString).pathExtension, base = (file as NSString).deletingPathExtension
        let u = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: sub) ?? Bundle.main.url(forResource: base, withExtension: ext)
        return u.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    static func bundledData(_ name: String) -> Data? {
        let file = (name as NSString).lastPathComponent
        let sub = (name as NSString).deletingLastPathComponent
        let ext = (file as NSString).pathExtension, base = (file as NSString).deletingPathExtension
        let u = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: sub.isEmpty ? nil : sub) ?? Bundle.main.url(forResource: base, withExtension: ext)
        return u.flatMap { try? Data(contentsOf: $0) }
    }
}

struct HistoryEntry: Codable, Identifiable, Hashable { var url: String; var title: String; var time: Int64; var id: String { url + "\(time)" } }
struct Bookmark: Codable, Identifiable, Hashable { var url: String; var title: String; var time: Int64; var id: String { url } }

/// History, bookmarks and recent searches — this device only.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()
    @Published private(set) var history: [HistoryEntry] = Files.load("history.json", as: [HistoryEntry].self) ?? []
    @Published private(set) var bookmarks: [Bookmark] = Files.load("bookmarks.json", as: [Bookmark].self) ?? []
    @Published private(set) var queries: [String] = Files.load("queries.json", as: [String].self) ?? []

    func addHistory(_ url: String, _ title: String) {
        if history.first?.url == url { history[0].title = title.nilIfBlank ?? history[0].title; save(); return }
        history.insert(HistoryEntry(url: url, title: title, time: Clock.now), at: 0)
        if history.count > 2000 { history.removeLast(history.count - 2000) }
        save()
    }
    func removeHistory(_ e: HistoryEntry) { history.removeAll { $0 == e }; save() }
    func clearHistory() { history = []; save() }

    func isBookmarked(_ url: String) -> Bool { bookmarks.contains { $0.url == url } }
    func toggleBookmark(_ url: String, _ title: String) {
        if isBookmarked(url) { bookmarks.removeAll { $0.url == url } } else { bookmarks.insert(Bookmark(url: url, title: title.nilIfBlank ?? url, time: Clock.now), at: 0) }
        save()
    }
    func removeBookmark(_ b: Bookmark) { bookmarks.removeAll { $0 == b }; save() }

    func addQuery(_ q: String) {
        queries.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        queries.insert(q, at: 0)
        if queries.count > 12 { queries.removeLast(queries.count - 12) }
        save()
    }
    func removeQuery(_ q: String) { queries.removeAll { $0 == q }; save() }
    func clearAll() { history = []; bookmarks = []; queries = []; save() }

    private func save() {
        Files.save("history.json", history); Files.save("bookmarks.json", bookmarks); Files.save("queries.json", queries)
    }
}
