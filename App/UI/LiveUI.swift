import SwiftUI
import BastionCore

/// "Live now": a red LED with how many channels are on air (3/12), on-air cards, and the Offline tab.
struct LiveNowSection: View {
    let onAddChannel: () -> Void
    @EnvironmentObject var media: MediaStore
    @EnvironmentObject var router: Router
    @State private var showOffline = false
    @State private var ask: MediaSource?
    @State private var addingPack = false

    var body: some View {
        let channels = media.channels
        let live = media.liveNow
        let offline = media.offline
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LiveLed(on: !live.isEmpty)
                Text("Live now").font(.headline).foregroundStyle(Theme.text)
                if !channels.isEmpty {
                    Text("\(live.count)/\(channels.count) live").font(.caption.weight(.semibold)).foregroundStyle(live.isEmpty ? Theme.muted : Theme.live)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill((live.isEmpty ? Theme.muted : Theme.live).opacity(0.15)))
                }
                Spacer()
                if media.liveChecking { ProgressView().controlSize(.small) }
                else if !channels.isEmpty { Button { Task { await media.checkLive(force: true) } } label: { Image(systemName: "arrow.clockwise").foregroundStyle(Theme.muted) } }
                Button(action: onAddChannel) { Image(systemName: "plus").font(.body.weight(.semibold)).foregroundStyle(Theme.teal) }.padding(.leading, 6)
            }
            if channels.isEmpty {
                VStack(spacing: 10) {
                    Text("Live channels, one tap apart").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Text("Add YouTube, Twitch, Rumble, PeerTube or Owncast channels — Bastion checks who's on air from your phone.")
                        .font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    Button {
                        addingPack = true
                        Task { for u in Live.newsPack { _ = try? await media.add(u) }; addingPack = false }
                    } label: {
                        Label(addingPack ? "Adding…" : "Add 24/7 news channels", systemImage: "antenna.radiowaves.left.and.right").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(Theme.live).disabled(addingPack)
                    Text("Al Jazeera English · DW News · France 24 · Sky News · NASA").font(.caption2).foregroundStyle(Theme.muted)
                    Button("Add your own channel", action: onAddChannel).font(.subheadline)
                }.padding(18).frame(maxWidth: .infinity).card(20)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(live, id: \.0.id) { pair in
                            LiveCard(src: pair.0, st: pair.1) { router.liveStart = pair.0.id }
                        }
                        if !offline.isEmpty {
                            Button { showOffline = true } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: "moon.zzz.fill").font(.title2).foregroundStyle(Theme.muted)
                                    Text("Offline · \(offline.count)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                    Text("Old episodes").font(.caption).foregroundStyle(Theme.teal)
                                }
                                .frame(width: live.isEmpty ? nil : 120, height: 150).frame(maxWidth: live.isEmpty ? .infinity : nil)
                                .card(16).overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.outline, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showOffline) {
            OfflineSheet(offline: offline) { s in ask = s }.environmentObject(media).preferredColorScheme(.dark)
        }
        .alert(ask.map { "\($0.name) is off air" } ?? "", isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } })) {
            Button("Show old episodes") { if let s = ask { showOffline = false; router.episodesFor = s }; ask = nil }
            Button("Not now", role: .cancel) { ask = nil }
        } message: { Text("Would you like to see old episodes? The most recent ones are shown first, and they play right here.") }
    }
}

struct LiveCard: View {
    let src: MediaSource
    let st: LiveStatus
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    if let t = st.thumbnailUrl { Thumb(url: t) } else { Theme.surfaceHighest }
                    HStack(spacing: 4) {
                        Circle().fill(.white).frame(width: 6, height: 6)
                        Text("LIVE").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.white)
                    }.padding(.horizontal, 6).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 5).fill(Theme.live)).padding(8)
                    if let v = st.viewers {
                        Text("\(formatCount(v)) watching").font(.caption2.weight(.medium)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(.black.opacity(0.6)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(8)
                    }
                }
                .frame(width: 220, height: 124).clipShape(RoundedRectangle(cornerRadius: 12))
                Text(src.name).font(.caption.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(st.title).font(.caption2).foregroundStyle(Theme.muted).lineLimit(1)
            }.frame(width: 220)
        }.buttonStyle(.plain)
    }
}

