import SwiftUI
import SwiftData

// Settings › Kids and Settings › PowerSchool accounts.
// Everything set up during onboarding can be added, edited or removed here.

// MARK: - Kids list

struct KidsSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Child.sortOrder) private var children: [Child]
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                ForEach(children) { kid in
                    NavigationLink { KidEditView(kid: kid) } label: { KidLabel(kid: kid) }
                }
                .onMove(perform: move)
                .onDelete(perform: delete)
            } footer: {
                Text("Drag to reorder. Swipe left to remove a kid and all of their data from this iPhone.")
            }
            Section("Add a kid") {
                HStack {
                    TextField("First name", text: $newName).textInputAutocapitalization(.words)
                    Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("To bring in kids from PowerSchool automatically, use PowerSchool accounts › Add another district or Find kids.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Kids")
        .toolbar { EditButton() }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let kid = Child(firstName: name, colorHex: Theme.kidColors[children.count % Theme.kidColors.count],
                        sortOrder: (children.map(\.sortOrder).max() ?? -1) + 1)
        context.insert(kid)
        try? context.save()
        newName = ""
    }

    private func move(_ from: IndexSet, _ to: Int) {
        var list = children
        list.move(fromOffsets: from, toOffset: to)
        for (i, k) in list.enumerated() { k.sortOrder = i }
        try? context.save()
    }

    private func delete(_ offsets: IndexSet) {
        for i in offsets { KidEditView.remove(children[i], context: context) }
    }
}

