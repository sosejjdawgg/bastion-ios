import SwiftUI
import BastionCore

/// The filter bar shared by Newsfeed, Media and user-made modules: a search pill and a Filters button, a row of
/// outlet/channel chips (busiest first), and quick chips built from what's in the feed right now — saved views,
/// Unread, Today, Videos/Articles, trending topics. Counts are live facet counts. New sources appear on their own.
struct FilterBar: View {
    let section: FeedSection
    let base: [MediaItem]
    let shown: Int
    let accent: Color
    let noun: String
    @EnvironmentObject var media: MediaStore
    @EnvironmentObject var settings: Settings
    @State private var sheet = false

    var body: some View {
        let f = media.prune(media.filter(for: section), section)
        let facets = media.facets(section, f, base: base)
        let topics = Topics.trending(base)
        let outlets = media.sectionOutlets(section)
        let views = settings.savedViews.filter { $0.section == section }
        let since = Clock.now - 48 * 3_600_000
        var recent: [String: Int] = [:]
        for i in base where i.publishedAt > since { recent[media.groupKey(i.sourceId), default: 0] += 1 }
        let active = outlets.sorted { (recent[$0.id] ?? 0) > (recent[$1.id] ?? 0) }
        let pinned = active.filter { f.sources.contains($0.id) } + active.filter { !f.sources.contains($0.id) }.prefix(10)
        let hasBoth = (facets.byType[.VIDEO] ?? 0) > 0 && (facets.byType[.ARTICLE] ?? 0) > 0
        let setF: (FeedFilter) -> Void = { media.setFilter(section, $0) }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.subheadline).foregroundStyle(Theme.muted)
                    TextField("Search \(noun.lowercased())", text: Binding(get: { f.query }, set: { var n = f; n.query = $0; setF(n) }))
                        .font(.subheadline).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    if !f.query.isEmpty { Button { var n = f; n.query = ""; setF(n) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted) } }
                }
                .padding(.horizontal, 14).frame(height: 42).background(Capsule().fill(Theme.surfaceHigh))
                let n = f.activeCount - (f.query.isBlank ? 0 : 1)
                Button { sheet = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease").font(.subheadline.weight(.semibold))
                        Text("Filters").font(.subheadline.weight(.medium))
                        if n > 0 { Text("\(n)").font(.caption2.weight(.bold)).foregroundStyle(Theme.bg).frame(width: 18, height: 18).background(Circle().fill(accent)) }
                    }
                    .foregroundStyle(n > 0 ? accent : Theme.text)
                    .padding(.horizontal, 14).frame(height: 42).background(Capsule().fill(n > 0 ? accent.opacity(0.18) : Theme.surfaceHigh))
                }.buttonStyle(.plain)
            }

            if outlets.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        QuickChip(label: "All", selected: f.sources.isEmpty, accent: accent) { var x = f; x.sources = []; setF(x) }
                        ForEach(pinned) { o in
                            QuickChip(label: o.name, count: facets.bySource[o.id] ?? 0, selected: f.sources.contains(o.id), accent: accent,
                                      icon: o.hasVideo && !o.hasSite ? "play.fill" : nil, dot: section == .NEWS ? outletColor(o.name) : nil) {
                                var x = f
                                if x.sources.contains(o.id) { x.sources.remove(o.id) } else { x.sources.insert(o.id) }
                                setF(x)
                            }
                        }
                        if outlets.count > pinned.count { QuickChip(label: "+\(outlets.count - pinned.count)", selected: false, accent: accent) { sheet = true } }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(views) { v in
                        QuickChip(label: v.name, selected: v.filter == f, accent: accent, icon: "star.fill") { setF(v.filter == f ? FeedFilter() : v.filter) }
                    }
                    if facets.unread > 0 || f.unreadOnly {
                        QuickChip(label: "Unread", count: facets.unread, selected: f.unreadOnly, accent: accent) { var x = f; x.unreadOnly.toggle(); setF(x) }
                    }
                    QuickChip(label: "Today", selected: f.time == .TODAY, accent: accent) { var x = f; x.time = f.time == .TODAY ? .ANY : .TODAY; setF(x) }
                    if hasBoth || f.type != nil {
                        QuickChip(label: "Videos", count: facets.byType[.VIDEO], selected: f.type == .VIDEO, accent: accent, icon: "play.fill") {
                            var x = f; x.type = f.type == .VIDEO ? nil : .VIDEO; setF(x)
                        }
                        QuickChip(label: "Articles", count: facets.byType[.ARTICLE], selected: f.type == .ARTICLE, accent: accent) {
                            var x = f; x.type = f.type == .ARTICLE ? nil : .ARTICLE; setF(x)
                        }
                    }
                    if !topics.isEmpty || f.topic != nil { Rectangle().fill(Theme.outline).frame(width: 1, height: 18).padding(.horizontal, 2) }
                    if let t = f.topic, !topics.contains(where: { $0.key == t }) {
                        QuickChip(label: "#" + t.capitalized, selected: true, accent: accent) { var x = f; x.topic = nil; setF(x) }
                    }
                    ForEach(topics) { t in
                        QuickChip(label: "#" + t.label, selected: f.topic == t.key, accent: accent) { var x = f; x.topic = f.topic == t.key ? nil : t.key; setF(x) }
                    }
                }
            }

            if f.activeCount > 0 {
                HStack {
                    Text("Showing \(shown) of \(base.count)" + describe(f)).font(.caption.weight(.medium)).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer()
                    Button("Clear") { setF(FeedFilter(sort: f.sort)) }.font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                }
            }
        }
        .padding(.top, 4)
        .sheet(isPresented: $sheet) {
            FilterSheet(section: section, base: base, accent: accent, noun: noun).environmentObject(media).environmentObject(settings).preferredColorScheme(.dark)
        }
    }

    private func describe(_ f: FeedFilter) -> String {
        var parts: [String] = []
        if f.sources.count == 1, let o = media.outlets.first(where: { f.sources.contains($0.id) }) { parts.append(o.name) }
        else if f.sources.count > 1 { parts.append("\(f.sources.count) sources") }
        if let t = f.topic { parts.append("#\(t)") }
        if !f.query.isBlank { parts.append("“\(f.query.trimmed)”") }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }
}

