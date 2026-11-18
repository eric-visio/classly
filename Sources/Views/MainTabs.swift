import SwiftUI
import SwiftData
import Charts
import Observation

enum AppTab: Hashable { case today, grades, homework, attendance, calendar }

/// Lets a screen move the app to another tab (e.g. the "Calendar" button on Today).
@Observable final class TabRouter { var tab: AppTab = .today }

struct MainTabs: View {
    var refreshing: Bool
    var refresh: () async -> Void
    @Query(sort: \Child.sortOrder) private var children: [Child]
    @AppStorage("selectedChild") private var selectedID = ""
    @State private var router = TabRouter()

    private var child: Child? { children.first { $0.id.uuidString == selectedID } ?? children.first }

    var body: some View {
        TabView(selection: Bindable(router).tab) {
            screen(title: "Today", subtitle: Date.now.formatted(.dateTime.weekday(.wide).month().day())) { TodayView(child: $0) }
                .tabItem { Label("Today", systemImage: "house") }.tag(AppTab.today)
            screen(title: "Grades") { GradesView(child: $0) }.tabItem { Label("Grades", systemImage: "chart.bar") }.tag(AppTab.grades)
            screen(title: "Homework") { HomeworkView(child: $0) }.tabItem { Label("Homework", systemImage: "checklist") }.tag(AppTab.homework)
            screen(title: "Attendance") { AttendanceView(child: $0) }.tabItem { Label("Attendance", systemImage: "person.badge.clock") }.tag(AppTab.attendance)
            calendarScreen.tabItem { Label("Calendar", systemImage: "calendar") }.tag(AppTab.calendar)
        }
        .tint(Theme.accent)
        .environment(router)
    }

    private func sync() { Task { await refresh() } }

    @ViewBuilder
    private func screen<V: View>(title: String, subtitle: String? = nil, @ViewBuilder _ content: @escaping (Child) -> V) -> some View {
        NavigationStack {
            Group {
                if let child {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            TabHeader(title: title, subtitle: subtitle, children: children,
                                      selectedID: $selectedID, current: child, refreshing: refreshing, onSync: sync)
                            content(child)
                        }
                        .padding(20)
                    }
                    .background(Theme.bg)
                    .refreshable { await refresh() }
                } else {
                    Color.clear
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var calendarScreen: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TabHeader(title: "Calendar", refreshing: refreshing, onSync: sync)
                    SchoolCalendarView()
                }
                .padding(20)
            }
            .background(Theme.bg)
            .refreshable { await refresh() }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// Title on top, then a row with the kid switcher (left) and the Sync button (right). Settings is
/// the single gear on the title row. Calendar passes no kid switcher.
struct TabHeader: View {
    let title: String
    var subtitle: String? = nil
    var children: [Child] = []
    var selectedID: Binding<String>? = nil
    var current: Child? = nil
    let refreshing: Bool
    let onSync: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.largeTitle.bold())
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                NavigationLink { SettingsView() } label: {
                    Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(Theme.accent)
                        .frame(width: 40, height: 40).background(.white, in: Circle())
                }
                .accessibilityLabel("Settings")
            }
            HStack(spacing: 10) {
                if let selectedID, let current {
                    KidChips(children: children, selectedID: selectedID, current: current)
                }
                Spacer(minLength: 8)
                SyncButton(refreshing: refreshing, action: onSync)
            }
        }
    }
}

struct SyncButton: View {
    let refreshing: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .rotationEffect(.degrees(refreshing ? 360 : 0))
                    .animation(refreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: refreshing)
                Text(refreshing ? "Syncing…" : syncText).font(.footnote.weight(.semibold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12).frame(height: 40)
            .background(.white, in: Capsule())
        }
        .disabled(refreshing)
        .accessibilityLabel("Sync now")
    }
    private var syncText: String {
        guard let d = AppSettings.lastRefresh else { return "Sync" }
        return d.formatted(date: .omitted, time: .shortened)
    }
}

