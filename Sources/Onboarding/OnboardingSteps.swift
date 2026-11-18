import SwiftUI
import SwiftData

// MARK: 0 · Welcome

struct WelcomeStep: View {
    var next: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Everything about school, in one place").font(.largeTitle.bold())
            Text("Grades, homework, attendance and school days for all your kids, checked every morning.")
                .foregroundStyle(.secondary)
            GroupBox("Setup takes about 2 minutes") {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Your PowerSchool **parent** login", systemImage: "1.circle.fill")
                    Label("Your school's calendar link (optional)", systemImage: "2.circle.fill")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Label("Logins and school data stay on this iPhone.", systemImage: "lock.fill").font(.subheadline)
            Spacer()
            PrimaryButton("Get started", action: next)
        }
    }
}

// MARK: 1 · School

struct SchoolStep: View {
    @Binding var draft: OnboardingDraft
    var next: () -> Void
    var skip: () -> Void
    @State private var address = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Where do your kids go to school?").font(.title.bold())
            Text("Kids in different districts? Add the first one now, the others in a minute.").foregroundStyle(.secondary)
            Text("PowerSchool web address").font(.footnote.weight(.bold))
            TextField("yourdistrict.powerschool.com", text: $address)
                .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(14).background(.white, in: .rect(cornerRadius: 12))
            Text("It's the address you see when you sign in to the parent portal in a web browser.")
                .font(.footnote).foregroundStyle(.secondary)
            if let error { Text(error).font(.footnote).foregroundStyle(Theme.attention) }
            Spacer()
            PrimaryButton("Continue") {
                guard let url = Self.normalize(address) else { error = "That doesn't look like a web address."; return }
                draft.schools[draft.current].baseURL = url
                draft.schools[draft.current].displayName = url.host ?? ""
                next()
            }
            Button("My school doesn't use PowerSchool", action: skip).frame(maxWidth: .infinity)
        }
    }

    /// "Yourdistrict.powerschool.com/public/home.html" → https://yourdistrict.powerschool.com/
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        if !s.hasPrefix("http") { s = "https://" + s }
        guard var c = URLComponents(string: s), let host = c.host, host.contains(".") else { return nil }
        c.scheme = "https"; c.path = "/"; c.query = nil; c.fragment = nil
        return c.url
    }
}

// MARK: 2 · Parent PowerSchool sign-in

struct PowerSchoolStep: View {
    @Binding var draft: OnboardingDraft
    var next: () -> Void
    @State private var showSignIn = false

    var school: OnboardingDraft.School { draft.schools[draft.current] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in with your parent account").font(.title.bold())
            Text("One parent login usually covers all your kids in this district. Use **yours**, not your child's student login.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Label("You'll see your district's own sign-in page.", systemImage: "checkmark")
                Label("District uses a Google or Clever button? Tap it — that works too.", systemImage: "checkmark")
                Label("Your login is saved in this iPhone's Keychain for the morning refresh.", systemImage: "checkmark")
            }.font(.subheadline)
            DisclosureGroup("No parent account yet?") {
                Text("On the sign-in page choose **Create Account** and use the Access ID and Access Password from your school's letter or email. You can link every child there.")
                    .font(.footnote)
            }
            Spacer()
            PrimaryButton(school.credential == nil ? "Open PowerSchool sign-in" : "Signed in · Continue") {
                if school.credential == nil { showSignIn = true } else { next() }
            }
        }
        .sheet(isPresented: $showSignIn) {
            if let url = school.baseURL {
                NavigationStack {
                    PowerSchoolSignInView(baseURL: url) { cred, html, sso in
                        found(cred: cred, homeHTML: html, sso: sso)
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(url.host ?? "PowerSchool").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Cancel") { showSignIn = false } }
                }
            }
        }
    }

