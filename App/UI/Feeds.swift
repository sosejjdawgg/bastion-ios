import SwiftUI
import BastionCore

private let page = 25

// MARK: - Media & user-made modules

/// Media and every module the user makes ("Entertainment", "Hobbies"…): same format, own filters and channels.
struct FeedModuleView: View {
    @ObservedObject var tab: BrowserTab
    let moduleId: String
    @EnvironmentObject var media: MediaStore
    @EnvironmentObject var router: Router
    @EnvironmentObject var settings: Settings
    @State private var limit = page
    @State private var showAdd = false
    @State private var showSettings = false

    var body: some View {
        if let m = media.module(moduleId) {
            let s = m.section
            let accent = m.id == FeedModule.MEDIA ? Theme.teal : m.color
            let base = media.items(in: s)
            let f = media.filter(for: s)
            let visible = media.filtered(s, f, base: base)
            let channels = media.outlets(in: s)
            let single = media.prune(f, s).sources.count == 1
            let unread = base.filter { !media.readIds.contains($0.id) }.count

            VStack(alignment: .leading, spacing: 8) {
                ModuleHeader(title: m.title, sub: channels.isEmpty ? nil : (unread > 0 ? "\(unread) new" : "\(channels.count) channels"),
                             leading: m.builtin ? nil : AnyView(Circle().fill(accent).frame(width: 10, height: 10)),
                             collapsed: m.collapsed, onToggle: { media.setCollapsed(m.id, !m.collapsed) }, refreshing: media.refreshing,
                             onRefresh: channels.isEmpty ? nil : { Task { await media.refresh(force: true) } },
                             onAdd: { showAdd = true }, onSettings: { showSettings = true })
                if !m.collapsed {
                    if channels.isEmpty {
                        if m.builtin { EmptyMedia(onAdd: { showAdd = true }) } else { EmptyCustom(title: m.title, accent: accent) { showAdd = true } }
                    } else {
                        FilterBar(section: s, base: base, shown: visible.count, accent: accent, noun: m.title)
                        if visible.isEmpty {
                            EmptyResult(refreshing: media.refreshing, filtered: f.activeCount > 0)
                        } else {
                            LazyVStack(spacing: 8) {
                                ForEach(visible.prefix(limit)) { item in
                                    MediaCard(item: item, sourceName: media.name(of: item.sourceId), read: media.readIds.contains(item.id), showSource: !single) {
                                        openMediaItem(item, tab: tab)
                                    }
                                }
                            }
                            PagingFooter(visible: visible, limit: $limit, isPrivate: tab.isPrivate, unit: "items", total: visible.count)
                        }
                    }
                }
            }
            .onChange(of: f) { _ in limit = page }
            .sheet(isPresented: $showAdd) { AddSourceSheet(target: m).environmentObject(media).preferredColorScheme(.dark) }
            .sheet(isPresented: $showSettings) {
                ModuleSettingsSheet(moduleId: m.id).environmentObject(media).environmentObject(router).preferredColorScheme(.dark)
            }
        }
    }
}

struct MediaCard: View {
    let item: MediaItem
    let sourceName: String
    let read: Bool
    let showSource: Bool
    let open: () -> Void
    @EnvironmentObject var settings: Settings