struct KidChips: View {
    let children: [Child]
    @Binding var selectedID: String
    let current: Child
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(children) { c in
                    Button { selectedID = c.id.uuidString } label: {
                        HStack(spacing: 10) {
                            Circle().fill(Color(hex: c.colorHex)).frame(width: 34, height: 34)
                                .overlay(Text(c.firstName.prefix(1)).bold().foregroundStyle(.white))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(c.firstName).font(.subheadline.bold()).foregroundStyle(.primary)
                                if let g = c.gradeLevel { Text("Grade \(g)").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .padding(.vertical, 6).padding(.leading, 6).padding(.trailing, 14)
                        .background(.white, in: Capsule())
                        .overlay(Capsule().strokeBorder(c.id == current.id ? Theme.accent : Color.gray.opacity(0.25), lineWidth: c.id == current.id ? 2 : 1))
                    }
                    .accessibilityAddTraits(c.id == current.id ? .isSelected : [])
                }
            }
        }
    }
}

// MARK: Shared pieces

struct Card<Content: View>: View {
    var title: String?
    var tint: Color = .white
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.headline) }
            content
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(tint, in: .rect(cornerRadius: 20))
    }
}

struct RingStat: View {
    let value: Double   // 0...1
    let label: String
    let text: String
    var color: Color = Theme.accent
    var body: some View {
        VStack(spacing: 6) {
            Gauge(value: value) { EmptyView() } currentValueLabel: { Text(text).font(.headline.monospacedDigit()) }
                .gaugeStyle(.accessoryCircularCapacity).tint(color).scaleEffect(1.25).frame(height: 70)
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12).background(.white, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}

extension Child {
    var psCourses: [Course] { courses.filter { $0.source == .powerSchool }.sorted { ($0.period ?? $0.name) < ($1.period ?? $1.name) } }
    var missing: [Assignment] { assignments.filter { $0.isMissing && !$0.isExempt } }
    var upcoming: [Assignment] {
        assignments.filter { !$0.isTurnedIn && ($0.dueDate.map { $0 >= Calendar.current.startOfDay(for: .now) } ?? false) }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }
    /// Unweighted 4.0 GPA from current letter grades (districts weight differently; label it as an estimate).
    var estimatedGPA: Double? {
        let pts: [String: Double] = ["A+": 4, "A": 4, "A-": 3.7, "A−": 3.7, "B+": 3.3, "B": 3, "B-": 2.7, "B−": 2.7,
                                     "C+": 2.3, "C": 2, "C-": 1.7, "C−": 1.7, "D+": 1.3, "D": 1, "F": 0]
        let vals = psCourses.compactMap { $0.letterGrade.flatMap { pts[$0] } }
        return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }
    /// Past-due work PowerSchool has a *definite* status for: turned in (scored or
    /// collected), flagged missing, or flagged late. Work that's merely ungraded and
    /// unflagged is "unknown" — PowerSchool can't say if it was handed in — so we don't
    /// let it count for or against on-time.
    var decidedPastDue: [Assignment] {
        assignments.filter {
            ($0.dueDate ?? .distantFuture) < .now && !$0.isExempt
            && ($0.isTurnedIn || $0.isMissing || $0.isLate)
        }
    }
    /// The assignments pulling the on-time number down: missing or turned in late.
    /// This is exactly what the On-time tile drills into.
    var offTrack: [Assignment] {
        decidedPastDue
            .filter { $0.isMissing || $0.isLate || !$0.isTurnedIn }
            .sorted { ($0.dueDate ?? .distantPast) > ($1.dueDate ?? .distantPast) }
    }
    /// On-time = of past-due work with a known status, the share turned in and not late or missing.
    var onTimeRate: Double? {
        let decided = decidedPastDue
        guard !decided.isEmpty else { return nil }
        let onTime = decided.filter { $0.isTurnedIn && !$0.isLate && !$0.isMissing }
        return Double(onTime.count) / Double(decided.count)
    }
}
