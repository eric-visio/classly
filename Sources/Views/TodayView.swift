import SwiftUI
import SwiftData

struct TodayView: View {
    let child: Child
    @Query(sort: \SchoolEvent.start) private var events: [SchoolEvent]
    @Environment(TabRouter.self) private var router

    var body: some View {
        let insights = Insights(child: child)

        BriefingCard(child: child, events: events)

        AttentionCard(child: child, insights: insights)

        HStack(spacing: 10) {
            NavigationLink {
                kidScroll { GradesView(child: child) }.navigationTitle("Grades").navigationBarTitleDisplayMode(.inline)
            } label: {
                RingStat(value: (child.estimatedGPA ?? 0) / 4, label: "GPA",
                         text: child.estimatedGPA.map { String(format: "%.2f", $0) } ?? "–")
            }.buttonStyle(.plain)

            NavigationLink {
                kidScroll { AttendanceView(child: child) }.navigationTitle("Attendance").navigationBarTitleDisplayMode(.inline)
            } label: {
                RingStat(value: attendanceRate, label: "Attendance", text: "\(Int(attendanceRate * 100))%")
            }.buttonStyle(.plain)

            NavigationLink {
                kidScroll { HomeworkView(child: child, initialFilter: .offtrack) }.navigationTitle("Work").navigationBarTitleDisplayMode(.inline)
            } label: {
                RingStat(value: child.onTimeRate ?? 0, label: "On-time work",
                         text: child.onTimeRate.map { "\(Int($0 * 100))%" } ?? "–", color: Color(hex: "E07A1F"))
            }.buttonStyle(.plain)
        }

        Card {
            HStack {
                Text("Due soon").font(.headline)
                Spacer()
                NavigationLink("See all") {
                    kidScroll { HomeworkView(child: child) }.navigationTitle("Homework").navigationBarTitleDisplayMode(.inline)
                }
                .font(.subheadline.weight(.semibold))
            }
            let soon = child.upcoming.prefix(6)
            if soon.isEmpty { Text("Nothing due right now.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(Array(soon)) { a in AssignmentRow(a: a, color: Color(hex: child.colorHex)) }
        }

        Card {
            HStack {
                Text("Coming up at school").font(.headline)
                Spacer()
                Button("Calendar") { router.tab = .calendar }.font(.subheadline.weight(.semibold))
            }
            let upcoming = events.filter { $0.start >= Calendar.current.startOfDay(for: .now) && $0.childIDs.contains(child.id) }.prefix(3)
            if upcoming.isEmpty {
                Text("Add your school's calendar in Settings to see days off, picture day and events.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(upcoming)) { e in EventRow(e: e) }
        }

        PTONewsCard()

        Label("Stored only on this iPhone", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }

    /// Wrap a pushed detail in the same padded, tinted scroll the tabs use.
    @ViewBuilder private func kidScroll<V: View>(@ViewBuilder _ content: @escaping () -> V) -> some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) { content() }.padding(20) }.background(Theme.bg)
    }

    private var attendanceRate: Double {
        // Rough rate: days with an absence over school days so far (≈ 180-day year, prorated).
        let absentDays = Set(child.attendance.filter { $0.kind == .absentExcused || $0.kind == .absentUnexcused }
            .map { Calendar.current.startOfDay(for: $0.date) }).count
        let schoolDaysSoFar = max(1.0, Date.now.timeIntervalSince(SchoolYear.start) / 86_400 * 5 / 7 * 0.93)
        return max(0, 1 - Double(absentDays) / schoolDaysSoFar)
    }

}

/// A short, on-device summary of the kid's day. Shows the instant templated version first,
/// then quietly upgrades to the Apple Intelligence paragraph when the device supports it.
struct BriefingCard: View {
    let child: Child
    let events: [SchoolEvent]
    @State private var text = ""
    @State private var usedAI = false

    var body: some View {
        let facts = Briefing.facts(for: child, events: events)
        Card {
            HStack(spacing: 8) {
                Text("Today's briefing").font(.headline)
                Spacer()
                if usedAI {
                    Text("On-device AI").font(.caption2).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
            }
            Text(text.isEmpty ? Briefing.templated(facts) : text)
                .font(.subheadline).foregroundStyle(.primary).lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Instant templated text shows immediately above; this upgrades to the on-device AI
        // paragraph when available, and re-runs whenever the underlying facts change.
        .task(id: facts.signature) {
            text = Briefing.templated(facts)
            usedAI = false
            if let ai = await Briefing.ai(facts) {
                text = ai
                usedAI = true
            }
        }
    }
}

/// The amber "Needs your attention" card on Today. Each row jumps to the relevant screen.
/// Shows a calm green state when nothing needs attention.
struct AttentionCard: View {
    let child: Child
    let insights: Insights

    var body: some View {
        let alerts = Array(insights.alerts.prefix(4))
        if alerts.isEmpty {
            Card(tint: Color(hex: "E7F4EC")) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Color(hex: "2E7D4F"))
                    Text("All caught up").font(.headline).foregroundStyle(Color(hex: "1E5B38"))
                }
                Text("No missing work, grade drops or attendance flags right now.")
                    .font(.footnote).foregroundStyle(Color(hex: "2E6B46"))
            }
        } else {
            Card(tint: Theme.attentionBG) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.attention)
                    Text("Needs your attention · \(insights.alerts.count)").font(.headline).foregroundStyle(Color(hex: "8A3D08"))
                }
                ForEach(alerts) { alert in
                    NavigationLink { destination(for: alert) } label: { row(alert) }
                    if alert.id != alerts.last?.id { Divider().overlay(Color(hex: "F1D5BC")) }
                }
            }
        }
    }

    private func row(_ alert: Insights.Alert) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(.subheadline.bold()).foregroundStyle(Color(hex: "121722"))
                Text(alert.detail).font(.footnote).foregroundStyle(Color(hex: "6A4A30")).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(Color(hex: "8A3D08"))
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder private func destination(for alert: Insights.Alert) -> some View {
        let t = alert.title.lowercased()
        let wrap = { (v: AnyView) in ScrollView { VStack(alignment: .leading, spacing: 18) { v }.padding(20) }.background(Theme.bg) }
        if let name = alert.course, let course = child.psCourses.first(where: { $0.name == name }) {
            CourseDetailView(child: child, course: course)
        } else if t.contains("absent") || t.contains("tardy") || t.contains("attendance") {
            wrap(AnyView(AttendanceView(child: child)))
        } else if t.contains("missing") || t.contains("turned in") || t.contains("quiz") || t.contains("test") {
            wrap(AnyView(HomeworkView(child: child, initialFilter: t.contains("missing") ? .offtrack : .upcoming)))
        } else {
            wrap(AnyView(GradesView(child: child)))
        }
    }
}

