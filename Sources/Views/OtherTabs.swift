import SwiftUI
import SwiftData
import Charts

// MARK: Homework

struct HomeworkView: View {
    enum Filter: String, CaseIterable { case upcoming = "Upcoming", offtrack = "Off-track", done = "Done" }
    let child: Child
    @State var filter: Filter
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var classroomSync: ClassroomSync
    init(child: Child, initialFilter: Filter = .upcoming) { self.child = child; _filter = State(initialValue: initialFilter) }

    var body: some View {
        // One tap: jump straight to Classroom in Safari; the extension scrapes and bounces
        // back. The detailed setup/troubleshooting screen still lives in Settings.
        if FeatureFlags.classroomEnabled {
            Button {
                openURL(classroomSync.begin(for: child))
            } label: {
                Label(classroomSync.syncing ? "Syncing… finish in Safari, then return" : "Sync Classroom homework",
                      systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(classroomSync.syncing)
            if let message = classroomSync.lastMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            NavigationLink {
                ClassroomImportView(kid: child)
            } label: {
                Label("First time? Set up Classroom", systemImage: "questionmark.circle")
                    .font(.footnote)
            }
        }

        WorkTrackCard(child: child)
        TurnedInWeeklyCard(child: child)

        Picker("Filter", selection: $filter) {
            ForEach(Filter.allCases, id: \.self) { f in Text(label(f)).tag(f) }
        }
        .pickerStyle(.segmented)

        if filter == .offtrack {
            Text("This is the work behind your On-time score: past-due assignments PowerSchool marked missing or late. Submitted work that's just waiting to be graded isn't counted either way.")
                .font(.footnote).foregroundStyle(.secondary)
        }

        Card {
            let list = items
            if list.isEmpty {
                Text(filter == .offtrack ? "Nothing missing or late. Everything past due is turned in."
                                         : "Nothing here.").foregroundStyle(.secondary)
            }
            ForEach(list, id: \.key) { a in
                if let link = a.link { Link(destination: link) { AssignmentRow(a: a, color: Color(hex: child.colorHex)) }.foregroundStyle(.primary) }
                else { AssignmentRow(a: a, color: Color(hex: child.colorHex)) }
            }
        }
    }

    private func label(_ f: Filter) -> String {
        switch f {
        case .upcoming: "Upcoming · \(child.upcoming.count)"
        case .offtrack: "Off-track · \(child.offTrack.count)"
        case .done: "Done"
        }
    }

    private var items: [Assignment] {
        switch filter {
        case .upcoming: child.upcoming
        case .offtrack: child.offTrack
        case .done: child.assignments.filter(\.isTurnedIn).sorted { ($0.dueDate ?? .distantPast) > ($1.dueDate ?? .distantPast) }.prefix(30).map { $0 }
        }
    }

}

// MARK: Attendance

struct AttendanceView: View {
    let child: Child
    var body: some View {
        let absences = child.psCourses.map(\.absences).max() ?? 0   // per-class counts; the max approximates full days
        let tardies = child.psCourses.map(\.tardies).reduce(0, +)
        let schoolDays = max(1, Int(Date.now.timeIntervalSince(SchoolYear.start) / 86_400 * 5 / 7 * 0.93))
        let chronicLine = max(1, Int((Double(schoolDays) * 0.10).rounded()))

        HStack(spacing: 10) {
            stat("\(max(0, 100 - absences * 100 / schoolDays))%", "Present")
            stat("\(absences)", "Absences")
            stat("\(tardies)", "Tardies", warn: tardies > 0)
        }

        Card(title: "Days missed vs. chronic-absence line") {
            MissedVsChronicBar(missed: absences, chronic: chronicLine)
            Text("Missing 10% of school days is the threshold schools commonly flag.\(absences < chronicLine ? " \(child.firstName) is well under it." : "")")
                .font(.footnote).foregroundStyle(.secondary)
        }

        AttendanceMonth(child: child)

        Card(title: "Recent records") {
            let recs = child.attendance.sorted { $0.date > $1.date }
            if recs.isEmpty { Text("No absences or tardies recorded yet.").foregroundStyle(.secondary) }
            ForEach(recs.prefix(20), id: \.key) { r in
                HStack {
                    VStack(alignment: .leading) {
                        Text(title(r.kind) + (r.period.map { " · Period \($0)" } ?? "")).font(.subheadline.bold())
                        Text(r.date.formatted(date: .complete, time: .omitted)).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(r.code).font(.caption.bold()).padding(6).background(Theme.attentionBG, in: .rect(cornerRadius: 6))
                }
            }
        }
    }

    private func stat(_ v: String, _ l: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading) { Text(v).font(.title.bold()); Text(l).font(.footnote.weight(.semibold)) }
            .foregroundStyle(warn ? Theme.attention : .primary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(warn ? Theme.attentionBG : .white, in: .rect(cornerRadius: 18))
    }

    private func title(_ k: AttendanceKind) -> String {
        switch k { case .tardy: "Tardy"; case .absentExcused: "Excused absence"; case .absentUnexcused: "Unexcused absence"; default: "Attendance" }
    }
}

// MARK: Calendar

struct SchoolCalendarView: View {
    enum Source { case school, pto }
    @Query(sort: \SchoolEvent.start) private var events: [SchoolEvent]
    @Query(sort: \Child.sortOrder) private var children: [Child]
    @State private var kind: EventKind?
    @State private var source: Source?

    var body: some View {
        let hasPTO = events.contains { $0.isPTO }
        let upcoming = events.filter {
            $0.start >= Calendar.current.startOfDay(for: .now)
            && (kind == nil || $0.kind == kind)
            && (source == nil || (source == .pto ? $0.isPTO : !$0.isPTO))
        }
        VStack(alignment: .leading, spacing: 16) {
            if let off = events.first(where: { $0.kind == .noSchool && $0.start > .now }) {
                let days = Calendar.current.dateComponents([.day], from: .now, to: off.start).day ?? 0
                Card(tint: Theme.attentionBG) {
                    Text("Next day off in \(days) day\(days == 1 ? "" : "s")").font(.footnote).foregroundStyle(Theme.attention.opacity(0.75))
                    Text("\(off.title) · \(off.start.formatted(.dateTime.weekday().month().day()))").font(.headline).foregroundStyle(Theme.attention)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    chip("All", nil); chip("No school", .noSchool); chip("Early", .earlyDismissal)
                    chip("Tests", .test); chip("Events", .event); chip("Deadlines", .deadline)
                }
            }
            if hasPTO {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        sourceChip("All sources", nil)
                        sourceChip("School", .school)
                        sourceChip("PTO", .pto)
                    }
                }
            }
            Card {
                if upcoming.isEmpty {
                    Text(events.isEmpty ? "No upcoming events. Add your school's calendar in Settings."
                                        : "No events match this filter.").foregroundStyle(.secondary)
                }
                ForEach(upcoming.prefix(60)) { e in
                    CalendarEventRow(e: e, kids: kids(e))
                }
            }
        }
    }

    private func kids(_ e: SchoolEvent) -> String { children.filter { e.childIDs.contains($0.id) }.map(\.firstName).joined(separator: ", ") }

    private func chip(_ t: String, _ k: EventKind?) -> some View {
        Button(t) { kind = k }
            .font(.footnote.bold()).padding(.horizontal, 14).frame(height: 36)
            .background(kind == k ? Color(hex: "121722") : .white, in: Capsule())
            .foregroundStyle(kind == k ? .white : .primary)
    }

    private func sourceChip(_ t: String, _ s: Source?) -> some View {
        let on = source == s
        return Button(t) { source = s }
            .font(.footnote.bold()).padding(.horizontal, 14).frame(height: 36)
            .background(on ? Theme.accent : .white, in: Capsule())
            .foregroundStyle(on ? .white : .primary)
            .overlay(Capsule().stroke(Theme.accent.opacity(on ? 0 : 0.35), lineWidth: 1))
    }
}

/// Calendar row: date box, title/time, and a right column with the PTO tag stacked **above** the
/// kid name. The tag's space is always reserved so the kid name sits in the same spot on every row,
/// with or without a tag.
struct CalendarEventRow: View {
    let e: SchoolEvent
    let kids: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Text(e.start.formatted(.dateTime.month(.abbreviated))).font(.caption2.bold()).textCase(.uppercase)
                    .foregroundStyle(e.kind == .noSchool ? Theme.attention : Theme.accent)
                Text(e.start.formatted(.dateTime.day())).font(.title3.bold())
            }
            .frame(width: 48, height: 52)
            .background(e.kind == .noSchool ? Theme.attentionBG : Theme.accent.opacity(0.1), in: .rect(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(e.title).font(.subheadline.bold())
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Text(e.allDay ? e.start.formatted(.dateTime.weekday(.wide))
                              : e.start.formatted(.dateTime.weekday().hour().minute()))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 4) {
                Text("PTO").font(.caption2.bold()).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                    .opacity(e.isPTO ? 1 : 0)        // keep the slot so the kid name stays put
                if !kids.isEmpty {
                    Text(kids).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: Settings

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var accounts: [PowerSchoolAccount]
    @Query private var ptoAccounts: [PTOAccount]
    @Query(sort: \Child.sortOrder) private var children: [Child]
    @State private var s = AppSettings.load()
    @State private var confirmErase = false
    @State private var showPTOConnect = false
    @State private var districtEnabled = DistrictDefault.enabled
    @State private var districtName = DistrictDefault.name
    @State private var showDistrictEditor = false

    var body: some View {
        Form {
            Section("Your family") {
                NavigationLink { KidsSettingsView() } label: {
                    LabeledContent("Kids", value: children.map(\.firstName).joined(separator: ", "))
                }
                NavigationLink { AccountsSettingsView() } label: {
                    LabeledContent("PowerSchool accounts", value: "\(accounts.count)")
                }
                NavigationLink { CalendarSettingsView() } label: {
                    LabeledContent("School calendars", value: "\(children.filter { !$0.allCalendarFeeds.isEmpty }.count) of \(children.count) set")
                }
            }

            Section {
                Toggle(isOn: $districtEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(districtName)
                        Text("Added for every kid automatically").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Change district…") { showDistrictEditor = true }
            } header: { Text("District calendar") } footer: {
                Text("Your district's closures, early dismissals and events are included out of the box — no setup. Turn it off or switch districts here.")
            }
            Section {
                if let pto = ptoAccounts.first, pto.isConnected {
                    LabeledContent("PTO", value: pto.needsReconnect ? "Reconnect needed" : "Connected")
                    if !pto.gradeLabels.isEmpty {
                        LabeledContent("Newsletters", value: pto.gradeLabels.joined(separator: ", "))
                    }
                    Button(pto.needsReconnect ? "Reconnect PTO" : "Reconnect / change grades") { showPTOConnect = true }
                } else {
                    Button { showPTOConnect = true } label: {
                        Label("Connect your PTO (news & calendar)", systemImage: "newspaper")
                    }
                }
            } header: { Text("PTO (Membership Toolkit)") } footer: {
                Text("Sign in once to add your PTO's calendar and get on-device summaries of its newsletters. Your PTO password stays with the PTO site.")
            }

            if FeatureFlags.classroomEnabled {
                Section("Classroom Sync") {
                    ForEach(children) { child in
                        NavigationLink {
                            ClassroomImportView(kid: child)
                        } label: {
                            Label("Classroom Sync · \(child.firstName)", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                }
            }
            Section("Connection status") {
                ForEach(accounts) { a in
                    NavigationLink { AccountEditView(account: a) } label: {
                        LabeledContent("PowerSchool · \(a.displayName)",
                                       value: a.lastError ?? (a.lastSync.map { "OK \($0.formatted(date: .omitted, time: .shortened))" } ?? "Not yet"))
                    }
                }
            }
            Section {
                Picker("Morning check", selection: $s.morningHour) { ForEach(5...8, id: \.self) { Text("around \($0):00 AM").tag($0) } }
                Picker("After-school check", selection: $s.afterSchoolHour) {
                    Text("Off").tag(Int?.none); ForEach(14...18, id: \.self) { Text("around \($0 - 12):00 PM").tag(Int?.some($0)) }
                }
            } header: { Text("Automatic refresh") }
              footer: { Text("iPhone decides the exact moment based on battery and usage. The app also refreshes whenever you open it.") }
            Section("Notify me when") {
                Toggle("An assignment goes missing", isOn: $s.notifyMissing)
                Toggle("A grade falls below \(Int(s.gradeDropFloor))%", isOn: $s.notifyGradeDrop)
                Toggle("Absent or tardy", isOn: $s.notifyAttendance)
                Toggle("New test or quiz score", isOn: $s.notifyNewScores)
                Toggle("No-school days", isOn: $s.notifyDaysOff)
                Toggle("Evening \"due tomorrow\" digest", isOn: $s.eveningDigest)
            }
            Section { Toggle("Lock with Face ID", isOn: $s.faceIDLock) }
            #if DEBUG
            Section("Developer") {
                ForEach(accounts) { a in PortalCaptureButton(account: a) }
            }
            #endif
            Section {
                Button("Erase all data & sign-ins from this iPhone", role: .destructive) { confirmErase = true }
            }
        }
        .navigationTitle("Sync & alerts")
        .onChange(of: s.morningHour) { save() }
        .onChange(of: s.afterSchoolHour) { save() }
        .onDisappear { save() }
        .confirmationDialog("Erase everything?", isPresented: $confirmErase) {
            Button("Erase", role: .destructive) { try? Persistence.eraseEverything(context) }
        }
        .sheet(isPresented: $showPTOConnect) { PTOConnectView() }
        .sheet(isPresented: $showDistrictEditor) {
            DistrictEditorView { districtName = DistrictDefault.name; districtEnabled = DistrictDefault.enabled; applyDistrictChange() }
        }
        .onChange(of: districtEnabled) { _, on in DistrictDefault.enabled = on; applyDistrictChange() }
    }

    private func save() { s.save(); BackgroundRefresh.schedule(settings: s) }

    /// Clear any district-sourced events, then re-sync so the active district (if any) repopulates.
    private func applyDistrictChange() {
        let events = (try? context.fetch(FetchDescriptor<SchoolEvent>())) ?? []
        for e in events where e.key.contains("generate_ical") { context.delete(e) }
        try? context.save()
        let ctx = context
        Task { await SyncEngine(context: ctx).refreshCalendarsOnly() }
    }

}

/// Clean horizontal "days missed vs. chronic line" meter. Robust at 0 (unlike a bar chart).
struct MissedVsChronicBar: View {
    let missed: Int
    let chronic: Int

    var body: some View {
        // Put the chronic marker near the right edge; clamp the fill to the track.
        let scaleMax = Double(max(chronic + 1, missed + 1)) * 1.1
        let overLine = missed >= chronic
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                let fill = min(1, Double(missed) / scaleMax) * w
                let mark = min(1, Double(chronic) / scaleMax) * w
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(hex: "EEF1F5")).frame(height: 14)
                    Capsule().fill(overLine ? Theme.attention : Theme.accent).frame(width: max(missed == 0 ? 0 : 8, fill), height: 14)
                    Rectangle().fill(Theme.attention).frame(width: 2, height: 30).offset(x: mark - 1)
                }
                .frame(height: 30)
            }
            .frame(height: 30)
            HStack {
                Text("\(missed) day\(missed == 1 ? "" : "s") missed").font(.caption.bold())
                Spacer()
                Text("≈\(chronic) days = chronic").font(.caption.bold()).foregroundStyle(Theme.attention)
            }
        }
    }
}

/// Month view of attendance. Weekdays only, one cell per school day, colored by record.
struct AttendanceMonth: View {
    let child: Child
    @State private var monthOffset = 0

    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; return c }

    var body: some View {
        let month = cal.date(byAdding: .month, value: monthOffset, to: cal.startOfDay(for: .now)) ?? .now
        Card {
            HStack {
                Button { monthOffset -= 1 } label: { Image(systemName: "chevron.left") }
                    .frame(width: 44, height: 44).accessibilityLabel("Previous month")
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                Spacer()
                Button { if monthOffset < 0 { monthOffset += 1 } } label: { Image(systemName: "chevron.right") }
                    .frame(width: 44, height: 44).disabled(monthOffset >= 0).accessibilityLabel("Next month")
            }
            HStack(spacing: 8) {
                ForEach(["Mon", "Tue", "Wed", "Thu", "Fri"], id: \.self) { d in
                    Text(d).font(.caption2.bold()).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(Array(weekdayCells(of: month).enumerated()), id: \.offset) { _, date in cell(date) }
            }
            legend
        }
    }

    @ViewBuilder private func cell(_ date: Date?) -> some View {
        if let date {
            let info = status(on: date)
            VStack(spacing: 1) {
                Text(date.formatted(.dateTime.day())).font(.subheadline.weight(.semibold))
                if let tag = info.tag { Text(tag).font(.system(size: 9, weight: .bold)) }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(info.fg)
            .background(info.bg, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(info.border, lineWidth: info.border == .clear ? 0 : 2))
        } else {
            Color.clear.frame(minHeight: 44)
        }
    }

    private struct Status { var bg: Color; var fg: Color; var border: Color = .clear; var tag: String? }

    private func status(on date: Date) -> Status {
        let recs = child.attendance.filter { cal.isDate($0.date, inSameDayAs: date) }
        if recs.contains(where: { $0.kind == .absentUnexcused }) {
            return Status(bg: Color(hex: "B4530F"), fg: .white, tag: "ABS")
        }
        if recs.contains(where: { $0.kind == .absentExcused }) {
            return Status(bg: Color(hex: "FCE3CE"), fg: Color(hex: "8A3D08"), tag: "EXC")
        }
        if recs.contains(where: { $0.kind == .tardy }) {
            return Status(bg: .white, fg: Color(hex: "8A3D08"), border: Color(hex: "E07A1F"), tag: "TARDY")
        }
        let today = cal.startOfDay(for: .now)
        if date >= SchoolYear.start && date <= today {
            return Status(bg: Color(hex: "E8EEFD"), fg: Color(hex: "1E44B8"))   // present
        }
        return Status(bg: Color(hex: "F4F6FA"), fg: Color(hex: "AEB6C4"))       // future / out of term
    }

    private var legend: some View {
        HStack(spacing: 12) {
            swatch(Color(hex: "E8EEFD"), "Present")
            swatch(Color(hex: "FCE3CE"), "Excused")
            swatch(Color(hex: "B4530F"), "Unexcused")
        }
        .font(.caption2).foregroundStyle(.secondary)
    }
    private func swatch(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 4).fill(c).frame(width: 12, height: 12); Text(t) }
    }

    /// Mon–Fri cells for the month, with leading blanks so the 1st lands under the right weekday.
    private func weekdayCells(of month: Date) -> [Date?] {
        guard let range = cal.range(of: .day, in: .month, for: month),
              let first = cal.date(from: cal.dateComponents([.year, .month], from: month)) else { return [] }
        var cells: [Date?] = []
        let firstWeekday = cal.component(.weekday, from: first)   // 1=Sun..7=Sat
        // Column index Mon..Fri = 0..4; map weekday to that, skipping weekends.
        let mondayIndex = (firstWeekday + 5) % 7                  // Mon=0 … Sun=6
        if mondayIndex <= 4 { cells += Array(repeating: nil, count: mondayIndex) }
        for day in range {
            if let d = cal.date(byAdding: .day, value: day - 1, to: first) {
                let wd = cal.component(.weekday, from: d)
                if wd != 1 && wd != 7 { cells.append(d) }         // skip Sat/Sun
            }
        }
        return cells
    }
}