struct FilterSheet: View {
    let section: FeedSection
    let base: [MediaItem]
    let accent: Color
    let noun: String
    @EnvironmentObject var media: MediaStore
    @EnvironmentObject var settings: Settings
    @Environment(\.dismiss) var dismiss
    @State private var find = ""
    @State private var naming = false
    @State private var viewName = ""

    var body: some View {
        let f = media.prune(media.filter(for: section), section)
        let facets = media.facets(section, f, base: base)
        let outlets = media.sectionOutlets(section)
        let setF: (FeedFilter) -> Void = { media.setFilter(section, $0) }
        let views = settings.savedViews.filter { $0.section == section }
        let shown = media.filtered(section, f, base: base).count

        NavigationStack {
            Form {
                Section {
                    Picker("Sort", selection: Binding(get: { f.sort }, set: { var x = f; x.sort = $0; setF(x) })) {
                        ForEach(SortMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("Show", selection: Binding(get: { f.type?.rawValue ?? "ALL" }, set: { var x = f; x.type = ItemType(rawValue: $0); setF(x) })) {
                        Text("Everything · \(facets.byType.values.reduce(0, +))").tag("ALL")
                        Text("Articles · \(facets.byType[.ARTICLE] ?? 0)").tag("ARTICLE")
                        Text("Videos · \(facets.byType[.VIDEO] ?? 0)").tag("VIDEO")
                    }.pickerStyle(.segmented)
                    Picker("When", selection: Binding(get: { f.time }, set: { var x = f; x.time = $0; setF(x) })) {
                        ForEach(TimeFacet.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle(isOn: Binding(get: { f.unreadOnly }, set: { var x = f; x.unreadOnly = $0; setF(x) })) {
                        VStack(alignment: .leading) { Text("Unread only"); Text("\(facets.unread) unread").font(.caption).foregroundStyle(Theme.muted) }
                    }.tint(accent)
                } header: { Text("\(facets.total) items from \(outlets.count) \(section == .NEWS ? "outlets" : "channels")") }

                let kinds = Set(outlets.flatMap(\.kinds))
                if kinds.count > 1 {
                    Section("Platform") {
                        ForEach(kinds.sorted { $0.order < $1.order }, id: \.self) { k in
                            Button {
                                var x = f
                                if x.platforms.contains(k) { x.platforms.remove(k) } else { x.platforms.insert(k) }
                                setF(x)
                            } label: {
                                HStack {
                                    Image(systemName: f.platforms.contains(k) ? "checkmark.circle.fill" : "circle").foregroundStyle(f.platforms.contains(k) ? accent : Theme.muted)
                                    Text(k == .FEED ? "Websites" : k == .WEB ? "Web pages" : k.label).foregroundStyle(Theme.text)
                                    Spacer()
                                    Text("\(facets.byPlatform[k] ?? 0)").foregroundStyle(Theme.muted)
                                }
                            }
                        }
                    }
                }

                Section {
                    if outlets.count > 8 { TextField("Find a source", text: $find) }
                    let list = outlets.filter { find.isBlank || $0.name.localizedCaseInsensitiveContains(find.trimmed) }.sorted { a, b in
                        let sa = f.sources.contains(a.id), sb = f.sources.contains(b.id)
                        if sa != sb { return sa }
                        let ca = facets.bySource[a.id] ?? 0, cb = facets.bySource[b.id] ?? 0
                        return ca != cb ? ca > cb : a.name.lowercased() < b.name.lowercased()
                    }
                    ForEach(list) { o in
                        let c = facets.bySource[o.id] ?? 0
                        Button {
                            var x = f
                            if x.sources.contains(o.id) { x.sources.remove(o.id) } else { x.sources.insert(o.id) }
                            setF(x)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: f.sources.contains(o.id) ? "checkmark.square.fill" : "square").foregroundStyle(f.sources.contains(o.id) ? accent : Theme.muted)
                                if section == .NEWS { Circle().fill(outletColor(o.name)).frame(width: 8, height: 8) }
                                VStack(alignment: .leading) {
                                    Text(o.name).foregroundStyle(Theme.text).lineLimit(1)
                                    Text(platformLabel(o)).font(.caption).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Text("\(c)").foregroundStyle(Theme.muted)
                            }.opacity(c == 0 && !f.sources.contains(o.id) ? 0.5 : 1)
                        }
                    }
                } header: {
                    HStack {
                        Text(section == .NEWS ? "Outlets" : "Channels")
                        Spacer()
                        if !f.sources.isEmpty { Button("Show all") { var x = f; x.sources = []; setF(x) }.font(.caption) }
                    }
                }

                Section("Saved views") {
                    if views.isEmpty { Text("Save the filters you use most, and they appear as the first chip.").font(.caption).foregroundStyle(Theme.muted) }
                    ForEach(views) { v in
                        Button { setF(v.filter) } label: { Label(v.name, systemImage: v.filter == f ? "star.fill" : "star").foregroundStyle(Theme.text) }
                            .swipeActions { Button(role: .destructive) { settings.savedViews.removeAll { $0.id == v.id } } label: { Label("Delete", systemImage: "trash") } }
                    }
                    Button { viewName = suggest(f); naming = true } label: { Label("Save as view", systemImage: "plus") }.disabled(f.activeCount == 0)
                }
            }
            .scrollContentBackground(.hidden).background(Theme.bg)
            .navigationTitle("Filter \(noun)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Reset") { setF(FeedFilter()) }.disabled(f.isDefault) }
                ToolbarItem(placement: .confirmationAction) { Button("Show \(shown)") { dismiss() }.bold() }
            }
            .alert("Save view", isPresented: $naming) {
                TextField("Name", text: $viewName)
                Button("Save") {
                    let name = String(viewName.trimmed.prefix(32))
                    guard !name.isEmpty else { return }
                    settings.savedViews.removeAll { $0.section == section && $0.name == name }
                    settings.savedViews.append(SavedView(section: section, name: name, filter: f))
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.large])
    }

    private func platformLabel(_ o: Outlet) -> String {
        var seen: [String] = []
        for k in o.kinds.sorted(by: { $0.order < $1.order }) { let l = k.isSite ? "Site" : k.label; if !seen.contains(l) { seen.append(l) } }
        return seen.joined(separator: " + ")
    }

    private func suggest(_ f: FeedFilter) -> String {
        var p: [String] = []
        if f.sources.count == 1, let o = media.outlets.first(where: { f.sources.contains($0.id) }) { p.append(o.name) } else if f.sources.count > 1 { p.append("\(f.sources.count) sources") }
        if let t = f.topic { p.append(t.capitalized) }
        if !f.query.isBlank { p.append(f.query.trimmed) }
        if f.type == .VIDEO { p.append("videos") } else if f.type == .ARTICLE { p.append("articles") }
        if f.time != .ANY { p.append(f.time.label.lowercased()) }
        if f.unreadOnly { p.append("unread") }
        let s = p.joined(separator: " · ")
        return String((s.prefix(1).uppercased() + s.dropFirst()).prefix(32))
    }
}
