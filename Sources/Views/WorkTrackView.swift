import SwiftUI

/// Work-habit visualizations for the Homework tab, built from assignment data (PowerSchool status
/// + Classroom upcoming). "Work track" is a per-class × per-week status grid; "Turned in, week by
/// week" is the share of each week's due work that was turned in. Neither is a grade — both show
/// follow-through.

private enum WorkStatus { case turnedIn, late, missing, upcoming, unknown }

private struct WorkWeeks {
    let starts: [Date]           // 8 week-start dates, oldest → current
    let labels: [String]
    static func make(now: Date = .now) -> WorkWeeks {
        let cal = Calendar.current
        let thisStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        let starts = (0..<8).compactMap { cal.date(byAdding: .weekOfYear, value: -(7 - $0), to: thisStart) }
        let labels = starts.map { $0.formatted(.dateTime.month(.twoDigits).day(.twoDigits)) }  // e.g. 09/20
        return WorkWeeks(starts: starts, labels: labels)
    }
    func index(for date: Date) -> Int? {
        let cal = Calendar.current
        guard let s = cal.dateInterval(of: .weekOfYear, for: date)?.start else { return nil }
        return starts.firstIndex(of: s)
    }
}

private func status(of a: Assignment, now: Date = .now) -> WorkStatus {
    if a.isMissing && !a.isExempt { return .missing }
    if a.isTurnedIn { return a.isLate ? .late : .turnedIn }
    if let due = a.dueDate, due >= Calendar.current.startOfDay(for: now) { return .upcoming }
    return .unknown
}

private func isQuiz(_ a: Assignment) -> Bool {
    let s = (a.category ?? "") + " " + a.title
    return s.range(of: "quiz|test|exam|assessment", options: [.regularExpression, .caseInsensitive]) != nil
}

private func color(_ s: WorkStatus) -> Color {
    switch s {
    case .turnedIn: Color(hex: "2E7D4F")
    case .late:     Color(hex: "C98A2B")
    case .missing:  Color(hex: "C0392B")
    case .upcoming: Color(hex: "B8B8AE")
    case .unknown:  Color(hex: "D8D8D0")
    }
}

// MARK: Work track grid

struct WorkTrackCard: View {
    let child: Child
    private let weeks = WorkWeeks.make()

    private var courses: [String] {
        let names = child.psCourses.map(\.name)
        let fromAssignments = Array(Set(child.assignments.map(\.courseName)))
        let ordered = names + fromAssignments.filter { !names.contains($0) }.sorted()
        return Array(ordered.prefix(8))
    }

    /// Markers for one class in one week.
    private func markers(course: String, week: Int) -> [(status: WorkStatus, quiz: Bool)] {
        child.assignments
            .filter { $0.courseName == course }
            .filter { a in a.dueDate.flatMap { weeks.index(for: $0) } == week }
            .sorted { ($0.dueDate ?? .distantPast) < ($1.dueDate ?? .distantPast) }
            .prefix(4)
            .map { (status(of: $0), isQuiz($0)) }
    }