struct OfflineSheet: View {
    let offline: [MediaSource]
    let pick: (MediaSource) -> Void
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            List(offline) { s in
                Button { pick(s) } label: {
                    HStack(spacing: 12) {
                        LetterAvatar(host: s.name)
                        VStack(alignment: .leading) {
                            Text(s.name).foregroundStyle(Theme.text)
                            Text(Live.target(s).kind.label).font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Text("Episodes").font(.subheadline.weight(.medium)).foregroundStyle(Theme.teal)
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Theme.bg)
            .navigationTitle("Offline channels").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) { Text("Tap a channel to catch up on its past episodes.").font(.caption).foregroundStyle(Theme.muted).padding(.top, 4) }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}

/// Past episodes of a channel, newest first, playable in the sandboxed player.
struct EpisodesScreen: View {
    let source: MediaSource
    @EnvironmentObject var router: Router
    @EnvironmentObject var tm: TabManager
    @EnvironmentObject var settings: Settings
    @Environment(\.dismiss) var dismiss
    @State private var episodes: [Episode]?
    @State private var error: String?
    @State private var playing: (Episode, String)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let p = playing {
                        let ep = p.0
                        EmbedPlayer(playUrl: p.1, hls: false).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 14))
                        Text(ep.title).font(.headline).foregroundStyle(Theme.text)
                        HStack {
                            Text(ep.publishedAt > 0 ? timeAgo(ep.publishedAt) : "").font(.caption).foregroundStyle(Theme.muted)
                            Spacer()
                            Button("Open in browser") { dismiss(); if let t = tm.current { tm.navigate(t, ep.pageUrl) } }.font(.caption.weight(.medium))
                        }
                    }
                    if let error { Text(error).foregroundStyle(Theme.muted).padding(.vertical, 30) }
                    else if let episodes {
                        if episodes.isEmpty { Text("No past episodes found.").foregroundStyle(Theme.muted).padding(.vertical, 30) }
                        ForEach(episodes) { ep in
                            Button { Task { if let u = await Episodes.playable(ep) { playing = (ep, u) } else { dismiss(); if let t = tm.current { tm.navigate(t, ep.pageUrl) } } } } label: {
                                HStack(spacing: 12) {
                                    ZStack(alignment: .bottomTrailing) {
                                        if let t = ep.thumbnailUrl { Thumb(url: t) } else { Theme.surfaceHighest }
                                        if let d = Episodes.formatDuration(ep.durationSec) ?? ep.durationText {
                                            Text(d).font(.caption2.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 4).background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.7))).padding(4)
                                        }
                                    }.frame(width: 140, height: 79).clipShape(RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(ep.title).font(.subheadline.weight(.semibold)).foregroundStyle(playing?.0.id == ep.id ? Theme.teal : Theme.text).lineLimit(3)
                                        Text([ep.publishedAt > 0 ? timeAgo(ep.publishedAt) : nil, ep.wasLive ? "Past broadcast" : nil].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(Theme.muted)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }.buttonStyle(.plain)
                        }
                    } else { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40) }
                }.padding(16)
            }
            .background(Theme.bg)
            .navigationTitle(source.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark") } } }
        }
        .task {
            do { episodes = try await Episodes.load(source, hideShorts: settings.mediaHideShorts) }
            catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't load episodes." }
        }
    }
}