    private func found(cred: PowerSchoolCredential, homeHTML: String, sso: Bool) {
        var students = PortalParsers.students(homeHTML: homeHTML)
        if students.isEmpty {
            // Single-student accounts often show no student switcher.
            students = [PortalStudent(id: "current", name: PortalParsers.selectedStudentName(homeHTML: homeHTML) ?? "My child")]
        }
        let i = draft.current
        draft.schools[i].credential = cred
        draft.schools[i].usedSSO = sso
        draft.schools[i].kids = students.map { s in
            OnboardingDraft.DraftKid(firstName: Self.firstName(s.name), powerSchoolStudentID: s.id, colorHex: draft.nextColor())
        }
        // nextColor() above counts existing kids; re-assign so siblings get distinct colors.
        let offset = draft.schools[..<i].flatMap(\.kids).count
        for k in draft.schools[i].kids.indices {
            draft.schools[i].kids[k].colorHex = Theme.kidColors[(offset + k) % Theme.kidColors.count]
        }
        showSignIn = false
        next()
    }

    /// "Chen, Maya L" → "Maya";  "Maya Chen" → "Maya"
    static func firstName(_ portalName: String) -> String {
        let n = portalName.contains(",") ? (portalName.split(separator: ",").last.map(String.init) ?? portalName) : portalName
        return n.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? portalName
    }
}

// MARK: 3 · Confirm kids

struct KidsStep: View {
    @Binding var draft: OnboardingDraft
    var addAnotherSchool: () -> Void
    var next: () -> Void
    @State private var manualName = ""

    var body: some View {
        let count = draft.allKids.count
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(count == 0 ? "Add your kids" : "We found \(count) kid\(count == 1 ? "" : "s")").font(.title.bold())
                Text("Pick a color for each. It labels their homework and events everywhere in the app.").foregroundStyle(.secondary)
                ForEach(draft.schools.flatMap(\.kids)) { kid in KidCard(kid: kid, draft: $draft) }
                HStack {
                    TextField("Add a kid by first name", text: $manualName).padding(12).background(.white, in: .rect(cornerRadius: 12))
                    Button("Add") {
                        let name = manualName.trimmingCharacters(in: .whitespaces); guard !name.isEmpty else { return }
                        draft.schools[draft.current].kids.append(.init(firstName: name, powerSchoolStudentID: nil, colorHex: draft.nextColor()))
                        manualName = ""
                    }
                }
                Button(action: addAnotherSchool) {
                    Label("Add a kid at another school or district", systemImage: "plus.circle")
                }
            }
        }
        PrimaryButton(count == 0 ? "Add at least one kid" : "Continue with \(count)", action: next).disabled(count == 0)
    }
}

private struct KidCard: View {
    let kid: OnboardingDraft.DraftKid
    @Binding var draft: OnboardingDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(Color(hex: kid.colorHex)).frame(width: 44, height: 44)
                    .overlay(Text(kid.firstName.prefix(1)).font(.headline).foregroundStyle(.white))
                TextField("Name", text: Binding(get: { kid.firstName }, set: { v in draft.updateKid(kid.id) { $0.firstName = v } }))
                    .font(.headline)
                Toggle("Include", isOn: Binding(get: { kid.include }, set: { v in draft.updateKid(kid.id) { $0.include = v } }))
                    .labelsHidden()
            }
            HStack(spacing: 10) {
                ForEach(Theme.kidColors, id: \.self) { hex in
                    Button { draft.updateKid(kid.id) { $0.colorHex = hex } } label: {
                        Circle().fill(Color(hex: hex)).frame(width: 32, height: 32)
                            .overlay(Circle().stroke(.primary, lineWidth: kid.colorHex == hex ? 3 : 0))
                    }.accessibilityLabel(hex == kid.colorHex ? "Selected color" : "Color")
                }
            }
        }
        .padding(14).background(.white, in: .rect(cornerRadius: 18))
    }
}

// MARK: 4 · Google Classroom per kid

