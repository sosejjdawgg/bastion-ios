import SwiftUI
import WebKit
import BastionCore

enum TabContent { case home, results, web }

/// One browser tab. Its web view is created on first use.
@MainActor
final class BrowserTab: ObservableObject, Identifiable {
    let id = UUID()
    let isPrivate: Bool
    @Published var content: TabContent = .home
    @Published var url = ""
    @Published var title = ""
    @Published var progress: Double = 0
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var query = ""
    @Published var searching = false
    @Published var outcome: SearchOutcome?
    @Published var parked = false
    @Published var noticeDismissedFor: String?
    /// Where the user asked to go (a redirect keeps pointing at this, so Web history looks up the right site).
    @Published var intendedUrl: String?
    var openedFromResults = false
    /// The month and year asked for in Web history (for the archive banner).
    @Published var archiveRequest: (Int, Int)?
    var pageHost: String?
    var upgradedHosts = Set<String>(), proceedHosts = Set<String>(), httpAllowedHosts = Set<String>()
    var pendingUpgrade = false, pendingStripped = 0
    var webView: WKWebView?
    var observers: [NSKeyValueObservation] = []
    var searchTask: Task<Void, Never>?

    init(isPrivate: Bool) { self.isPrivate = isPrivate }

    var displayTitle: String { title.nilIfBlank ?? URLs.host(url)?.removingPrefix("www.") ?? (content == .results ? query : "New tab") }
}

/// Weak wrapper so the content controller doesn't keep the tab manager alive.
final class WeakHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: TabManager?
    weak var tab: BrowserTab?
    init(_ t: TabManager, _ tab: BrowserTab) { target = t; self.tab = tab }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        let manager = target, owner = tab
        Task { @MainActor in
            guard let manager, let owner else { replyHandler(nil, nil); return }
            manager.handle(message, tab: owner, reply: replyHandler)
        }
    }
}

/// Owns all tabs and their web views, routes input to search or navigation, and enforces navigation-level
/// protections (HTTPS-only, tracking-parameter stripping, malware interstitials, shields per site).
@MainActor
final class TabManager: NSObject, ObservableObject {
    static let shared = TabManager()

    @Published private(set) var tabs: [BrowserTab] = []
    @Published var currentId: UUID?
    @Published var downloadsNote: String?
    private var privateStore: WKWebsiteDataStore?
    private let processPool = WKProcessPool()

    var current: BrowserTab? { tabs.first { $0.id == currentId } }

    override init() {
        super.init()
        newTab(isPrivate: false)
        Shields.shared.onChange = { [weak self] in self?.refreshProtections() }
    }

    // MARK: tabs

    @discardableResult
    func newTab(isPrivate: Bool, select: Bool = true) -> BrowserTab {
        let t = BrowserTab(isPrivate: isPrivate)
        tabs.append(t)
        if select { currentId = t.id }
        return t
    }

    func select(_ t: BrowserTab) { currentId = t.id }

    func close(_ t: BrowserTab) {
        guard let idx = tabs.firstIndex(where: { $0 === t }) else { return }
        destroy(t)
        tabs.remove(at: idx)
        PrivacyStats.shared.endTab(t.id)
        if t.isPrivate && !tabs.contains(where: \.isPrivate) { wipePrivate() }
        if tabs.isEmpty { newTab(isPrivate: false) }
        if currentId == t.id { currentId = tabs[max(0, min(idx - 1, tabs.count - 1))].id }
    }

    func closeAllPrivate() { for t in tabs where t.isPrivate { close(t) } }

    /// Private tabs share one in-memory store, thrown away when the last private tab closes.
    private func wipePrivate() {
        privateStore?.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        privateStore = nil
    }

    private func destroy(_ t: BrowserTab) {
        t.searchTask?.cancel()
        t.observers.removeAll()
        if let wv = t.webView {
            wv.stopLoading()
            wv.configuration.userContentController.removeAllScriptMessageHandlers()
            wv.removeFromSuperview()
        }
        t.webView = nil
    }

    // MARK: input

    static let scheme = Rx("^[a-zA-Z][a-zA-Z0-9+.-]*://")