/// Full-screen live viewer: swipe the player or use the dial to flick between channels that are on air.
struct LiveViewer: View {
    let startId: String
    @EnvironmentObject var media: MediaStore
    @EnvironmentObject var tm: TabManager
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) var dismiss
    @State private var currentId: String = ""
    @State private var drag: CGFloat = 0
    @State private var sleepAt: Date?

    var body: some View {
        let live = media.liveNow
        let idx = live.firstIndex { $0.0.id == currentId } ?? 0
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: { Image(systemName: "chevron.down").font(.title3.weight(.semibold)).foregroundStyle(.white) }
                if live.indices.contains(idx) {
                    let s = live[idx].0, st = live[idx].1
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            LiveLed(size: 7)
                            Text(s.name).font(.headline).foregroundStyle(.white).lineLimit(1)
                        }
                        Text(st.viewers.map { "\(formatCount($0)) watching" } ?? Live.target(s).kind.label).font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    Menu {
                        ForEach([15, 30, 60, 90], id: \.self) { m in Button("\(m) minutes") { sleepAt = Date().addingTimeInterval(Double(m) * 60) } }
                        if sleepAt != nil { Button("Cancel sleep timer", role: .destructive) { sleepAt = nil } }
                    } label: { Image(systemName: sleepAt == nil ? "moon" : "moon.fill").foregroundStyle(sleepAt == nil ? .white : Theme.gold) }
                    if let page = st.pageUrl {
                        Button { dismiss(); if let t = tm.current { tm.navigate(t, page) } } label: { Image(systemName: "safari").foregroundStyle(.white) }
                    }
                } else { Spacer() }
            }
            .padding(16)

            if live.indices.contains(idx), let url = live[idx].1.playUrl {
                EmbedPlayer(playUrl: url, hls: live[idx].1.hls).id(live[idx].0.id)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .offset(x: drag)
                    .gesture(DragGesture(minimumDistance: 30).onChanged { drag = $0.translation.width * 0.4 }.onEnded { v in
                        withAnimation(.spring()) { drag = 0 }
                        if v.translation.width < -80 { step(live, idx, 1) } else if v.translation.width > 80 { step(live, idx, -1) }
                    })
                Text(live[idx].1.title).font(.subheadline).foregroundStyle(.white.opacity(0.9)).lineLimit(2).padding(.horizontal, 16).padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("This channel just went off air.").foregroundStyle(.white.opacity(0.7)).frame(maxWidth: .infinity, minHeight: 220)
            }

            HStack(spacing: 28) {
                RoundControl(icon: "backward.end.fill", enabled: live.count > 1) { step(live, idx, -1) }
                VStack(spacing: 2) {
                    Text("\(live.isEmpty ? 0 : idx + 1)").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(.white).monospacedDigit()
                    Text("of \(live.count) on air").font(.caption2).foregroundStyle(.white.opacity(0.6))
                }.frame(width: 90)
                RoundControl(icon: "forward.end.fill", enabled: live.count > 1) { step(live, idx, 1) }
            }.padding(.vertical, 18)

            Text("ON AIR NOW").font(.caption.weight(.bold)).tracking(2).foregroundStyle(.white.opacity(0.5)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(live, id: \.0.id) { pair in
                            let s = pair.0, st = pair.1
                            Button { withAnimation { currentId = s.id } } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    ZStack { if let t = st.thumbnailUrl { Thumb(url: t) } else { Theme.surfaceHighest } }
                                        .frame(width: 140, height: 79).clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(s.id == currentId ? Theme.live : .clear, lineWidth: 2))
                                    Text(s.name).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                }.frame(width: 140)
                            }.buttonStyle(.plain).id(s.id)
                        }
                    }.padding(.horizontal, 16)
                }
                .onChange(of: currentId) { id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
            Spacer()
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { currentId = startId }
        .task(id: sleepAt) {
            guard let at = sleepAt else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(0, at.timeIntervalSinceNow) * 1_000_000_000))
            if !Task.isCancelled && sleepAt != nil { dismiss() }
        }
    }

    private func step(_ live: [(MediaSource, LiveStatus)], _ idx: Int, _ d: Int) {
        guard !live.isEmpty else { return }
        let n = (idx + d + live.count) % live.count
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation { currentId = live[n].0.id }
    }
}

struct RoundControl: View {
    let icon: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3).foregroundStyle(.white.opacity(enabled ? 1 : 0.3))
                .frame(width: 56, height: 56).background(Circle().fill(.white.opacity(0.1)))
        }.disabled(!enabled)
    }
}
