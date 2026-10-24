import SwiftUI
import BastionCore

extension BrowserTab {
    /// Where the user meant to go when they've been forwarded to a different site (e.g. a domain sale page).
    var redirectedFrom: String? {
        guard let i = intendedUrl, let ih = URLs.host(i), let ch = URLs.host(url), !Wayback.isArchived(url) else { return nil }
        return Domains.base(ih) != Domains.base(ch) ? i : nil
    }
}

/// "Web history": dial in a month and year and open the Wayback Machine's capture nearest to it.
struct WebHistorySheet: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var tm: TabManager
    @Environment(\.dismiss) var dismiss
    @State private var original = ""
    @State private var year = 2020
    @State private var month = 1
    @State private var busy = false
    @State private var error: String?

    static let firstYear = 1996
    private var thisYear: Int { Calendar.current.component(.year, from: Date()) }

    /// If the user was redirected, the address they asked for comes first; the page they landed on is the alternative.
    private var subjects: [String] {
        let current = Wayback.originalUrl(tab.url)
        if let asked = tab.redirectedFrom { return [asked, current] }
        return [tab.parked ? (tab.intendedUrl ?? current) : current]
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if subjects.count > 1 {
                    Text("Look up").font(.caption.weight(.medium)).foregroundStyle(Theme.muted)
                    HStack(spacing: 8) {
                        ForEach(Array(subjects.enumerated()), id: \.offset) { i, u in
                            let h = URLs.host(u)?.removingPrefix("www.") ?? u
                            QuickChip(label: i == 0 ? "\(h) (you asked for)" : h, selected: original == u) { original = u }
                        }
                    }
                }
                HStack(spacing: 0) {
                    Picker("Month", selection: $month) {
                        ForEach(1...12, id: \.self) { m in Text(Calendar.current.monthSymbols[m - 1]).tag(m) }
                    }.pickerStyle(.wheel).frame(maxWidth: .infinity)
                    Picker("Year", selection: $year) {
                        ForEach(Self.firstYear...thisYear, id: \.self) { y in Text(String(y)).tag(y) }
                    }.pickerStyle(.wheel).frame(width: 120)
                }
                .frame(height: 170).clipped()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach([("1 year ago", 1), ("5 years ago", 5), ("10 years ago", 10), ("20 years ago", 20)], id: \.1) { label, back in
                            QuickChip(label: label, selected: false) { year = max(Self.firstYear, thisYear - back) }
                        }
                        QuickChip(label: "Earliest", selected: false) { year = Self.firstYear; month = 1 }
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(Theme.danger) }
                Button(action: go) {
                    HStack {
                        if busy { ProgressView().tint(Theme.bg); Text("Searching the archive…") } else { Text("Go to \(Wayback.formatMonth(year, month))").bold() }
                    }.frame(maxWidth: .infinity).frame(height: 44)
                }.buttonStyle(.borderedProminent).tint(Theme.teal).disabled(busy)
                Text("Opens the Internet Archive's copy closest to that month. If nothing was saved then, you'll get the nearest capture. Only the address and the date are sent.")
                    .font(.caption).foregroundStyle(Theme.muted)
                Spacer()
            }
            .padding(20)
            .background(Theme.bg)
            .navigationTitle("Web history").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Web history").font(.headline)
                        Text(URLs.host(original)?.removingPrefix("www.") ?? original).font(.caption2).foregroundStyle(Theme.muted)
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) }
            }
        }
        .onAppear {
            original = subjects[0]
            if let d = Wayback.captureDate(tab.url) { year = d.year ?? thisYear; month = d.month ?? 1 }
            else {
                // a parked site most likely wants "the last time it was real": start at today and let the archive find it
                year = tab.parked ? thisYear : thisYear - 5
                month = Calendar.current.component(.month, from: Date())
            }
        }
        .presentationDetents([.large])
    }

    private func go() {
        busy = true; error = nil
        Task {
            switch await Wayback.closest(original, year: year, month: month) {
            case .found(let snap, _): tab.archiveRequest = (year, month); tm.navigate(tab, snap.url); dismiss()
            case .tryDirect(let u): tab.archiveRequest = (year, month); tm.navigate(tab, u); dismiss()
            case .failed(let m): error = m
            }
            busy = false
        }
    }
}

struct ArchiveBanner: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var tm: TabManager
    @EnvironmentObject var router: Router
    var body: some View {
        if let c = Wayback.captureDate(tab.url) {
            let req = tab.archiveRequest
            let same = req != nil && req!.0 == c.year && req!.1 == c.month
            HStack(spacing: 8) {
                Image(systemName: "calendar").font(.caption).foregroundStyle(Theme.warn)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Archived copy · \(Wayback.formatDate(c))").font(.caption.weight(.semibold)).foregroundStyle(Theme.warn)
                    Text(req == nil ? "From the Internet Archive" : same ? "Captured in the month you asked for" : "Nearest capture to \(Wayback.formatMonth(req!.0, req!.1))")
                        .font(.caption2).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Change") { router.sheet = .webHistory }.font(.caption.weight(.semibold)).foregroundStyle(Theme.warn)
                Button { tab.archiveRequest = nil; tm.navigate(tab, Wayback.originalUrl(tab.url)) } label: { Label("Live", systemImage: "arrow.clockwise").font(.caption.weight(.semibold)) }
                    .foregroundStyle(Theme.teal)
            }
            .padding(.horizontal, 14).padding(.vertical, 6).background(Theme.warn.opacity(0.14))
        }
    }
}

/// Shown when the user was bounced somewhere they didn't ask for — typically an expired domain forwarded to a
/// registrar's sale page. Names the site they wanted and offers its history, rather than leaving them on an ad.
struct RedirectNotice: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var router: Router
    var body: some View {
        let from = tab.redirectedFrom
        if !Wayback.isArchived(tab.url) && (tab.parked || from != nil) {
            let wanted = URLs.host(from ?? tab.intendedUrl ?? tab.url)?.removingPrefix("www.") ?? ""
            let landed = URLs.host(tab.url)?.removingPrefix("www.") ?? ""
            HStack(spacing: 10) {
                Image(systemName: "info.circle").font(.caption).foregroundStyle(Theme.teal)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.parked ? "\(wanted) is no longer an active site" : "Redirected from \(wanted)").font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
                    Text(tab.parked ? (from != nil ? "It now forwards to a domain sale page on \(landed)." : "The domain is parked or listed for sale.") : "You asked for \(wanted); it sent you to \(landed).")
                        .font(.caption2).foregroundStyle(Theme.muted).lineLimit(2)
                }
                Spacer()
                Button(tab.parked ? "See how it was" : "History") { router.sheet = .webHistory }.font(.caption.weight(.semibold)).foregroundStyle(Theme.teal)
                Button { tab.noticeDismissedFor = tab.url } label: { Image(systemName: "xmark").font(.caption2) }.foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 8).background(Theme.surfaceHigh)
        }
    }
}