    func openUserInput(_ tab: BrowserTab, _ raw: String) {
        let input = raw.trimmed
        guard !input.isEmpty else { return }
        if looksLikeUrl(input) { navigate(tab, TabManager.scheme.contains(input) ? input : "https://\(input)") } else { search(tab, input) }
    }

    func search(_ tab: BrowserTab, _ q: String) {
        tab.query = q; tab.content = .results; tab.searching = true; tab.outcome = nil
        if !tab.isPrivate { Library.shared.addQuery(q) }
        tab.searchTask?.cancel()
        let enabled = Settings.shared.enabledSearchSources
        let set = Shields.shared.set
        let stats = PrivacyStats.shared
        tab.searchTask = Task {
            var past: [String: Int64] = [:]
            let outcome = await SearchEngine.shared.search(q, enabled: enabled, lookup: { set.lookup($0) }, pastBlocked: { _ in 0 })
            for r in outcome.results { past[Domains.base(r.host)] = stats.blockedForSite(Domains.base(r.host)) }
            guard !Task.isCancelled, tab.query == q else { return }
            tab.outcome = SearchOutcome(query: outcome.query, results: outcome.results.map { r in
                RankedResult(title: r.title, url: r.url, host: r.host, snippet: r.snippet, sources: r.sources, score: r.score, flagged: r.flagged,
                             pastBlocked: past[Domains.base(r.host)] ?? 0)
            }, statuses: outcome.statuses)
            tab.searching = false
        }
    }

    func openResult(_ tab: BrowserTab, _ url: String) { tab.openedFromResults = true; navigate(tab, url) }

    func looksLikeUrl(_ s: String) -> Bool {
        if s.contains(" ") { return false }
        if TabManager.scheme.contains(s) || s.hasPrefix("localhost") { return true }
        let hostPart = s.before("/").before("?").before("#").before(":")
        if Rx("^\\d{1,3}(\\.\\d{1,3}){3}$").matches(hostPart) { return true }
        guard Rx("^[\\w-]+(\\.[\\w-]+)+$").matches(hostPart) else { return false }
        let tld = hostPart.afterLast(".")
        return tld.count >= 2 && tld.allSatisfy(\.isLetter)
    }

    // MARK: navigation policy

    private enum Nav { case go(String), warn(String, TrackerInfo) }

    private func prepare(_ tab: BrowserTab, _ raw: String) -> Nav {
        var url = raw
        let s = Settings.shared
        if s.stripParams {
            let r = UrlCleaner.clean(url)
            if r.removed > 0 { url = r.url; tab.pendingStripped += r.removed; PrivacyStats.shared.countStripped(r.removed) }
        }
        guard var c = URLComponents(string: url), let h = c.host?.lowercased() else { return .go(url) }
        if s.httpsOnly && c.scheme == "http" && !tab.httpAllowedHosts.contains(h) && !isLocal(h) {
            c.scheme = "https"
            if c.port == 80 { c.port = nil }
            url = c.string ?? url
            tab.upgradedHosts.insert(h); tab.pendingUpgrade = true
            PrivacyStats.shared.countUpgrade()
        }
        if let info = Shields.shared.set.lookup(h), info.category == .MALICIOUS || info.category == .CRYPTOMINER, !tab.proceedHosts.contains(h) {
            return .warn(url, info)
        }
        return .go(url)
    }

    private func isLocal(_ h: String) -> Bool {
        h == "localhost" || h.hasSuffix(".local") || h.hasPrefix("192.168.") || h.hasPrefix("10.") || h.hasPrefix("127.")
    }

    func navigate(_ tab: BrowserTab, _ url: String) {
        tab.intendedUrl = url
        tab.noticeDismissedFor = nil
        switch prepare(tab, url) {
        case .go(let u): load(tab, u)
        case .warn(let u, let info): showWarning(tab, u, info)
        }
    }

    func load(_ tab: BrowserTab, _ url: String) {
        let wv = ensureWebView(tab)
        tab.content = .web
        tab.url = url
        guard let u = URL(string: url) else { return }
        var req = URLRequest(url: u)
        if Settings.shared.gpc { req.setValue("1", forHTTPHeaderField: "Sec-GPC"); req.setValue("1", forHTTPHeaderField: "DNT") }
        applyPageProtections(tab, wv, for: url)
        wv.load(req)
    }