struct KidLabel: View {
    let kid: Child
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(Color(hex: kid.colorHex)).frame(width: 36, height: 36)
                .overlay(Text(kid.firstName.prefix(1)).bold().foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(kid.firstName).font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var summary: String {
        var parts: [String] = []
        if let g = kid.gradeLevel, !g.isEmpty { parts.append("Grade \(g)") }
        parts.append(kid.powerSchoolAccount == nil ? "No PowerSchool" : "PowerSchool")
        if FeatureFlags.classroomEnabled, kid.googleStatus == .linked { parts.append("Classroom") }
        if !kid.allCalendarFeeds.isEmpty { parts.append("Calendar") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Edit one kid

struct KidEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [PowerSchoolAccount]
    @Bindable var kid: Child

    @State private var gradeText = ""
    @State private var schoolText = ""
    @State private var googleBusy = false
    @State private var googleMessage: String?
    @State private var confirmRemove = false
    @State private var auth = GoogleAuth()

    var body: some View {
        Form {
            Section("Name & color") {
                TextField("First name", text: $kid.firstName).textInputAutocapitalization(.words)
                HStack(spacing: 12) {
                    ForEach(Theme.kidColors, id: \.self) { hex in
                        Button { kid.colorHex = hex } label: {
                            Circle().fill(Color(hex: hex)).frame(width: 32, height: 32)
                                .overlay(Circle().stroke(Color.primary, lineWidth: kid.colorHex == hex ? 3 : 0))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(kid.colorHex == hex ? "Selected color" : "Color")
                    }
                }
            }

            Section("School") {
                TextField("Grade (e.g. 7)", text: $gradeText).keyboardType(.numbersAndPunctuation)
                TextField("School name", text: $schoolText)
            }

            Section {
                Picker("PowerSchool account", selection: accountBinding) {
                    Text("None").tag(PersistentIdentifier?.none)
                    ForEach(accounts) { a in Text(a.displayName).tag(Optional(a.persistentModelID)) }
                }
                if kid.powerSchoolAccount != nil {
                    LabeledContent("Student ID", value: kid.powerSchoolStudentID ?? "Not matched")
                }
            } header: { Text("PowerSchool") } footer: {
                Text("To match this kid to a student on the account, open PowerSchool accounts › the account › Find kids.")
            }

            if FeatureFlags.classroomEnabled {
                Section("Google Classroom Web") {
                    NavigationLink("Classroom Sync") { ClassroomImportView(kid: kid) }
                }
            }

            if FeatureFlags.classroomEnabled, kid.googleStatus == .linked {
              Section {
                switch kid.googleStatus {
                case .linked:
                    LabeledContent("Connected as", value: kid.googleEmail ?? "Google account")
                    Button("Disconnect Google Classroom", role: .destructive, action: disconnectGoogle)
                case .blockedBySchool:
                    Text("The school hasn't approved this app for student accounts yet. Ask the school's tech office to allow it, then try again.")
                        .font(.footnote)
                    connectButton(title: "Try again")
                case .expired:
                    Text("Sign-in expired.").font(.footnote).foregroundStyle(Theme.attention)
                    connectButton(title: "Sign in again")
                case .notLinked, .skipped:
                    connectButton(title: "Connect \(kid.firstName)'s school Google account")
                }
                if let googleMessage { Text(googleMessage).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("Google Classroom") } footer: {
                Text("Use the kid's school account, the one they use on their school Chromebook. Read-only.")
            }
            }

            Section {
                NavigationLink { CalendarLinkEditor(kid: kid) } label: {
                    LabeledContent("Calendars", value: kid.calendarSummary)
                }
            } header: { Text("School calendar") }

            Section {
                Button("Remove \(kid.firstName) from this iPhone", role: .destructive) { confirmRemove = true }
            }
        }
        .navigationTitle(kid.firstName.isEmpty ? "Kid" : kid.firstName)
        .onAppear {
            gradeText = kid.gradeLevel ?? ""
            schoolText = kid.schoolName ?? ""
        }
        .onDisappear(perform: save)
        .confirmationDialog("Remove \(kid.firstName)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Self.remove(kid, context: context)
                dismiss()
            }
        } message: {
            Text("Deletes their grades, homework and attendance from this iPhone. Nothing changes at school.")
        }
    }

    private var accountBinding: Binding<PersistentIdentifier?> {
        Binding(
            get: { kid.powerSchoolAccount?.persistentModelID },
            set: { id in
                kid.powerSchoolAccount = accounts.first { $0.persistentModelID == id }
                if id == nil { kid.powerSchoolStudentID = nil }
            })
    }

    private func connectButton(title: String) -> some View {
        Button(googleBusy ? "Opening Google…" : title) { Task { await connectGoogle() } }
            .disabled(googleBusy)
    }

    private func connectGoogle() async {
        googleBusy = true
        defer { googleBusy = false }
        do {
            let tokens = try await auth.signIn(emailHint: kid.googleEmail)
            let key = kid.googleKeychainKey ?? "g.\(kid.id.uuidString)"
            try Keychain.set(tokens, for: key)
            kid.googleKeychainKey = key
            kid.googleEmail = tokens.email ?? kid.googleEmail
            kid.googleStatus = .linked
            googleMessage = "Connected. Homework will appear after the next refresh."
            try? context.save()
        } catch GoogleAuth.AuthError.blockedBySchool {
            kid.googleStatus = .blockedBySchool
        } catch GoogleAuth.AuthError.cancelled {
            // nothing to do
        } catch {
            googleMessage = error.localizedDescription
        }
    }

    private func disconnectGoogle() {
        if let key = kid.googleKeychainKey { Keychain.delete(key) }
        kid.googleKeychainKey = nil
        kid.googleStatus = .notLinked
        for a in kid.assignments where a.source == .classroom { context.delete(a) }
        try? context.save()
    }

    private func save() {
        let g = gradeText.trimmingCharacters(in: .whitespaces)
        let s = schoolText.trimmingCharacters(in: .whitespaces)
        kid.gradeLevel = g.isEmpty ? nil : g
        kid.schoolName = s.isEmpty ? nil : s
        kid.firstName = kid.firstName.trimmingCharacters(in: .whitespaces)
        try? context.save()
    }

    static func remove(_ kid: Child, context: ModelContext) {
        if let key = kid.googleKeychainKey { Keychain.delete(key) }
        let id = kid.id
        if let events = try? context.fetch(FetchDescriptor<SchoolEvent>()) {
            for e in events where e.childIDs.contains(id) {
                e.childIDs.removeAll { $0 == id }
                if e.childIDs.isEmpty { context.delete(e) }
            }
        }
        context.delete(kid)   // cascades to courses, assignments, attendance, grade history
        try? context.save()
    }
}

// MARK: - PowerSchool accounts

struct AccountsSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var accounts: [PowerSchoolAccount]
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(accounts) { a in
                    NavigationLink { AccountEditView(account: a) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.displayName).font(.headline)
                            Text(status(a)).font(.caption)
                                .foregroundStyle(a.lastError == nil ? Color.secondary : Theme.attention)
                        }
                    }
                }
            } footer: {
                if accounts.isEmpty { Text("No PowerSchool accounts yet.") }
            }
            Section {
                Button { adding = true } label: { Label("Add another district", systemImage: "plus.circle") }
            } footer: {
                Text("Use this when a kid goes to school in a different district, or is on a different parent login.")
            }
        }
        .navigationTitle("PowerSchool accounts")
        .sheet(isPresented: $adding) { AddAccountSheet() }
    }

    private func status(_ a: PowerSchoolAccount) -> String {
        let kids = a.children.map(\.firstName).joined(separator: ", ")
        let state = a.lastError ?? a.lastSync.map { "Updated \($0.formatted(.relative(presentation: .named)))" } ?? "Not refreshed yet"
        return kids.isEmpty ? state : "\(kids) · \(state)"
    }
}