    var body: some View {
        let video = item.type == .VIDEO
        let thumbs = settings.mediaThumbnails && item.thumbnailUrl != nil
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                if video && thumbs {
                    ZStack {
                        Thumb(url: item.thumbnailUrl!).aspectRatio(16 / 9, contentMode: .fit)
                        PlayBadge()
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(3).multilineTextAlignment(.leading)
                        HStack(spacing: 4) {
                            if video && !thumbs { Image(systemName: "play.fill").font(.caption2).foregroundStyle(Theme.teal) }
                            Text([showSource ? sourceName.nilIfBlank : nil, item.publishedAt > 0 ? timeAgo(item.publishedAt) : nil].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2.weight(.medium)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        if !item.snippet.isBlank && !video {
                            Text(item.snippet).font(.caption).foregroundStyle(Theme.text.opacity(0.75)).lineLimit(2).multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                    if !video && thumbs { Thumb(url: item.thumbnailUrl!).frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 10)) }
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(read ? 0.55 : 1)
        }.buttonStyle(.plain)
    }
}

struct PlayBadge: View {
    var size: CGFloat = 44
    var body: some View {
        Image(systemName: "play.fill").foregroundStyle(.white).frame(width: size, height: size).background(Circle().fill(.black.opacity(0.55)))
    }
}

struct EmptyResult: View {
    let refreshing: Bool
    let filtered: Bool
    var body: some View {
        Text(refreshing ? "Fetching your sources…" : filtered ? "Nothing matches these filters." : "No items yet. Pull down to refresh.")
            .font(.subheadline).foregroundStyle(Theme.muted).padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PagingFooter: View {
    let visible: [MediaItem]
    @Binding var limit: Int
    let isPrivate: Bool
    var unit = "items"
    let total: Int
    @EnvironmentObject var media: MediaStore
    var body: some View {
        HStack {
            if !isPrivate { Button("Mark all read") { media.markAllRead(visible) }.font(.subheadline.weight(.medium)).foregroundStyle(Theme.teal) }
            Spacer()
            if total > limit {
                Button("Show \(min(page, total - limit)) more") { limit += page }.font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8).overlay(Capsule().stroke(Theme.outline))
            } else { Text("\(total) \(unit)").font(.caption2).foregroundStyle(Theme.muted) }
        }.padding(.top, 6)
    }
}

private let mediaStarters = [
    ("The Verge", "https://www.theverge.com/rss/index.xml"), ("Ars Technica", "https://feeds.arstechnica.com/arstechnica/index"),
    ("Veritasium", "https://www.youtube.com/@veritasium"), ("Kurzgesagt", "https://www.youtube.com/@kurzgesagt"),
    ("Framatube (PeerTube)", "https://framatube.org/feeds/videos.xml?sort=-publishedAt")
]

struct EmptyMedia: View {
    let onAdd: () -> Void
    @EnvironmentObject var media: MediaStore
    @State private var adding = Set<String>()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your channels, without the noise").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
            Text("Creators, blogs and channels — YouTube, PeerTube, Rumble or any feed. News outlets go to Newsfeed automatically. No accounts, no ads, no recommendations.")
                .font(.caption).foregroundStyle(Theme.text.opacity(0.8))
            Button(action: onAdd) { Label("Add a source", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(Theme.teal)
            Text("Or start with").font(.caption.weight(.medium)).foregroundStyle(Theme.muted)
            StarterChips(starters: mediaStarters, adding: $adding)
        }.padding(18).card(20)
    }
}

struct StarterChips: View {
    let starters: [(String, String)]
    @Binding var adding: Set<String>
    var dots = false
    @EnvironmentObject var media: MediaStore
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(starters, id: \.1) { name, url in
                Button {
                    guard !adding.contains(url) else { return }
                    adding.insert(url)
                    Task { _ = try? await media.add(url) }
                } label: {
                    HStack(spacing: 6) {
                        if adding.contains(url) { ProgressView().controlSize(.mini) }
                        else if dots { Circle().fill(outletColor(name)).frame(width: 8, height: 8) }
                        else { Image(systemName: "plus").font(.caption) }
                        Text(name).font(.subheadline)
                    }
                    .foregroundStyle(Theme.text).padding(.horizontal, 12).frame(height: 32).overlay(Capsule().stroke(Theme.outline))
                }.buttonStyle(.plain)
            }
        }
    }
}

struct EmptyCustom: View {
    let title: String
    let accent: Color
    let onAdd: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(title) is ready").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
            Text("Add the channels, creators and sites you follow for this. Anything you add here stays here — it won't be moved to Newsfeed.")
                .font(.caption).foregroundStyle(Theme.text.opacity(0.8))
            Button(action: onAdd) { Label("Add a channel", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(accent)
        }.padding(18).card(20)
    }
}

// MARK: - Newsfeed

private let newsStarters = [
    ("BBC News", "https://feeds.bbci.co.uk/news/rss.xml"), ("The Guardian", "https://www.theguardian.com/world/rss"),
    ("Al Jazeera", "https://www.aljazeera.com/xml/rss/all.xml"), ("Sky News", "https://feeds.skynews.com/feeds/rss/home.xml"),
    ("GB News", "https://www.gbnews.com/feeds/news.rss"), ("Breaking Points", "https://www.youtube.com/@breakingpoints")
]

/// Newsfeed: one entry per outlet (site and channels merged) and one card per story. When several outlets cover
/// the same event, their headlines and videos fold into one card. The top story is what most outlets are covering.
struct NewsfeedView: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var media: MediaStore
    @EnvironmentObject var router: Router
    @State private var limit = 12
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var adding = Set<String>()

