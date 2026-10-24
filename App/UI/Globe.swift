import SwiftUI
import BastionCore

/// Loads the bundled gazetteer and land dots, and turns headlines into hotspots (only from modules whose
/// "Flare new posts on the globe" is on). No extra requests, no third-party geo service.
@MainActor
final class WorldGlobeModel: ObservableObject {
    static let shared = WorldGlobeModel()
    @Published private(set) var events: WorldEvents?

    func load() {
        Task.detached(priority: .utility) {
            let g = Gazetteer.load(Files.bundled("geo/gazetteer.tsv") ?? "")
            let dots = WorldEvents.decodeDots(Files.bundledData("geo/land_dots.bin") ?? Data())
            let ev = WorldEvents(gazetteer: g, landDots: dots)
            await MainActor.run { self.events = ev }
        }
    }

    func clusters(_ window: EventWindow) -> [Cluster<MediaItem>] {
        guard let events else { return [] }
        let media = MediaStore.shared
        let ok = Set(media.sources.filter { $0.enabled && media.flares(media.section(of: $0.id)) }.map(\.id))
        return events.clusters(media.items.filter { ok.contains($0.sourceId) }, window: window)
    }
}

/// A slowly turning, dotted-earth globe. Each place in the news gets a flare — a glowing core with solar-prominence
/// arcs — larger and warmer where more stories cluster. Drag the globe to turn it; tap a flare for its stories.
/// Only the globe itself takes touches: the lanes either side (marked by rails) scroll the page.
struct WorldGlobe: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var media: MediaStore
    @StateObject private var model = WorldGlobeModel.shared
    @State private var window: EventWindow = .H24
    @State private var spin = Spin()
    @State private var selected: Cluster<MediaItem>?
    @State private var adding = false

    static let gold = Color(hex: 0xF6C177), ember = Color(hex: 0xFF6B3D), ice = Color(hex: 0x9EE7FF)

    var body: some View {
        let clusters = model.clusters(window)
        let stories = clusters.reduce(0) { $0 + $1.count }
        VStack(spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("WORLD EVENTS").font(.system(size: 11, weight: .semibold)).tracking(3).foregroundStyle(Theme.teal)
                    Text(clusters.isEmpty ? "No mapped stories yet" : "\(clusters.count) hotspots · \(stories) stories").font(.caption2).foregroundStyle(Theme.muted)
                }
                Spacer()
                HStack(spacing: 4) {
                    ForEach(EventWindow.allCases, id: \.self) { w in
                        Button { window = w; selected = nil } label: {
                            Text(w.label).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(w == window ? Theme.teal : Theme.muted)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6).fill(w == window ? Theme.teal.opacity(0.12) : .clear))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(w == window ? Theme.teal : Theme.outline, lineWidth: 0.8))
                        }.buttonStyle(.plain)
                    }
                }
            }
            GeometryReader { g in
                let size = g.size
                let radius = Self.radius(size)
                ZStack {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                        Canvas { c, sz in draw(c, sz, clusters, ctx.date) }
                    }
                    .allowsHitTesting(false)
                    // the touch area is the disc only
                    Circle().fill(Color.white.opacity(0.001)).frame(width: radius * 2.12, height: radius * 2.12)
                        .contentShape(Circle())
                        .gesture(DragGesture(minimumDistance: 6)
                            .onChanged { v in
                                if spin.dragStart == nil { spin.dragStart = (spin.rot, spin.tilt); spin.velocity = 0; spin.target = nil }
                                spin.rot = spin.dragStart!.0 + Double(v.translation.width / size.width) * 180
                                spin.tilt = (spin.dragStart!.1 + Double(v.translation.height / size.height) * 120).clamped(-60, 70)
                                spin.lastTouch = Date()
                            }
                            .onEnded { v in
                                spin.velocity = (Double(v.predictedEndTranslation.width - v.translation.width) / Double(size.width) * 180 * 2).clamped(-400, 400)
                                spin.dragStart = nil; spin.lastTouch = Date()
                            })
                        .simultaneousGesture(SpatialTapGesture().onEnded { t in tap(t.location, size: size, radius: radius, clusters: clusters) })
                }
            }
            .aspectRatio(1, contentMode: .fit)
            if clusters.isEmpty {
                VStack(spacing: 6) {
                    Text(media.sources.isEmpty ? "Add world news sources to light up the globe" :
                         media.modules.allSatisfy({ !$0.flare }) ? "Globe flares are off for every module" : "None of your recent headlines name a place")
                        .font(.caption).foregroundStyle(Theme.text.opacity(0.8))
                    if media.sources.isEmpty {
                        Button(adding ? "Adding…" : "Add world news") {
                            adding = true
                            Task { for u in ["https://feeds.bbci.co.uk/news/world/rss.xml", "https://www.aljazeera.com/xml/rss/all.xml", "https://www.theguardian.com/world/rss"] { _ = try? await media.add(u) }; adding = false }
                        }.buttonStyle(.bordered)
                    }
                }
            } else {
                Text("Drag the globe to turn · tap a flare").font(.caption2).tracking(0.5).foregroundStyle(Theme.muted)
            }
        }
        .sheet(item: $selected) { c in ClusterSheet(cluster: c, tab: tab).environmentObject(media).preferredColorScheme(.dark) }
    }

    static func radius(_ size: CGSize) -> CGFloat { max(60, min(size.width / 2 - 46, size.height * 0.42)) }

    // MARK: drawing

    private func draw(_ c: GraphicsContext, _ size: CGSize, _ clusters: [Cluster<MediaItem>], _ now: Date) {
        spin.step(now, idle: selected == nil)
        let t = now.timeIntervalSinceReferenceDate
        let cx = size.width / 2, cy = size.height / 2
        let r = Self.radius(size)
        let rr = spin.rot * .pi / 180, tt = spin.tilt * .pi / 180
        let cl = cos(rr), sl = sin(rr), ct = cos(tt), st = sin(tt)
        func project(_ x: Double, _ y: Double, _ z: Double) -> (CGPoint, Double) {
            let x1 = x * cl + z * sl, z1 = -x * sl + z * cl
            let y2 = y * ct - z1 * st, z2 = y * st + z1 * ct
            return (CGPoint(x: cx + r * x1, y: cy - r * y2), z2)
        }

        // scroll rails in the side lanes
        let railH = r * 1.1
        for x in [CGFloat(16), size.width - 16] {
            var p = Path()
            p.move(to: CGPoint(x: x, y: cy - railH / 2)); p.addLine(to: CGPoint(x: x, y: cy + railH / 2))
            c.stroke(p, with: .color(Theme.muted.opacity(0.22)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            let a: CGFloat = 5, top = cy - railH / 2 - 12, bot = cy + railH / 2 + 12
            var ch = Path()
            ch.move(to: CGPoint(x: x - a, y: top + a * 0.6)); ch.addLine(to: CGPoint(x: x, y: top - a * 0.4)); ch.addLine(to: CGPoint(x: x + a, y: top + a * 0.6))
            ch.move(to: CGPoint(x: x - a, y: bot - a * 0.6)); ch.addLine(to: CGPoint(x: x, y: bot + a * 0.4)); ch.addLine(to: CGPoint(x: x + a, y: bot - a * 0.6))
            c.stroke(ch, with: .color(Theme.muted.opacity(0.22)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }

        // atmosphere and sphere
        let center = CGPoint(x: cx, y: cy)
        c.fill(Path(ellipseIn: CGRect(x: cx - r * 1.22, y: cy - r * 1.22, width: r * 2.44, height: r * 2.44)),
               with: .radialGradient(Gradient(stops: [.init(color: Theme.teal.opacity(0), location: 0.78), .init(color: Theme.teal.opacity(0.16), location: 0.82),
                                                      .init(color: Theme.teal.opacity(0.05), location: 0.9), .init(color: .clear, location: 1)]),
                                     center: center, startRadius: 0, endRadius: r * 1.22))
        c.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
               with: .radialGradient(Gradient(colors: [Color(hex: 0x16242E), Color(hex: 0x0C141B), Color(hex: 0x0A0E13)]),
                                     center: CGPoint(x: cx - r * 0.35, y: cy - r * 0.4), startRadius: 0, endRadius: r * 1.5))
        c.stroke(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)), with: .color(Theme.teal.opacity(0.28)), lineWidth: 1)

        // graticule
        var grat = Path()
        for lat in stride(from: -60.0, through: 60, by: 30) {
            var prev: (CGPoint, Double)?
            for lon in stride(from: 0.0, through: 360, by: 6) {
                let la = lat * .pi / 180, lo = lon * .pi / 180
                let p = project(cos(la) * sin(lo), sin(la), cos(la) * cos(lo))
                if let q = prev, q.1 > 0, p.1 > 0 { grat.move(to: q.0); grat.addLine(to: p.0) }
                prev = p
            }
        }
        for lon in stride(from: 0.0, to: 360, by: 30) {
            var prev: (CGPoint, Double)?
            for lat in stride(from: -90.0, through: 90, by: 6) {
                let la = lat * .pi / 180, lo = lon * .pi / 180
                let p = project(cos(la) * sin(lo), sin(la), cos(la) * cos(lo))
                if let q = prev, q.1 > 0, p.1 > 0 { grat.move(to: q.0); grat.addLine(to: p.0) }
                prev = p
            }
        }
        c.stroke(grat, with: .color(Theme.teal.opacity(0.07)), lineWidth: 0.7)

        // land dots in three depth bands
        if let dots = model.events?.landDots, !dots.isEmpty {
            var bands = [Path(), Path(), Path()]
            let ds = max(1.6, size.width / 270)
            var i = 0
            while i + 2 < dots.count {
                let x = Double(dots[i]), y = Double(dots[i + 1]), z = Double(dots[i + 2])
                let x1 = x * cl + z * sl, z1 = -x * sl + z * cl
                let y2 = y * ct - z1 * st, z2 = y * st + z1 * ct
                if z2 > 0.02 {
                    let b = z2 > 0.55 ? 0 : z2 > 0.25 ? 1 : 2
                    let s = ds * (1 - CGFloat(b) * 0.18)
                    bands[b].addEllipse(in: CGRect(x: cx + r * x1 - s / 2, y: cy - r * y2 - s / 2, width: s, height: s))
                }
                i += 3
            }
            for (b, a) in [0.78, 0.5, 0.24].enumerated() { c.fill(bands[b], with: .color(Theme.teal.opacity(a))) }
        }

        // flares
        var visible: [(Cluster<MediaItem>, CGPoint, Double, CGFloat)] = []
        for cl0 in clusters {
            let la = cl0.lat * .pi / 180, lo = cl0.lon * .pi / 180
            let (p, z) = project(cos(la) * sin(lo), sin(la), cos(la) * cos(lo))
            let k = min(1, max(0.15, log2(Double(cl0.count) + 1) / 4))
            let coreR = CGFloat(3 + 5 * k)
            visible.append((cl0, p, z, coreR))
            if z < -0.25 { continue }
            let seed = Double(Int(cl0.label.javaHash) & 0xffff) / 6553.6
            let fade = min(1, max(0, (z + 0.25) / 0.5))
            let color = Self.mix(Self.gold, Self.ember, k)
            // prominence arcs rising from the surface
            let nx = p.x - cx, ny = p.y - cy
            let len = max(1, sqrt(nx * nx + ny * ny))
            let (ux, uy): (CGFloat, CGFloat) = len < 2 ? (0, -1) : (nx / len, ny / len)
            let (tx, ty) = (-uy, ux)
            for j in 0..<3 {
                let ph = t * (0.9 + 0.25 * Double(j)) + seed + Double(j) * 2.1
                let rise = CGFloat((0.5 + 0.5 * sin(ph))) * CGFloat(10 + 18 * k)
                let w = CGFloat(6 + 8 * k) * (1 + 0.3 * CGFloat(j))
                let side = CGFloat(j == 1 ? -1 : 1) * CGFloat(0.3 + 0.2 * Double(j))
                let a0 = CGPoint(x: p.x - tx * w * 0.5 + tx * side * 4, y: p.y - ty * w * 0.5 + ty * side * 4)
                let a1 = CGPoint(x: p.x + tx * w * 0.5 + tx * side * 4, y: p.y + ty * w * 0.5 + ty * side * 4)
                let ctl = CGPoint(x: p.x + ux * rise * 1.6 + tx * side * w, y: p.y + uy * rise * 1.6 + ty * side * w)
                var arc = Path(); arc.move(to: a0); arc.addQuadCurve(to: a1, control: ctl)
                let alpha = (0.35 + 0.4 * (0.5 + 0.5 * sin(ph * 1.3))) * fade
                c.stroke(arc, with: .color(color.opacity(alpha)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            }
            if z > 0 {
                let pulse = 1 + 0.18 * CGFloat(sin(t * 3 + seed))
                let gr = coreR * 2.2 * pulse
                c.fill(Path(ellipseIn: CGRect(x: p.x - gr, y: p.y - gr, width: gr * 2, height: gr * 2)),
                       with: .radialGradient(Gradient(colors: [.white.opacity(0.95), color.opacity(0.85), color.opacity(0)]), center: p, startRadius: 0, endRadius: gr))
                let newest = cl0.places.flatMap { $0.1 }.map(\.publishedAt).max() ?? 0
                if Clock.now - newest < 90 * 60_000 {
                    let phase = CGFloat(((t + seed).truncatingRemainder(dividingBy: 2.4)) / 2.4)
                    let rr2 = coreR * (1.5 + phase * 4)
                    c.stroke(Path(ellipseIn: CGRect(x: p.x - rr2, y: p.y - rr2, width: rr2 * 2, height: rr2 * 2)), with: .color(Self.ice.opacity(Double(1 - phase) * 0.6)), lineWidth: 1)
                }
                if selected?.id == cl0.id {
                    let s = coreR * 3.2
                    c.stroke(Path(ellipseIn: CGRect(x: p.x - s, y: p.y - s, width: s * 2, height: s * 2)), with: .color(Theme.teal), lineWidth: 1.5)
                }
            }
        }
        spin.projected = visible

        // HUD labels for the busiest visible hotspots, skipping placements that would overlap
        var placed: [CGRect] = []
        for (cl0, p, z, coreR) in visible.filter({ $0.2 > 0.3 }).sorted(by: { $0.0.count > $1.0.count }).prefix(4) {
            let name = Text(cl0.label.uppercased()).font(.system(size: 10, weight: .medium)).tracking(1.4).foregroundColor(Theme.text.opacity(0.9))
                + Text("  \(cl0.count)").font(.system(size: 10, weight: .bold)).foregroundColor(Self.gold)
            let resolved = c.resolve(name)
            let ts = resolved.measure(in: CGSize(width: 300, height: 40))
            for (dx, dy) in [(1.0, -1.0), (-1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] as [(CGFloat, CGFloat)] {
                let elbow = CGPoint(x: p.x + dx * 14, y: p.y + dy * 16)
                let end = CGPoint(x: elbow.x + dx * 8, y: elbow.y)
                let tx = dx > 0 ? end.x + 4 : end.x - 4 - ts.width
                let rect = CGRect(x: tx - 3, y: end.y - ts.height / 2 - 3, width: ts.width + 6, height: ts.height + 6)
                if rect.minX < 0 || rect.maxX > size.width || rect.minY < 0 || rect.maxY > size.height { continue }
                if placed.contains(where: { $0.intersects(rect) }) { continue }
                if visible.contains(where: { $0.0.id != cl0.id && $0.2 > 0 && rect.contains($0.1) }) { continue }
                placed.append(rect)
                var line = Path()
                line.move(to: CGPoint(x: p.x + dx * coreR * 0.7, y: p.y + dy * coreR * 0.7)); line.addLine(to: elbow); line.addLine(to: end)
                c.stroke(line, with: .color(.white.opacity(0.45)), lineWidth: 0.8)
                c.draw(resolved, at: CGPoint(x: tx, y: end.y), anchor: .leading)
                _ = z
                break
            }
        }
    }

    private func tap(_ loc: CGPoint, size: CGSize, radius: CGFloat, clusters: [Cluster<MediaItem>]) {
        spin.lastTouch = Date()
        // the tap area is centred on the disc; convert to canvas coordinates
        let off = CGPoint(x: size.width / 2 - radius * 1.06, y: size.height / 2 - radius * 1.06)
        let p = CGPoint(x: loc.x + off.x, y: loc.y + off.y)
        guard let hit = spin.projected.filter({ $0.2 > 0 }).min(by: { hypot($0.1.x - p.x, $0.1.y - p.y) < hypot($1.1.x - p.x, $1.1.y - p.y) }),
              hypot(hit.1.x - p.x, hit.1.y - p.y) < 40 + hit.3 else { return }
        let c = hit.0
        // bring the hotspot to the front, then open it
        let delta = ((-c.lon - spin.rot).truncatingRemainder(dividingBy: 360) + 540).truncatingRemainder(dividingBy: 360) - 180
        spin.velocity = 0
        spin.target = (spin.rot, spin.tilt, spin.rot + delta, c.lat.clamped(-50, 60), Date())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { selected = c }
    }

    static func mix(_ a: Color, _ b: Color, _ k: Double) -> Color {
        let ua = UIColor(a), ub = UIColor(b)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0, r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        ua.getRed(&r1, green: &g1, blue: &b1, alpha: &a1); ub.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = CGFloat(k)
        return Color(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t)
    }
}

/// The globe's motion, kept outside SwiftUI state so turning it redraws only the canvas, not the whole view.
final class Spin {
    var rot: Double = -10
    var tilt: Double = 22
    var velocity: Double = 0
    var lastTouch = Date.distantPast
    var dragStart: (Double, Double)?
    var lastFrame = Date()
    /// (from rot, from tilt, to rot, to tilt, start) — an eased turn towards a tapped hotspot
    var target: (Double, Double, Double, Double, Date)?
    /// What was drawn last frame, for tap hit-testing.
    var projected: [(Cluster<MediaItem>, CGPoint, Double, CGFloat)] = []

    /// Idle drift, inertia after a fling, or an eased turn to a hotspot.
    func step(_ now: Date, idle: Bool) {
        let dt = min(0.05, max(0, now.timeIntervalSince(lastFrame)))
        lastFrame = now
        if let tg = target {
            let (r0, t0, r1, t1, start) = tg
            let k = min(1, now.timeIntervalSince(start) / 0.8)
            let e = k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2
            rot = r0 + (r1 - r0) * e; tilt = t0 + (t1 - t0) * e
            if k >= 1 { target = nil; lastTouch = now }
            return
        }
        guard dragStart == nil else { return }
        var next = rot + velocity * dt
        velocity *= exp(-3 * dt)
        if abs(velocity) < 2 { velocity = 0 }
        if now.timeIntervalSince(lastTouch) > 2.5 && velocity == 0 && idle { next += 5.5 * dt }
        rot = (next.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }
}

struct ClusterSheet: View {
    let cluster: Cluster<MediaItem>
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var media: MediaStore
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(cluster.places.enumerated()), id: \.offset) { _, entry in
                    Section(entry.0.display) {
                        ForEach(entry.1) { item in
                            Button { dismiss(); openMediaItem(item, tab: tab) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(3)
                                    Text("\(media.name(of: item.sourceId)) · \(timeAgo(item.publishedAt))").font(.caption).foregroundStyle(Theme.muted)
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Theme.bg)
            .navigationTitle("\(cluster.label) · \(cluster.count) stories").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}