struct AccountEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Child.sortOrder) private var children: [Child]
    @Bindable var account: PowerSchoolAccount
    var initialFound: [PortalStudent] = []

    @State private var addressText = ""
    @State private var signingIn = false
    @State private var found: [PortalStudent] = []
    @State private var message: String?
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section("Account") {
                TextField("Name", text: $account.displayName)
                TextField("yourdistrict.powerschool.com", text: $addressText)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                LabeledContent("Sign-in type", value: account.usesSSO ? "Google / Clever / district sign-in" : "Username & password")
                if let e = account.lastError { Text(e).font(.footnote).foregroundStyle(Theme.attention) }
            }

            Section {
                Button(account.lastError == nil ? "Sign in again / find kids" : "Reconnect") { signingIn = true }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("Opens your district's own sign-in page. Use your parent login. The saved login on this iPhone is replaced.")
            }

            if !found.isEmpty {
                Section("Students on this account") {
                    ForEach(found, id: \.id) { s in StudentMatchRow(student: s, account: account, children: children) }
                }
            }

            Section {
                Button("Remove this account", role: .destructive) { confirmRemove = true }
            }
        }
        .navigationTitle(account.displayName)
        .onAppear {
            addressText = account.baseURL.host ?? account.baseURL.absoluteString
            if found.isEmpty { found = initialFound }
        }
        .onDisappear(perform: saveAddress)
        .sheet(isPresented: $signingIn) {
            NavigationStack {
                PowerSchoolSignInView(baseURL: account.baseURL) { cred, html, sso in
                    try? Keychain.set(cred, for: account.keychainKey)
                    account.usesSSO = sso
                    account.lastError = nil
                    found = PortalParsers.students(homeHTML: html)
                    if found.isEmpty {
                        found = [PortalStudent(id: "current", name: PortalParsers.selectedStudentName(homeHTML: html) ?? "Student")]
                    }
                    message = "Signed in. \(found.count) student\(found.count == 1 ? "" : "s") found."
                    try? context.save()
                    signingIn = false
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(account.baseURL.host ?? "PowerSchool").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Cancel") { signingIn = false } }
            }
        }
        .confirmationDialog("Remove \(account.displayName)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Keychain.delete(account.keychainKey)
                for k in account.children {
                    k.powerSchoolAccount = nil
                    k.powerSchoolStudentID = nil
                    for c in k.courses where c.source == .powerSchool { context.delete(c) }
                }
                context.delete(account)
                try? context.save()
                dismiss()
            }
        } message: {
            Text("Kids stay in the app; their PowerSchool grades and attendance are removed from this iPhone.")
        }
    }

    private func saveAddress() {
        if let url = SchoolStep.normalize(addressText), url != account.baseURL {
            account.baseURL = url
            account.lastError = "Address changed — sign in again"
        }
        try? context.save()
    }
}

/// One student found on a PowerSchool account: link it to an existing kid or add a new kid.
struct StudentMatchRow: View {
    @Environment(\.modelContext) private var context
    let student: PortalStudent
    let account: PowerSchoolAccount
    let children: [Child]

    private var linked: Child? {
        children.first { $0.powerSchoolAccount?.persistentModelID == account.persistentModelID && $0.powerSchoolStudentID == student.id }
    }

    var body: some View {
        if let linked {
            LabeledContent(student.name, value: "Linked to \(linked.firstName)")
        } else {
            Menu {
                ForEach(children) { kid in
                    Button("Link to \(kid.firstName)") { link(kid) }
                }
                Button("Add as a new kid") { addNew() }
            } label: {
                LabeledContent(student.name, value: "Choose…")
            }
        }
    }

    private func link(_ kid: Child) {
        kid.powerSchoolAccount = account
        kid.powerSchoolStudentID = student.id
        try? context.save()
    }

    private func addNew() {
        let kid = Child(firstName: PowerSchoolStep.firstName(student.name),
                        colorHex: Theme.kidColors[children.count % Theme.kidColors.count],
                        sortOrder: (children.map(\.sortOrder).max() ?? -1) + 1)
        kid.powerSchoolAccount = account
        kid.powerSchoolStudentID = student.id
        context.insert(kid)
        try? context.save()
    }
}

/// Add a PowerSchool account for another district: address → sign in → match students.
struct AddAccountSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var addressText = ""
    @State private var url: URL?
    @State private var error: String?
    @State private var created: PowerSchoolAccount?
    @State private var foundStudents: [PortalStudent] = []

    var body: some View {
        NavigationStack {
            Group {
                if let created {
                    AccountEditView(account: created, initialFound: foundStudents)
                } else if let url {
                    PowerSchoolSignInView(baseURL: url) { cred, html, sso in
                        var students = PortalParsers.students(homeHTML: html)
                        if students.isEmpty {
                            students = [PortalStudent(id: "current", name: PortalParsers.selectedStudentName(homeHTML: html) ?? "Student")]
                        }
                        foundStudents = students
                        let a = PowerSchoolAccount(baseURL: url, displayName: url.host ?? "PowerSchool", usesSSO: sso)
                        try? Keychain.set(cred, for: a.keychainKey)
                        context.insert(a)
                        try? context.save()
                        created = a
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    Form {
                        Section {
                            TextField("yourdistrict.powerschool.com", text: $addressText)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            if let error { Text(error).font(.footnote).foregroundStyle(Theme.attention) }
                        } header: { Text("PowerSchool web address") } footer: {
                            Text("The address you see when you sign in to the parent portal in a web browser.")
                        }
                        Button("Continue to sign-in") {
                            if let u = SchoolStep.normalize(addressText) { url = u } else { error = "That doesn't look like a web address." }
                        }
                    }
                }
            }
            .navigationTitle(created == nil ? "Add district" : "Find kids")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(created == nil ? "Cancel" : "Done") { dismiss() } }
        }
    }
}