struct ClassroomStep: View {
    @Binding var draft: OnboardingDraft
    var next: () -> Void
    @State private var busy: UUID?
    @State private var auth = GoogleAuth()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Add Google Classroom for homework").font(.title.bold())
                Text("Sign in with each kid's **school** Google account — the one they use on their school Chromebook. Keep your child nearby in case it asks for a code.")
                    .foregroundStyle(.secondary)
                ForEach(draft.allKids) { kid in row(kid) }
                Text("Read-only: classes, assignments and grades. We can't post, submit or change anything.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        PrimaryButton("Continue", action: next)
    }

    @ViewBuilder func row(_ kid: OnboardingDraft.DraftKid) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(Color(hex: kid.colorHex)).frame(width: 40, height: 40)
                    .overlay(Text(kid.firstName.prefix(1)).foregroundStyle(.white).bold())
                VStack(alignment: .leading) {
                    Text(kid.firstName).font(.headline)
                    Text(status(kid)).font(.footnote).foregroundStyle(kid.googleStatus == .blockedBySchool ? Theme.attention : .secondary)
                }
                Spacer()
                if kid.googleStatus == .linked { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
            }
            if kid.googleStatus == .blockedBySchool {
                Text("Schools must approve apps for students under 18. Grades and attendance from PowerSchool still work.")
                    .font(.footnote)
            }
            if kid.googleStatus != .linked {
                HStack {
                    Button(busy == kid.id ? "Opening Google…" : "Sign in with \(kid.firstName)'s school account") { Task { await link(kid) } }
                        .buttonStyle(.borderedProminent).disabled(busy != nil)
                    Button("Skip") { draft.updateKid(kid.id) { $0.googleStatus = .skipped } }
                }
            }
        }
        .padding(14).background(.white, in: .rect(cornerRadius: 18))
    }

    func status(_ k: OnboardingDraft.DraftKid) -> String {
        switch k.googleStatus {
        case .linked: k.googleTokens?.email ?? "Connected"
        case .blockedBySchool: "School hasn't approved this app yet"
        case .skipped: "Skipped — you can add it later in Settings"
        default: "Not connected"
        }
    }

    func link(_ kid: OnboardingDraft.DraftKid) async {
        busy = kid.id; defer { busy = nil }
        do {
            let t = try await auth.signIn(emailHint: kid.googleEmail)
            draft.updateKid(kid.id) { $0.googleTokens = t; $0.googleStatus = .linked }
        } catch GoogleAuth.AuthError.blockedBySchool {
            draft.updateKid(kid.id) { $0.googleStatus = .blockedBySchool }
        } catch {}
    }
}

// MARK: 5 · School calendar

struct CalendarStep: View {
    @Binding var draft: OnboardingDraft
    var next: () -> Void
    @State private var found: [UUID: [CalendarFeed.Found]] = [:]
    @State private var selected: [UUID: Set<URL>] = [:]
    @State private var errors: [UUID: String] = [:]
    @State private var searching: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Days off, picture day & events").font(.title.bold())
                Text("Paste the calendar page from your school or district website. The app finds the calendars on it. You can change these later in Settings › School calendars.")
                    .foregroundStyle(.secondary)
                ForEach(draft.allKids) { kid in kidCard(kid) }
            }
        }
        // Pre-filled district page (Millburn by default) — discover its calendars automatically
        // so parents see them ready without typing or tapping anything.
        .task {
            for kid in draft.allKids where !kid.calendarURL.isEmpty && found[kid.id] == nil {
                await search(kid)
            }
        }
        PrimaryButton("Continue") {
            for kid in draft.allKids {
                let urls = (found[kid.id] ?? []).map(\.feedURL).filter { (selected[kid.id] ?? []).contains($0) }
                if !urls.isEmpty { draft.updateKid(kid.id) { $0.calendarFeeds = urls } }
            }
            next()
        }
    }

    @ViewBuilder private func kidCard(_ kid: OnboardingDraft.DraftKid) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(kid.firstName)'s school").font(.headline)
            TextField("School or district calendar page", text: Binding(
                get: { kid.calendarURL }, set: { v in draft.updateKid(kid.id) { $0.calendarURL = v } }))
                .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                .padding(12).background(Theme.bg, in: .rect(cornerRadius: 10))
            HStack {
                Button(searching == kid.id ? "Looking…" : "Find calendars") { Task { await search(kid) } }
                    .disabled(kid.calendarURL.isEmpty || searching != nil)
                if let other = draft.allKids.first(where: { $0.id != kid.id && !(found[$0.id] ?? []).isEmpty }), (found[kid.id] ?? []).isEmpty {
                    Button("Same as \(other.firstName)") {
                        draft.updateKid(kid.id) { $0.calendarURL = other.calendarURL }
                        found[kid.id] = found[other.id]; selected[kid.id] = selected[other.id]
                    }
                }
            }
            if let e = errors[kid.id] { Text(e).font(.footnote).foregroundStyle(Theme.attention) }
            if let f = found[kid.id], !f.isEmpty {
                Text("Pick the calendars for \(kid.firstName):").font(.footnote.bold())
                FoundCalendarsList(found: f, selected: Binding(
                    get: { selected[kid.id] ?? [] }, set: { selected[kid.id] = $0 }))
            }
        }
        .padding(14).background(.white, in: .rect(cornerRadius: 18))
    }

    private func search(_ kid: OnboardingDraft.DraftKid) async {
        searching = kid.id; errors[kid.id] = nil
        defer { searching = nil }
        do {
            let f = try await CalendarFeed.discover(kid.calendarURL)
            found[kid.id] = f
            selected[kid.id] = f.count == 1 ? [f[0].feedURL] : []
        } catch {
            errors[kid.id] = error.localizedDescription
        }
    }
}