    func reload(_ tab: BrowserTab) { tab.webView?.reload() }
    func stop(_ tab: BrowserTab) { tab.webView?.stopLoading() }

    @discardableResult
    func goBack(_ tab: BrowserTab) -> Bool {
        if tab.content == .web, let wv = tab.webView, wv.canGoBack { tab.intendedUrl = nil; wv.goBack(); return true }
        if tab.content == .web && tab.openedFromResults && tab.outcome != nil { tab.content = .results; tab.openedFromResults = false; return true }
        if tab.content != .home { tab.content = .home; return true }
        return false
    }

    func goForward(_ tab: BrowserTab) { if let wv = tab.webView, wv.canGoForward { tab.intendedUrl = nil; wv.goForward() } }

    func goHome(_ tab: BrowserTab) { tab.content = .home }

    /// Re-applies scripts and rule lists to every open tab (after a settings or list change).
    func refreshProtections() {
        for t in tabs { if let wv = t.webView { applyPageProtections(t, wv, for: t.url); wv.configuration.preferences.isFraudulentWebsiteWarningEnabled = true } }
    }

    private func applyPageProtections(_ tab: BrowserTab, _ wv: WKWebView, for url: String) {
        let ucc = wv.configuration.userContentController
        ucc.removeAllUserScripts()
        for s in Shields.shared.userScripts(for: url) { ucc.addUserScript(s) }
        ucc.removeAllContentRuleLists()
        for l in Shields.shared.ruleLists(for: URLs.host(url)) { ucc.add(l) }
    }

    // MARK: web view

    func ensureWebView(_ tab: BrowserTab) -> WKWebView {
        if let wv = tab.webView { return wv }
        let cfg = WKWebViewConfiguration()
        cfg.processPool = processPool
        if tab.isPrivate {
            if privateStore == nil { privateStore = .nonPersistent() }
            cfg.websiteDataStore = privateStore!
        }
        cfg.allowsInlineMediaPlayback = true
        cfg.allowsPictureInPictureMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.preferences.isFraudulentWebsiteWarningEnabled = true
        cfg.defaultWebpagePreferences.preferredContentMode = .mobile
        cfg.userContentController.addScriptMessageHandler(WeakHandler(self, tab), contentWorld: .page, name: "bastion")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = Http.userAgent
        wv.allowsBackForwardNavigationGestures = true
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.backgroundColor = UIColor(Theme.bg)
        wv.isOpaque = false
        wv.scrollView.contentInsetAdjustmentBehavior = .automatic
        #if DEBUG
        if #available(iOS 16.4, *) { wv.isInspectable = true }
        #endif
        tab.observers = [
            wv.observe(\.estimatedProgress) { [weak tab] w, _ in Task { @MainActor in tab?.progress = w.estimatedProgress } },
            wv.observe(\.title) { [weak tab] w, _ in Task { @MainActor in if let t = w.title, !t.isEmpty { tab?.title = t } } },
            wv.observe(\.url) { [weak tab] w, _ in Task { @MainActor in if let u = w.url?.absoluteString, u.hasPrefix("http") { tab?.url = u } } },
            wv.observe(\.canGoBack) { [weak tab] w, _ in Task { @MainActor in tab?.canGoBack = w.canGoBack } },
            wv.observe(\.canGoForward) { [weak tab] w, _ in Task { @MainActor in tab?.canGoForward = w.canGoForward } },
            wv.observe(\.isLoading) { [weak tab] w, _ in Task { @MainActor in tab?.loading = w.isLoading } }
        ]
        tab.webView = wv
        return wv
    }

    func tab(for wv: WKWebView) -> BrowserTab? { tabs.first { $0.webView === wv } }

    // MARK: bridge