    var body: some View {
        Card {
            Text("Work track").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 0) {
                        Text("Class").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: 92, alignment: .leading)
                        ForEach(weeks.labels.indices, id: \.self) { i in
                            Text(weeks.labels[i]).font(.caption2).foregroundStyle(.secondary)
                                .frame(width: 42)
                        }
                    }
                    ForEach(courses, id: \.self) { course in
                        HStack(spacing: 0) {
                            Text(course).font(.caption.weight(.medium)).lineLimit(1)
                                .frame(width: 92, alignment: .leading)
                            ForEach(weeks.starts.indices, id: \.self) { w in
                                cell(markers(course: course, week: w))
                                    .frame(width: 42, height: 30)
                            }
                        }
                        if course != courses.last { Divider() }
                    }
                }
            }
            legend
        }
    }

    private func cell(_ marks: [(status: WorkStatus, quiz: Bool)]) -> some View {
        let cols = [GridItem(.fixed(10), spacing: 3), GridItem(.fixed(10), spacing: 3)]
        return LazyVGrid(columns: cols, spacing: 3) {
            ForEach(marks.indices, id: \.self) { i in marker(marks[i]) }
        }
    }

    @ViewBuilder private func marker(_ m: (status: WorkStatus, quiz: Bool)) -> some View {
        let filled = m.status == .turnedIn || m.status == .late
        Group {
            switch (m.quiz, filled) {
            case (true, true):   Circle().fill(color(m.status))
            case (true, false):  Circle().strokeBorder(color(m.status), lineWidth: 1.4)
            case (false, true):  RoundedRectangle(cornerRadius: 2).fill(color(m.status))
            case (false, false): RoundedRectangle(cornerRadius: 2).strokeBorder(color(m.status), lineWidth: 1.4)
            }
        }
        .frame(width: 10, height: 10)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                legendItem(.turnedIn, "Turned in")
                legendItem(.late, "Late")
                legendItem(.missing, "Missing")
                legendItem(.upcoming, "Coming up")
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(color(.turnedIn)).frame(width: 9, height: 9)
                Text("square = assignment")
                Circle().fill(color(.turnedIn)).frame(width: 9, height: 9).padding(.leading, 8)
                Text("circle = quiz or test")
            }
        }
        .font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
    }
    private func legendItem(_ s: WorkStatus, _ label: String) -> some View {
        HStack(spacing: 4) {
            let filled = s == .turnedIn || s == .late
            Group {
                if filled { RoundedRectangle(cornerRadius: 2).fill(color(s)) }
                else { RoundedRectangle(cornerRadius: 2).strokeBorder(color(s), lineWidth: 1.2) }
            }.frame(width: 9, height: 9)
            Text(label)
        }
    }
}

// MARK: Turned in, week by week

struct TurnedInWeeklyCard: View {
    let child: Child
    private let weeks = WorkWeeks.make()

    private struct WeekBar { var onTime: Double; var late: Double; var hasWork: Bool }

    /// For each week, the share of due work turned in **on time** vs **late**. Only work whose due
    /// date has passed and has a definite status counts, so a week with nothing due yet shows "–".
    private var bars: [WeekBar] {
        let now = Date.now
        return weeks.starts.indices.map { w in
            let decided = child.assignments.filter { a in
                guard let due = a.dueDate, weeks.index(for: due) == w, due < now, !a.isExempt else { return false }
                return a.isTurnedIn || a.isMissing || a.isLate
            }
            guard !decided.isEmpty else { return WeekBar(onTime: 0, late: 0, hasWork: false) }
            let total = Double(decided.count)
            let onTime = Double(decided.filter { $0.isTurnedIn && !$0.isLate }.count) / total
            let late = Double(decided.filter { $0.isTurnedIn && $0.isLate }.count) / total
            return WeekBar(onTime: onTime, late: late, hasWork: true)
        }
    }

    private let green = Color(hex: "2E7D4F")
    private let amber = Color(hex: "C98A2B")
    private let track = Color(hex: "EDEAE0")

    var body: some View {
        Card {
            Text("Turned in, week by week").font(.headline)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(weeks.starts.indices, id: \.self) { i in
                    let b = bars[i]
                    let pct = Int(((b.onTime + b.late) * 100).rounded())
                    VStack(spacing: 6) {
                        Text(b.hasWork ? "\(pct)%" : "–")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(b.hasWork ? (b.late > 0 ? amber : (pct >= 50 ? green : .secondary)) : .secondary)
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 4).fill(track).frame(width: 20, height: 70)
                            VStack(spacing: 0) {              // late stacks above on-time
                                if b.late > 0 { Rectangle().fill(amber).frame(height: 70 * b.late) }
                                if b.onTime > 0 { Rectangle().fill(green).frame(height: 70 * b.onTime) }
                            }
                            .frame(width: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        Text(weeks.labels[i]).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 14) {
                legendDot(green, "On time")
                legendDot(amber, "Late")
                legendDot(track, "Missing")
            }
            .font(.caption2).foregroundStyle(.secondary)
            Text("Share of each week's due work that was turned in. A work-habit measure, not a grade.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func legendDot(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
            Text(label)
        }
    }
}