enum SchoolYear {
    /// Sept 1 of the current school year.
    static var start: Date {
        let cal = Calendar.current; let now = Date.now
        let y = cal.component(.year, from: now) - (cal.component(.month, from: now) < 8 ? 1 : 0)
        return cal.date(from: DateComponents(year: y, month: 9, day: 1)) ?? now
    }
}

struct AssignmentRow: View {
    let a: Assignment
    let color: Color
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(a.isMissing ? Theme.attention : color).frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(a.title).font(.subheadline.weight(.semibold))
                Text([a.courseName, a.dueDate?.formatted(.dateTime.weekday().month().day().hour().minute()) ?? a.classroomDueText,
                      a.source == .classroom ? "Classroom" : "PowerSchool"].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                if a.isLate && !a.isMissing {
                    Text("Late").font(.caption2.bold()).foregroundStyle(Color(hex: "8A3D08"))
                        .padding(.horizontal, 6).padding(.vertical, 3).background(Color(hex: "FCE3CE"), in: Capsule())
                }
                if a.isMissing {
                    Text("Missing").font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4).background(Theme.attention, in: .rect(cornerRadius: 8))
                } else if let e = a.pointsEarned, let p = a.pointsPossible {
                    Text("\(e.formatted())/\(p.formatted())").font(.subheadline.bold().monospacedDigit())
                } else if a.isTurnedIn {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).accessibilityLabel("Turned in")
                }
            }
        }
        .frame(minHeight: 44)
    }
}

struct EventRow: View {
    let e: SchoolEvent
    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 0) {
                Text(e.start.formatted(.dateTime.month(.abbreviated))).font(.caption2.bold()).textCase(.uppercase)
                    .foregroundStyle(e.kind == .noSchool ? Theme.attention : Theme.accent)
                Text(e.start.formatted(.dateTime.day())).font(.title3.bold())
            }
            .frame(width: 48, height: 52)
            .background(e.kind == .noSchool ? Theme.attentionBG : Theme.accent.opacity(0.1), in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(e.title).font(.subheadline.bold())
                    .foregroundStyle(e.kind == .noSchool ? Theme.attention : .primary)
                Text(e.allDay ? e.start.formatted(.dateTime.weekday(.wide)) : e.start.formatted(.dateTime.weekday().hour().minute()))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if e.isPTO {
                Text("PTO").font(.caption2.bold()).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
            }
        }
    }
}

extension SchoolEvent {
    /// True for events that came from the PTO's Membership Toolkit calendar feed.
    var isPTO: Bool { key.contains("membershiptoolkit.com/subscription/") }
}



/// One row per school day, so an absence in 7 classes shows once, not 7 times.
struct AttendanceDay: Identifiable {
    let date: Date
    let records: [AttendanceRecord]
    var id: Date { date }

    var title: String {
        let absent = records.filter { $0.kind == .absentExcused || $0.kind == .absentUnexcused }
        let tardy = records.filter { $0.kind == .tardy }
        var parts: [String] = []
        if !absent.isEmpty {
            let excused = absent.allSatisfy { $0.kind == .absentExcused }
            parts.append((excused ? "Excused absence" : "Absent") + (absent.count > 1 ? " · \(absent.count) classes" : periodText(absent)))
        }
        if !tardy.isEmpty { parts.append("Tardy" + (tardy.count > 1 ? " · \(tardy.count) classes" : periodText(tardy))) }
        return parts.joined(separator: ", ")
    }

    private func periodText(_ r: [AttendanceRecord]) -> String {
        r.first?.period.map { " · Period \($0)" } ?? ""
    }

    static func group(_ records: [AttendanceRecord]) -> [AttendanceDay] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: records) { (r: AttendanceRecord) -> Date in cal.startOfDay(for: r.date) }
        return byDay.map { AttendanceDay(date: $0.key, records: $0.value) }.sorted { $0.date > $1.date }
    }
}