    func handle(_ message: WKScriptMessage, tab: BrowserTab, reply: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let t = body["t"] as? String else { reply(nil, nil); return }
        switch t {
        case "fp":
            let k = String((body["k"] as? String ?? "").prefix(32))
            if ["Canvas", "WebGL", "Audio", "Font probing"].contains(k) { PrivacyStats.shared.recordFingerprint(tab.id, k, frameHost: String((body["h"] as? String ?? "").prefix(128))) }
            reply(nil, nil)
        case "ad":
            if let k = body["k"] as? String, ["pruned", "skipped", "wall"].contains(k) { PrivacyStats.shared.recordYouTube(tab.id, k) }
            reply(nil, nil)
        case "gen":
            let (css, n) = Shields.shared.genericCss(keysJSON: body["keys"] as? String ?? "[]", href: body["href"] as? String ?? "")
            if n > 0 { PrivacyStats.shared.recordCosmetic(tab.id, n) }
            reply(css, nil)
        case "res":
            reply(nil, nil)
            guard let items = body["items"] as? [[Any]] else { return }
            let host = tab.pageHost
            for (info, blocked) in Shields.shared.classify(items, pageHost: host, pageUrl: tab.url) {
                PrivacyStats.shared.recordRequest(tab.id, pageHost: host, info: info, blocked: blocked)
            }
        default: reply(nil, nil)
        }
    }

    // MARK: interstitials

    private func showWarning(_ tab: BrowserTab, _ url: String, _ info: TrackerInfo) {
        let wv = ensureWebView(tab)
        tab.content = .web
        tab.url = url
        tab.title = "Blocked: dangerous site"
        let h = (URLs.host(url) ?? url).htmlEscaped
        let kind = info.category == .MALICIOUS ? "is on a public list of malware, phishing or scam hosts" : "runs cryptomining scripts that drain your battery"
        wv.loadHTMLString(TabManager.interstitial("Bastion blocked this site", "<b>\(h)</b> \(kind). Bastion stopped the page before it loaded anything.",
                                                 "Go back to safety", "bastion://back", "Open anyway (not recommended)",
                                                 "bastion://proceed?u=" + url.urlQueryEncoded, danger: true), baseURL: nil)
        PrivacyStats.shared.alert(tab.id, PrivacyAlert(time: Clock.now, severity: .DANGER, title: "Dangerous site blocked", detail: "\(URLs.host(url) ?? url) \(kind).", site: URLs.host(url) ?? ""))
    }

    private func showHttpsFailed(_ tab: BrowserTab, _ httpsUrl: String) {
        guard let wv = tab.webView else { return }
        let httpUrl = httpsUrl.replacingOccurrences(of: "https://", with: "http://")
        let h = (URLs.host(httpsUrl) ?? httpsUrl).htmlEscaped
        wv.loadHTMLString(TabManager.interstitial("No secure connection available",
                                                 "<b>\(h)</b> doesn't support HTTPS. Anything you send or receive there can be read or changed by your network operator or anyone on this Wi-Fi.",
                                                 "Go back", "bastion://back", "Continue over insecure HTTP", "bastion://http?u=" + httpUrl.urlQueryEncoded, danger: false), baseURL: nil)
    }