    var body: some View {
        let m = media.news
        let base = media.items(in: .NEWS)
        let f = media.filter(for: .NEWS)
        let visible = media.filtered(.NEWS, f, base: base)
        let outlets = media.outlets(in: .NEWS)
        let stories = f.sort == .NEWEST ? Stories.cluster(visible) : visible.map { Story(id: $0.id, items: [$0]) }
        let since = Clock.now - 12 * 3_600_000
        let top = stories.filter { $0.newest > since }.max { a, b in score(a) < score(b) }.flatMap { outletCount($0) >= 2 ? $0 : nil }
        let rest = stories.filter { $0.id != top?.id }
        let unread = base.filter { !media.readIds.contains($0.id) }.count

        VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(title: m.title, sub: outlets.isEmpty ? nil : (unread > 0 ? "\(unread) new" : "\(outlets.count) outlets"),
                         leading: AnyView(Image(systemName: "newspaper.fill").font(.subheadline).foregroundStyle(Theme.news)),
                         collapsed: m.collapsed, onToggle: { media.setCollapsed(m.id, !m.collapsed) }, refreshing: media.refreshing,
                         onRefresh: outlets.isEmpty ? nil : { Task { await media.refresh(force: true) } },
                         onAdd: { showAdd = true }, onSettings: { showSettings = true })
            if !m.collapsed {
                if outlets.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("The news, one story at a time").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        Text("Add outlets and citizen journalists. Each outlet's site and channel merge into one, and when several cover the same story you get one card with every headline and video.")
                            .font(.caption).foregroundStyle(Theme.text.opacity(0.8))
                        Button { showAdd = true } label: { Label("Add an outlet", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(Theme.news)
                        Text("Or start with").font(.caption.weight(.medium)).foregroundStyle(Theme.muted)
                        StarterChips(starters: newsStarters, adding: $adding, dots: true)
                    }.padding(18).card(20)
                } else {
                    FilterBar(section: .NEWS, base: base, shown: visible.count, accent: Theme.news, noun: m.title)
                    if stories.isEmpty {
                        EmptyResult(refreshing: media.refreshing, filtered: f.activeCount > 0)
                    } else {
                        LazyVStack(spacing: 10) {
                            if let top { TopStoryCard(story: top) { openMediaItem($0, tab: tab) } }
                            ForEach(rest.prefix(limit)) { st in StoryCard(story: st) { openMediaItem($0, tab: tab) } }
                        }
                        PagingFooter(visible: visible, limit: $limit, isPrivate: tab.isPrivate, unit: "stories", total: rest.count)
                    }
                }
            }
        }
        .onChange(of: f) { _ in limit = 12 }
        .sheet(isPresented: $showAdd) { AddSourceSheet(target: m).environmentObject(media).preferredColorScheme(.dark) }
        .sheet(isPresented: $showSettings) { ModuleSettingsSheet(moduleId: m.id).environmentObject(media).environmentObject(router).preferredColorScheme(.dark) }
    }

    private func outletCount(_ s: Story) -> Int { Set(s.items.map { media.groupKey($0.sourceId) }).count }
    private func score(_ s: Story) -> Int { outletCount(s) * 10 + s.items.count }
}

