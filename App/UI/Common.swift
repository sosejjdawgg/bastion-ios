import SwiftUI
import WebKit
import BastionCore

enum Theme {
    static let bg = Color(hex: 0x0E1116)
    static let surface = Color(hex: 0x161B22)
    static let surfaceHigh = Color(hex: 0x1B222C)
    static let surfaceHighest = Color(hex: 0x232B36)
    static let surfaceLow = Color(hex: 0x131820)
    static let text = Color(hex: 0xE6EDF3)
    static let muted = Color(hex: 0x9DA7B3)
    static let outline = Color(hex: 0x30363D)
    static let outlineVariant = Color(hex: 0x242A33)
    static let teal = Color(hex: 0x4FD1C5)
    static let purple = Color(hex: 0xA78BFA)
    static let danger = Color(hex: 0xE53E3E)
    static let warn = Color(hex: 0xF6AD55)
    static let good = Color(hex: 0x48BB78)
    static let news = Color(hex: 0xFF8A65)
    static let live = Color(hex: 0xFF3B47)
    static let gold = Color(hex: 0xF6C177)
}

func severityColor(_ s: Severity) -> Color { s == .DANGER ? Theme.danger : s == .WARNING ? Theme.warn : Theme.teal }

func gradeColor(_ g: Character) -> Color {
    switch g { case "A": return Theme.good; case "B": return Theme.teal; case "C": return Theme.warn; case "D": return Color(hex: 0xED8936); default: return Theme.danger }
}

/// A soft, stable colour per outlet, so the same outlet always wears the same badge.
func outletColor(_ name: String) -> Color {
    let palette: [UInt32] = [0xFF8A65, 0x4FD1C5, 0xA78BFA, 0xF6C177, 0x7AA2F7, 0xF78FB3, 0x9CCC65, 0x4DD0E1, 0xE6A26B, 0xB39DDB]
    return Color(hex: palette[Int(UInt32(bitPattern: name.lowercased().javaHash) & 0x7fffffff) % palette.count])
}

extension View {
    func card(_ radius: CGFloat = 16, color: Color = Theme.surface) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(color))
    }
}

// MARK: - Thumbnails

/// Thumbnails loaded straight from the publisher without cookies, never from known tracker hosts; memory-cached.
@MainActor
final class Thumbs {
    static let shared = Thumbs()
    private let cache = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    func cached(_ url: String) -> UIImage? { cache.object(forKey: url as NSString) }

    func load(_ url: String) async -> UIImage? {
        if let c = cached(url) { return c }
        if let t = inflight[url] { return await t.value }
        if let h = URLs.host(url), Shields.shared.set.lookup(h) != nil { return nil }
        let t = Task<UIImage?, Never> {
            guard let u = URL(string: url) else { return nil }
            var req = URLRequest(url: u)
            req.httpShouldHandleCookies = false
            req.setValue(Http.userAgent, forHTTPHeaderField: "User-Agent")
            guard let res = try? await Thumbs.session.data(for: req), let img = UIImage(data: res.0) else { return nil }
            return img.preparingThumbnail(of: CGSize(width: 720, height: 720 * img.size.height / max(1, img.size.width))) ?? img
        }
        inflight[url] = t
        let img = await t.value
        inflight[url] = nil
        if let img { cache.setObject(img, forKey: url as NSString) }
        return img
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never; c.httpShouldSetCookies = false
        c.urlCache = URLCache(memoryCapacity: 20 << 20, diskCapacity: 0)
        return URLSession(configuration: c)
    }()
}

struct Thumb: View {
    let url: String
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Theme.surfaceHighest
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }
        .clipped()
        .task(id: url) { image = Thumbs.shared.cached(url); if image == nil { image = await Thumbs.shared.load(url) } }
    }
}

// MARK: - Chips & small pieces

struct QuickChip: View {
    let label: String
    var count: Int? = nil
    let selected: Bool
    var accent: Color = Theme.teal
    var icon: String? = nil
    var dot: Color? = nil
    let action: () -> Void

    var body: some View {
        let dim = count == 0 && !selected
        Button(action: action) {
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(selected ? accent : Theme.muted) }
                Text(label).font(.subheadline.weight(.medium)).lineLimit(1).foregroundStyle(selected ? accent : Theme.text)
                if let count, count > 0 {
                    Text(count > 99 ? "99+" : "\(count)").font(.caption2.weight(.semibold)).foregroundStyle(selected ? accent : Theme.muted)
                }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(Capsule().fill(selected ? accent.opacity(0.18) : .clear))
            .overlay(Capsule().stroke(selected ? accent : Theme.outline, lineWidth: 1))
            .opacity(dim ? 0.5 : 1)
        }.buttonStyle(.plain)
    }
}

struct LetterAvatar: View {
    let host: String
    var size: CGFloat = 36
    var body: some View {
        let h = host.removingPrefix("www.")
        Text(String(h.first ?? "?").uppercased()).font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(Theme.bg)
            .frame(width: size, height: size).background(RoundedRectangle(cornerRadius: size * 0.3).fill(outletColor(h)))
    }
}

