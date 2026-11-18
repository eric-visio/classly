import Foundation

/// Everything the dashboard shows, computed on the phone from stored PowerSchool data.
/// No network, no Google — just the assignments, courses and attendance already synced.
///
/// What PowerSchool can and can't tell us:
///  - turned in / late / missing / scored  → yes (from gradebook flags and scores)
///  - "coming up / due soon"                → only if the teacher entered the assignment early
///  - "started but not turned in"           → no (that's a Google Classroom status)
/// So "work habits" here means: of the work teachers have entered, how much is in on time.
struct Insights {
    let child: Child
    let now: Date
    let weeks: [Date]              // Monday of each of the last 8 weeks, oldest first

    init(child: Child, now: Date = .now) {
        self.child = child
        self.now = now
        var cal = Calendar(identifier: .gregorian); cal.firstWeekday = 2
        let thisMonday = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        self.weeks = (0..<8).reversed().compactMap { cal.date(byAdding: .day, value: -7 * $0, to: thisMonday) }
    }

    private var psAssignments: [Assignment] { child.assignments.filter { $0.source == .powerSchool && !$0.isExempt } }
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; return c }

    // MARK: Headline stats

    var missing: [Assignment] { psAssignments.filter(\.isMissing) }

    var missingClassCount: Int { Set(missing.map(\.courseName)).count }

    /// Turned in vs. due in the last 3 weeks (a work-habit count, not a grade).
    var turnedInLast3Weeks: (done: Int, total: Int) {
        let since = now.addingTimeInterval(-21 * 86_400)
        let due = psAssignments.filter { ($0.dueDate ?? .distantFuture) >= since && ($0.dueDate ?? .distantFuture) <= now }
        return (due.filter(\.isTurnedIn).count, due.count)
    }

    var dueNext7Days: [Assignment] {
        let end = now.addingTimeInterval(7 * 86_400)
        return child.upcoming.filter { ($0.dueDate ?? .distantFuture) <= end }
    }

    var gradesPosted: Int { child.psCourses.filter { $0.percent != nil }.count }

    // MARK: Work-track grid

    enum Cell: Equatable { case turnedIn, late, missing, comingUp, quiz(Bool) }  // quiz(turnedIn)

    struct Row: Identifiable {
        let course: String
        let cells: [[Cell]]       // one array of marks per week
        var id: String { course }
    }

    var workTrack: [Row] {
        let courses = child.psCourses.map(\.name)
        return courses.map { name in
            let items = psAssignments.filter { $0.courseName == name }
            let cells = weeks.map { weekStart -> [Cell] in
                let weekEnd = cal.date(byAdding: .day, value: 7, to: weekStart)!
                return items
                    .filter { a in (a.dueDate.map { $0 >= weekStart && $0 < weekEnd }) ?? false }
                    .sorted { ($0.dueDate ?? .distantPast) < ($1.dueDate ?? .distantPast) }
                    .map(cell(for:))
            }
            return Row(course: name, cells: cells)
        }
    }

    private func cell(for a: Assignment) -> Cell {
        let isQuiz = isTestLike(a)
        if a.isMissing { return isQuiz ? .quiz(false) : .missing }
        if a.isTurnedIn { return isQuiz ? .quiz(true) : (a.isLate ? .late : .turnedIn) }
        if (a.dueDate ?? .distantPast) > now { return .comingUp }
        return isQuiz ? .quiz(false) : .missing
    }

    // MARK: Weekly turn-in rate

    struct WeekRate: Identifiable { let week: Date; let rate: Double?; var id: Date { week } }

    var weeklyTurnIn: [WeekRate] {
        weeks.map { weekStart in
            let weekEnd = cal.date(byAdding: .day, value: 7, to: weekStart)!
            let due = psAssignments.filter { a in (a.dueDate.map { $0 >= weekStart && $0 < weekEnd }) ?? false }
            guard !due.isEmpty else { return WeekRate(week: weekStart, rate: nil) }
            return WeekRate(week: weekStart, rate: Double(due.filter(\.isTurnedIn).count) / Double(due.count))
        }
    }

    // MARK: Tests coming up

    var upcomingTests: [Assignment] {
        child.upcoming.filter(isTestLike).sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    private func isTestLike(_ a: Assignment) -> Bool {
        let hay = "\(a.category ?? "") \(a.title)".lowercased()
        return ["test", "exam", "quiz", "assessment", "midterm", "final"].contains { hay.contains($0) }
    }

    // MARK: What to act on

    enum AlertLevel { case high, medium }
    struct Alert: Identifiable {
        let level: AlertLevel
        let title: String
        let detail: String
        let course: String?
        var id: String { title + "|" + detail }
    }

    var alerts: [Alert] {
        var out: [Alert] = []

        // Missing quiz or test — highest priority.
        for a in missing where isTestLike(a) {
            out.append(Alert(level: .high, title: "A quiz or test isn't turned in",
                             detail: "\(a.courseName): \(a.title)", course: a.courseName))
        }

        // Overall recent turn-in rate low.
        let r = turnedInLast3Weeks
        if r.total >= 4 {
            let pct = Double(r.done) / Double(r.total)
            if pct < 0.5 {
                out.append(Alert(level: .high, title: "Only \(r.done) of \(r.total) recent assignments turned in",
                                 detail: "\(Int(pct * 100))% of work due in the last 3 weeks is in (threshold 50%).", course: nil))
            }
        }

        // Per-course: several recent missing in a row.
        for course in child.psCourses.map(\.name) {
            let recent = psAssignments.filter { $0.courseName == course && ($0.dueDate ?? .distantPast) > now.addingTimeInterval(-14 * 86_400) }
            let missingCount = recent.filter(\.isMissing).count
            if recent.count >= 3, missingCount >= 3 {
                out.append(Alert(level: .medium, title: "\(course): stopped turning work in",
                                 detail: "\(missingCount) of the last \(recent.count) assignments are missing.", course: course))
            }
        }

        // Grade below floor.
        let floor = AppSettings.load().gradeDropFloor
        for c in child.psCourses where (c.percent ?? 100) < floor {
            out.append(Alert(level: .medium, title: "\(c.name) is at \(c.letterGrade ?? "")\(c.percent.map { " (\(Int($0))%)" } ?? "")",
                             detail: c.teacher ?? "Below \(Int(floor))%", course: c.name))
        }

        // Tests in the next few days.
        let soonTests = upcomingTests.filter { ($0.dueDate ?? .distantFuture) <= now.addingTimeInterval(5 * 86_400) }
        if !soonTests.isEmpty {
            let names = soonTests.prefix(2).map { "\($0.courseName): \($0.title)" }.joined(separator: "; ")
            out.append(Alert(level: .medium, title: "\(soonTests.count) test\(soonTests.count == 1 ? "" : "s") soon",
                             detail: names, course: nil))
        }

        // Recent attendance.
        let recentAbs = child.attendance.filter { $0.date > now.addingTimeInterval(-7 * 86_400) }
        if !recentAbs.isEmpty {
            let tardy = recentAbs.contains { $0.kind == .tardy }
            out.append(Alert(level: .medium, title: tardy ? "Recent tardy or absence" : "Recent absence",
                             detail: "\(Set(recentAbs.map { cal.startOfDay(for: $0.date) }).count) day(s) in the last week.", course: nil))
        }

        return out
    }

    var headline: Alert? { alerts.first { $0.level == .high } ?? alerts.first }
}