private func outletNames(_ st: Story, _ media: MediaStore) -> [String] {
    var out: [String] = []
    for i in st.items { let n = media.name(of: i.sourceId); if !out.contains(n) { out.append(n) } }
    return out
}

struct OutletBadges: View {
    let names: [String]
    var max = 3
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(names.prefix(max).enumerated()), id: \.offset) { i, n in
                if i > 0 { Text("  ·  ").font(.caption2).foregroundStyle(Theme.muted) }
                Circle().fill(outletColor(n)).frame(width: 7, height: 7).padding(.trailing, 5)
                Text(n).font(.caption.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
            }
            if names.count > max { Text("  +\(names.count - max)").font(.caption).foregroundStyle(Theme.muted) }
        }
    }
}

struct TopStoryCard: View {
    let story: Story
    let open: (MediaItem) -> Void
    @EnvironmentObject var media: MediaStore
    @EnvironmentObject var settings: Settings

    var body: some View {
        let lead = story.lead
        let thumb = settings.mediaThumbnails ? (story.items.first { $0.type == .VIDEO && $0.thumbnailUrl != nil } ?? story.items.first { $0.thumbnailUrl != nil }) : nil
        let names = outletNames(story, media)
        let videos = story.items.filter { $0.type == .VIDEO }.count
        VStack(alignment: .leading, spacing: 0) {
            if let thumb {
                ZStack(alignment: .topLeading) {
                    Thumb(url: thumb.thumbnailUrl!).aspectRatio(16 / 9, contentMode: .fit)
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    Text("TOP STORY").font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(Theme.bg)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 8).fill(Theme.news)).padding(12)
                    if thumb.type == .VIDEO { PlayBadge(size: 48).frame(maxWidth: .infinity, maxHeight: .infinity).onTapGesture { open(thumb) } }
                    Text("\(names.count) outlets" + (videos > 0 ? " · \(videos) video\(videos > 1 ? "s" : "")" : ""))
                        .font(.caption.weight(.medium)).foregroundStyle(.white).padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            } else {
                Text("TOP STORY · \(names.count) OUTLETS").font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(Theme.news).padding([.top, .horizontal], 16)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(displayTitle(lead.title)).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text).lineLimit(4)
                if !lead.snippet.isBlank { Text(lead.snippet).font(.subheadline).foregroundStyle(Theme.text.opacity(0.78)).lineLimit(3) }
                OutletBadges(names: names, max: 4).padding(.top, 2)
                Divider().overlay(Theme.outlineVariant)
                ForEach(story.items.filter { $0.id != lead.id }.prefix(4)) { CoverageRow(item: $0, open: open) }
                if story.items.count > 5 { Text("+\(story.items.count - 5) more").font(.caption.weight(.medium)).foregroundStyle(Theme.news) }
            }.padding(16)
        }
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle()).onTapGesture { open(lead) }
    }
}

struct StoryCard: View {
    let story: Story
    let open: (MediaItem) -> Void
    @EnvironmentObject var media: MediaStore
    @EnvironmentObject var settings: Settings
    @State private var expanded = false