// MARK: 5b · PTO

/// Optional: connect the parent's PTO (Membership Toolkit) for its calendar + newsletter
/// summaries. Reuses the same connect flow as Settings; the site field is pre-filled with the
/// launch district's PTO so most Millburn parents just tap Connect and sign in.
struct PTOStep: View {
    var next: () -> Void
    @Query private var ptoAccounts: [PTOAccount]
    @State private var showConnect = false

    private var connected: Bool { ptoAccounts.first?.isConnected == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your PTO's news & calendar").font(.title.bold())
            Text("Add your PTO's Membership Toolkit site to get its events on your calendar and short, on-device summaries of its newsletters. You sign in on the PTO's own site — your password never touches this app.")
                .foregroundStyle(.secondary)

            if connected {
                Label("PTO connected", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(Color(hex: "2E7D4F"))
                Button("Change PTO or grades") { showConnect = true }.font(.subheadline.weight(.semibold))
            } else {
                Button { showConnect = true } label: {
                    Label("Connect your PTO", systemImage: "newspaper")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Text("Don't have your PTO's web address handy? You can add it anytime in Settings.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Spacer()
            PrimaryButton(connected ? "Continue" : "Skip for now", action: next)
        }
        .sheet(isPresented: $showConnect) { PTOConnectView() }
    }
}

// MARK: 6 · Alerts & lock

struct FinishStep: View {
    var finish: (AppSettings) -> Void
    @State private var s = AppSettings()
    var body: some View {
        Form {
            Section("Tell me when") {
                Toggle("Missing assignments", isOn: $s.notifyMissing)
                Toggle("A class grade drops", isOn: $s.notifyGradeDrop)
                Toggle("Absent or tardy", isOn: $s.notifyAttendance)
                Toggle("Days off & early dismissals", isOn: $s.notifyDaysOff)
                Toggle("\"Due tomorrow\" at 7 PM", isOn: $s.eveningDigest)
            }
            Section { Toggle("Lock with Face ID", isOn: $s.faceIDLock) }
                footer: { Text("Keeps grades private if kids borrow your phone.") }
        }
        .scrollContentBackground(.hidden)
        PrimaryButton("Allow notifications & finish") { finish(s) }
    }
}

struct PrimaryButton: View {
    let title: String; let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity).frame(height: 54)
        }
        .buttonStyle(.borderedProminent).tint(Theme.accent).clipShape(.rect(cornerRadius: 16))
    }
}