struct LiveLed: View {
    var size: CGFloat = 9
    var on = true
    @State private var pulse = false
    var body: some View {
        ZStack {
            if on { Circle().fill(Theme.live.opacity(0.35)).frame(width: size * 2.2, height: size * 2.2).scaleEffect(pulse ? 1 : 0.5).opacity(pulse ? 0 : 1) }
            Circle().fill(on ? Theme.live : Theme.muted.opacity(0.5)).frame(width: size, height: size)
                .shadow(color: on ? Theme.live.opacity(0.8) : .clear, radius: 4)
        }
        .frame(width: size * 2.2, height: size * 2.2)
        .onAppear { if on { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true } } }
    }
}

struct SectionHeader: View {
    let title: String
    var sub: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).foregroundStyle(Theme.text)
            if let sub { Text(sub).font(.caption).foregroundStyle(Theme.muted) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToggleRow: View {
    let title: String
    let sub: String
    @Binding var on: Bool
    var body: some View {
        Toggle(isOn: $on) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.text)
                Text(sub).font(.caption).foregroundStyle(Theme.muted)
            }
        }.tint(Theme.teal).padding(.vertical, 4)
    }
}

// MARK: - Web views

/// Hosts a tab's WKWebView in SwiftUI.
struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor(Theme.bg)
        attach(webView, to: v)
        return v
    }
    func updateUIView(_ v: UIView, context: Context) { if webView.superview !== v { attach(webView, to: v) } }
    private func attach(_ wv: WKWebView, to v: UIView) {
        v.subviews.forEach { $0.removeFromSuperview() }
        wv.removeFromSuperview()
        wv.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(wv)
        NSLayoutConstraint.activate([wv.leadingAnchor.constraint(equalTo: v.leadingAnchor), wv.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                                     wv.topAnchor.constraint(equalTo: v.topAnchor), wv.bottomAnchor.constraint(equalTo: v.bottomAnchor)])
    }
}

/// The sandboxed player for live streams and episodes: a tiny page at https://bastion.local/ that frames the
/// embed (so embeds get a referrer, and Twitch's parent=bastion.local matches). Ads and trackers are blocked
/// with the same Safari rules as tabs; links inside the player never navigate it away.
struct EmbedPlayer: UIViewRepresentable {
    let playUrl: String
    let hls: Bool

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let main = action.targetFrame?.isMainFrame ?? true
            if main, let h = action.request.url?.host, h != "bastion.local", action.navigationType == .linkActivated { decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.allowsPictureInPictureMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .nonPersistent()
        let ucc = cfg.userContentController
        for l in Shields.shared.ruleLists(for: "bastion.local") { ucc.add(l) }
        if Settings.shared.youtubeShield, let yt = Files.bundled("youtube.js") {
            ucc.addUserScript(WKUserScript(source: "if (/(^|\\.)(youtube|youtube-nocookie)\\.com$/.test(location.hostname)) {\n" + yt + "\n}", injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.scrollView.isScrollEnabled = false
        wv.customUserAgent = Http.userAgent
        wv.navigationDelegate = context.coordinator
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        guard context.coordinator.loaded != playUrl else { return }
        context.coordinator.loaded = playUrl
        wv.loadHTMLString(EmbedPlayer.html(playUrl, hls), baseURL: URL(string: "https://bastion.local/"))
    }

    static func dismantleUIView(_ wv: WKWebView, coordinator: Coordinator) { wv.stopLoading(); wv.loadHTMLString("", baseURL: nil) }

    static func html(_ url: String, _ hls: Bool) -> String {
        let safe = url.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "")
        let media = hls ? "<video src=\"\(safe)\" autoplay playsinline controls></video>"
            : "<iframe src=\"\(safe)\" allow=\"autoplay; encrypted-media; picture-in-picture; fullscreen\" allowfullscreen referrerpolicy=\"origin\"></iframe>"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}iframe,video{position:absolute;inset:0;width:100%;height:100%;border:0;background:#000}</style>
        </head><body>\(media)</body></html>
        """
    }
}

/// A hidden web view that loads a page like a browser would — used when a site answers plain requests with a bot
/// check (Rumble's Cloudflare). Images and media are skipped; Bastion's rules still apply.
@MainActor
final class HeadlessFetch: NSObject, WKNavigationDelegate {
    static let shared = HeadlessFetch()
    private var busy = false
    private var webView: WKWebView?

    func html(_ url: String, timeout: Double = 20) async -> String? {
        while busy { try? await Task.sleep(nanoseconds: 200_000_000) }
        busy = true
        defer { busy = false }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        for l in Shields.shared.malwareLists + Shields.shared.adLists { cfg.userContentController.add(l) }
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800), configuration: cfg)
        wv.customUserAgent = Http.userAgent
        webView = wv
        guard let u = URL(string: url) else { return nil }
        wv.load(URLRequest(url: u))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if wv.isLoading { continue }
            let html = (try? await wv.evaluateJavaScript("document.documentElement.outerHTML")) as? String ?? ""
            if !html.isEmpty && !html.contains("Just a moment") && !html.contains("challenge-platform") { webView = nil; return html }
        }
        webView = nil
        return nil
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