    static func interstitial(_ title: String, _ body: String, _ primary: String, _ primaryHref: String, _ secondary: String, _ secondaryHref: String, danger: Bool) -> String {
        let accent = danger ? "#E53E3E" : "#F6AD55"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{margin:0;font-family:-apple-system,sans-serif;background:#0E1116;color:#E6EDF3;display:flex;min-height:100vh;align-items:center;justify-content:center}
        .c{max-width:420px;padding:28px}.i{width:56px;height:56px;border-radius:16px;background:\(accent);display:flex;align-items:center;justify-content:center;font-size:30px;color:#0E1116;font-weight:700}
        h1{font-size:22px;margin:20px 0 8px}p{color:#9DA7B3;line-height:1.5}a{display:block;text-align:center;padding:14px;border-radius:12px;text-decoration:none;margin-top:12px;font-weight:600}
        .p{background:#4FD1C5;color:#0E1116}.s{color:#9DA7B3;border:1px solid #30363D}</style></head>
        <body><div class="c"><div class="i">!</div><h1>\(title)</h1><p>\(body)</p>
        <a class="p" href="\(primaryHref)">\(primary)</a><a class="s" href="\(secondaryHref)">\(secondary)</a></div></body></html>
        """
    }

    private func handleInternal(_ tab: BrowserTab, _ url: URL) {
        if url.host == "back" { if !goBack(tab) { tab.content = .home }; return }
        guard let target = URLs.queryParam(url.absoluteString, "u"), let th = URLs.host(target) else { return }
        switch url.host {
        case "proceed": tab.proceedHosts.insert(th); load(tab, target)
        case "http": tab.httpAllowedHosts.insert(th); load(tab, target)
        default: break
        }
    }
}

// MARK: - WKNavigationDelegate

extension TabManager: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.allowsContentJavaScript = Settings.shared.javascript
        guard let tab = tab(for: webView), let url = action.request.url else { decisionHandler(.allow, preferences); return }
        if action.shouldPerformDownload { decisionHandler(.download, preferences); return }
        let isMain = action.targetFrame?.isMainFrame ?? true
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "bastion" { handleInternal(tab, url); decisionHandler(.cancel, preferences); return }
        if !isMain { decisionHandler(.allow, preferences); return }
        switch scheme {
        case "http", "https": break
        case "about", "data", "blob", "file": decisionHandler(.allow, preferences); return
        default:
            // tel:, mailto:, app links: hand to iOS, only when the user tapped
            if action.navigationType == .linkActivated { UIApplication.shared.open(url) }
            decisionHandler(.cancel, preferences); return
        }
        let u = url.absoluteString
        let automatic = action.navigationType == .other
        if !automatic { tab.intendedUrl = u }
        switch prepare(tab, u) {
        case .go(let next) where next != u:
            decisionHandler(.cancel, preferences); load(tab, next)
        case .warn(let next, let info):
            decisionHandler(.cancel, preferences); showWarning(tab, next, info)
        default:
            applyPageProtections(tab, webView, for: u)
            decisionHandler(.allow, preferences)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        tab.loading = true
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView), let u = webView.url?.absoluteString, u.hasPrefix("http") else { return }
        tab.url = u
        if tab.intendedUrl == nil { tab.intendedUrl = u }
        tab.parked = Parking.looksParked(u)
        let h = URLs.host(u)
        tab.pageHost = h
        PrivacyStats.shared.startPage(tab.id, host: h ?? u, secure: u.hasPrefix("https"), upgraded: tab.pendingUpgrade, stripped: tab.pendingStripped)
        tab.pendingUpgrade = false; tab.pendingStripped = 0
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        tab.loading = false
        guard let u = webView.url?.absoluteString, u.hasPrefix("http") else { return }
        tab.title = webView.title ?? tab.title
        if !tab.isPrivate { Library.shared.addHistory(u, tab.title) }
        if !tab.parked && !Wayback.isArchived(u) {
            webView.evaluateJavaScript(Parking.detectJS) { r, _ in Task { @MainActor in if (r as? Bool) == true && tab.url == u { tab.parked = true } } }
        }
        PrivacyStats.shared.pageFinished(tab.id)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let tab = tab(for: webView) else { return }
        tab.loading = false
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        if let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString, failing.hasPrefix("https://"),
           let h = URLs.host(failing), tab.upgradedHosts.contains(h), !tab.httpAllowedHosts.contains(h) {
            showHttpsFailed(tab, failing)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appendingPathComponent(suggestedFilename)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            let base = (suggestedFilename as NSString).deletingPathExtension, ext = (suggestedFilename as NSString).pathExtension
            dest = dir.appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")); n += 1
        }
        downloadsNote = "Downloading \(dest.lastPathComponent)"
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) { downloadsNote = "Saved to Files › On My iPhone › Bastion › Downloads" }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { downloadsNote = "Download failed" }

    // target=_blank and window.open: open in the same tab (no pop-ups)
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, navigationAction.navigationType == .linkActivated { webView.load(navigationAction.request) }
        return nil
    }

    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
        if let tab = tab(for: webView) {
            let what = type == .camera ? "camera" : type == .microphone ? "microphone" : "camera & microphone"
            PrivacyStats.shared.recordPermissionDenied(tab.id, host: origin.host, what: what)
        }
    }
}