    var body: some View {
        let lead = story.lead
        let read = story.items.allSatisfy { media.readIds.contains($0.id) }
        let names = outletNames(story, media)
        let video = lead.type == .VIDEO
        let thumbs = settings.mediaThumbnails && lead.thumbnailUrl != nil
        let videos = story.items.filter { $0.type == .VIDEO }.count
        VStack(alignment: .leading, spacing: 0) {
            if video && thumbs { ZStack { Thumb(url: lead.thumbnailUrl!).aspectRatio(16 / 9, contentMode: .fit); PlayBadge() } }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        OutletBadges(names: names)
                        Text(displayTitle(lead.title)).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(3)
                        if !lead.snippet.isBlank && !video { Text(lead.snippet).font(.caption).foregroundStyle(Theme.text.opacity(0.75)).lineLimit(2) }
                    }
                    Spacer(minLength: 0)
                    if !video && thumbs { Thumb(url: lead.thumbnailUrl!).frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 10)) }
                }
                HStack {
                    if video && !thumbs { Image(systemName: "play.fill").font(.caption2).foregroundStyle(Theme.news) }
                    Text(story.newest > 0 ? timeAgo(story.newest) : "").font(.caption2).foregroundStyle(Theme.muted)
                    Spacer()
                    if story.items.count > 1 {
                        Button { withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() } } label: {
                            HStack(spacing: 3) {
                                if (videos > 0 && !video) || videos > 1 { Image(systemName: "play.fill").font(.caption2) }
                                Text(expanded ? "Hide coverage" : "Full coverage · \(story.items.count)").font(.caption.weight(.medium))
                                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                            }.foregroundStyle(Theme.news).padding(.vertical, 4)
                        }.buttonStyle(.plain)
                    }
                }
                if expanded {
                    Divider().overlay(Theme.outlineVariant)
                    ForEach(story.items.filter { $0.id != lead.id }) { CoverageRow(item: $0, open: open) }
                }
            }.padding(14)
        }
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(read ? 0.55 : 1)
        .contentShape(Rectangle()).onTapGesture { open(lead) }
    }
}

struct CoverageRow: View {
    let item: MediaItem
    let open: (MediaItem) -> Void
    @EnvironmentObject var media: MediaStore
    @EnvironmentObject var settings: Settings
    var body: some View {
        let name = media.name(of: item.sourceId)
        let video = item.type == .VIDEO
        Button { open(item) } label: {
            HStack(spacing: 10) {
                if video, let t = item.thumbnailUrl, settings.mediaThumbnails {
                    ZStack { Thumb(url: t); Image(systemName: "play.fill").font(.caption).foregroundStyle(.white) }
                        .frame(width: 64, height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle().fill(outletColor(name)).frame(width: 6, height: 6)
                        Text(name + (video ? " · Video" : "") + (item.publishedAt > 0 ? " · \(timeAgo(item.publishedAt))" : "")).font(.caption2).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Text(displayTitle(item.title)).font(.subheadline).foregroundStyle(Theme.text).lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .opacity(media.readIds.contains(item.id) ? 0.55 : 1)
        }.buttonStyle(.plain)
    }
}

// MARK: - Add source

struct AddSourceSheet: View {
    let target: FeedModule?
    var liveFocus = false
    @EnvironmentObject var media: MediaStore
    @Environment(\.dismiss) var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(liveFocus ? "youtube.com/@channel, twitch.tv/name, rumble.com/c/…" : "bbc.co.uk, a feed URL, youtube.com/@name…", text: $text)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).focused($focused).submitLabel(.done).onSubmit(submit)
                    if let error { Text(error).font(.caption).foregroundStyle(Theme.danger) }
                } footer: {
                    Text(liveFocus ? "YouTube channels, Twitch, Rumble, PeerTube, Owncast servers and HLS streams (.m3u8). Live status is checked from your phone — no accounts."
                         : "News sites and blogs (Bastion finds their feed), RSS / Atom / JSON feeds, YouTube channels and playlists, PeerTube, Rumble, Twitch, and pages without a feed (headlines only).")
                }
                if liveFocus {
                    Section("24/7 news channels") {
                        Button {
                            busy = true
                            Task { for u in Live.newsPack { _ = try? await media.add(u) }; busy = false; dismiss() }
                        } label: { Label("Add the news pack (Al Jazeera, DW, France 24, Sky, NASA)", systemImage: "antenna.radiowaves.left.and.right") }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Theme.bg)
            .navigationTitle(target.map { !$0.builtin ? "Add to \($0.title)" : "Add a source" } ?? "Add a channel").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("Add", action: submit).bold().disabled(text.isBlank) }
                }
            }
        }
        .onAppear { focused = true }
        .presentationDetents([.medium, .large])
    }

    private func submit() {
        guard !text.isBlank, !busy else { return }
        busy = true; error = nil
        Task {
            do {
                // a user-made module keeps what you add to it; Newsfeed and Media sort themselves
                _ = try await media.add(text, section: target.flatMap { $0.builtin ? nil : $0.section })
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't add that source."
            }
            busy = false
        }
    }
}

