import SwiftUI
import SwiftData
import WebKit

/// One-time "Connect your PTO" flow:
///  1. Enter the PTO site address.
///  2. Sign in on Membership Toolkit's own page (we never see the password — we keep the session).
///  3. Pick your child's grade(s) for newsletters.
/// Afterwards the calendar syncs with no further login, and newsletters refresh on the saved session.
struct PTOConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Child.sortOrder) private var children: [Child]
    @StateObject private var model = PTOConnectModel()

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .site:     siteEntry
                case .signIn:   signIn
                case .grades:   gradePicker
                case .saving:   ProgressView("Setting up…").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .done:     done
                case .error(let m): errorView(m)
                }
            }
            .navigationTitle("Connect PTO")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .onAppear { model.configure(context: context, children: children) }
    }

    private var siteEntry: some View {
        Form {
            Section {
                TextField("yourpto.membershiptoolkit.com", text: $model.siteInput)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            } header: { Text("PTO website") } footer: {
                Text("Paste your PTO's Membership Toolkit web address. You'll sign in on their site — your password stays with them, never with this app.")
            }
            Section {
                Button("Continue") { model.startSignIn() }
                    .disabled(model.host.isEmpty)
            }
        }
    }

    private var signIn: some View {
        VStack(spacing: 0) {
            Text("Sign in to your PTO account below. This screen moves on automatically once you're in.")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            if let wv = model.webView { PTOWebView(webView: wv) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }

    private var gradePicker: some View {
        Form {
            Section {
                if model.grades.isEmpty {
                    Text("No grade newsletters were found. You can still finish — the PTO calendar will sync. You can add news later.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.grades, id: \.path) { g in
                    Button {
                        if model.selectedGrades.contains(g.path) { model.selectedGrades.remove(g.path) }
                        else { model.selectedGrades.insert(g.path) }
                    } label: {
                        HStack {
                            Text(g.label).foregroundStyle(.primary)
                            Spacer()
                            if model.selectedGrades.contains(g.path) {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
            } header: { Text("Your child's grade(s)") } footer: {
                Text("We'll summarize each grade's PTO newsletters on your phone and show them in PTO News.")
            }
            Section {
                if let feed = model.discoveredFeed {
                    Label("PTO calendar found", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color(hex: "2E7D4F")).font(.subheadline)
                    Text(feed.host ?? "").font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("PTO calendar not found — you can retry later", systemImage: "exclamationmark.circle")
                        .foregroundStyle(Theme.attention).font(.subheadline)
                }
            }
            Section { Button("Finish") { Task { await model.save() } } }
        }
    }

    private var done: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 48)).foregroundStyle(Theme.accent)
            Text("PTO connected").font(.title3.bold())
            Text("Calendar events will appear in your Calendar, and summarized news in PTO News.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
        }.padding()
    }

    private func errorView(_ m: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(Theme.attention)
            Text(m).font(.subheadline).multilineTextAlignment(.center).padding(.horizontal)
            Button("Try again") { model.phase = .site }.buttonStyle(.bordered)
        }.padding()
    }
}

/// Shows an existing WKWebView (the portal's) so the parent can sign in on the PTO's own page.
struct PTOWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
final class PTOConnectModel: ObservableObject {
    enum Phase: Equatable { case site, signIn, grades, saving, done, error(String) }

    @Published var phase: Phase = .site
    @Published var siteInput = "millburnmspto.membershiptoolkit.com"   // launch district default
    @Published var selectedGrades: Set<String> = []
    @Published private(set) var webView: WKWebView?
    @Published private(set) var grades: [PTOPortal.GradeRef] = []
    @Published private(set) var discoveredFeed: URL?

    private var portal: PTOPortal?
    private var poll: Task<Void, Never>?
    private var context: ModelContext?
    private var children: [Child] = []

    var host: String {
        var s = siteInput.trimmingCharacters(in: .whitespaces).lowercased()
        s = s.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        return String(s.split(separator: "/").first ?? "")
    }

    func configure(context: ModelContext, children: [Child]) {
        self.context = context; self.children = children
    }

    func startSignIn() {
        let h = host
        guard !h.isEmpty else { return }
        let p = PTOPortal(host: h)
        portal = p
        webView = p.webView
        phase = .signIn
        Task { try? await p.loadHome(); startPolling() }
    }

    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            for _ in 0..<150 {   // ~5 min max
                try? await Task.sleep(for: .seconds(2))
                guard let self, let p = self.portal else { return }
                if await p.isSignedIn() { await self.onSignedIn(); return }
            }
        }
    }

    private func onSignedIn() async {
        poll?.cancel()
        guard let p = portal else { return }
        discoveredFeed = try? await p.discoverCalendarFeed()
        grades = (try? await p.discoverGrades()) ?? []
        phase = .grades
    }

    func save() async {
        guard let context, let p = portal else { phase = .error("Something went wrong. Please try again."); return }
        phase = .saving
        let cookies = await p.capturedCookies()
        guard !cookies.isEmpty else { phase = .error("We couldn't keep your PTO session. Please sign in again."); return }

        let existing = (try? context.fetch(FetchDescriptor<PTOAccount>()))?.first
        let acct = existing ?? PTOAccount(host: host, displayName: Self.name(for: host))
        acct.host = host
        acct.calendarFeedURLString = discoveredFeed?.absoluteString
        let picked = grades.filter { selectedGrades.contains($0.path) }
        acct.gradePaths = picked.map(\.path)
        acct.gradeLabels = picked.map(\.label)
        acct.connectedAt = .now
        acct.needsReconnect = false
        acct.lastNewsRefresh = nil           // let the next sync pull news right away
        if existing == nil { context.insert(acct) }
        try? Keychain.set(PTOCredential(cookies: cookies), for: acct.keychainKey)

        if let feed = discoveredFeed {
            for kid in children where !kid.allCalendarFeeds.contains(feed) {
                kid.setCalendarFeeds(kid.allCalendarFeeds + [feed])
            }
        }
        try? context.save()

        // Kick off the first PTO pull in the background so news/calendar appear without waiting.
        let ctx = context
        Task { await SyncEngine(context: ctx).refreshAll() }

        phase = .done
    }

    static func name(for host: String) -> String {
        let sub = host.split(separator: ".").first.map(String.init) ?? "PTO"
        return sub.isEmpty ? "PTO" : sub.uppercased() + " PTO"
    }
}