// MARK: - Module settings

/// ⚙ on Newsfeed, Media and user-made modules: rename, globe flares, manage sources, new module, delete.
struct ModuleSettingsSheet: View {
    let moduleId: String
    @EnvironmentObject var media: MediaStore
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var creating = false
    @State private var confirmDelete = false

    var body: some View {
        if let m = media.module(moduleId) {
            NavigationStack {
                Form {
                    Section {
                        HStack {
                            TextField("Name", text: $name).onSubmit { media.rename(module: m.id, name) }
                            if m.builtin && name != m.defaultTitle { Button("Reset") { name = m.defaultTitle; media.rename(module: m.id, name) }.font(.caption) }
                        }
                    } header: { Text("Name") } footer: { Text("Shown on the home page and in Arrange home.") }
                    Section {
                        Toggle(isOn: Binding(get: { m.flare }, set: { media.setFlare(m.id, $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Flare new posts on the globe")
                                Text(m.flare ? "Places named in this module's headlines light up World events."
                                     : "Kept off the globe — good for entertainment, hobbies and anything that isn't world news.")
                                    .font(.caption).foregroundStyle(Theme.muted)
                            }
                        }.tint(m.color)
                    }
                    Section {
                        Button { commit(m); dismiss(); router.sheet = .sources } label: { Label("Manage sources", systemImage: "pencil") }
                        Button { creating = true } label: { Label("New module like this", systemImage: "plus") }
                        if !m.builtin { Button(role: .destructive) { confirmDelete = true } label: { Label("Delete module", systemImage: "trash") } }
                    } footer: {
                        Text((m.builtin ? "Built-in" : "Your module") + " · \(media.outlets(in: m.section).count) \(m.id == FeedModule.NEWS ? "outlets" : "channels")")
                    }
                }
                .scrollContentBackground(.hidden).background(Theme.bg)
                .navigationTitle("Module settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { commit(m); dismiss() }.bold() } }
                .sheet(isPresented: $creating) { NewModuleSheet { _ in commit(m); dismiss() }.environmentObject(media).preferredColorScheme(.dark) }
                .confirmationDialog("Delete \(m.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    let count = media.sources.filter { $0.section == m.section.key }.count
                    if count > 0 { Button("Delete module, keep \(count) channels") { media.deleteModule(m.id, deleteSources: false); dismiss() } }
                    Button(count > 0 ? "Delete module and channels" : "Delete", role: .destructive) { media.deleteModule(m.id, deleteSources: true); dismiss() }
                } message: { Text("Kept channels go back to Newsfeed or Media.") }
            }
            .onAppear { name = m.title }
            .presentationDetents([.medium, .large])
        }
    }

    private func commit(_ m: FeedModule) { if name.trimmed != m.title { media.rename(module: m.id, name) } }
}

/// Make a blank feed module. It appears below your other feed modules.
struct NewModuleSheet: View {
    var onCreated: (FeedModule) -> Void = { _ in }
    @EnvironmentObject var media: MediaStore
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var flare = false
    private let suggestions = ["Entertainment", "Hobbies", "Sport", "Music", "Gaming", "Science", "Cooking", "Podcasts"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Entertainment", text: $name)
                    FlowLayout(spacing: 6) {
                        ForEach(suggestions, id: \.self) { s in QuickChip(label: s, selected: name == s) { name = s } }
                    }.padding(.vertical, 4)
                } header: { Text("Name") }
                Section {
                    Toggle(isOn: $flare) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Flare new posts on the globe")
                            Text("Usually off for entertainment and hobbies.").font(.caption).foregroundStyle(Theme.muted)
                        }
                    }.tint(Theme.teal)
                } footer: { Text("Same format as Media: its own filters, saved views and channels. Rename or delete it any time from its ⚙.") }
            }
            .scrollContentBackground(.hidden).background(Theme.bg)
            .navigationTitle("New module").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { let m = media.createModule(name, flare: flare); dismiss(); onCreated(m) }.bold().disabled(name.isBlank)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
