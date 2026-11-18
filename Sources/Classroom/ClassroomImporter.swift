import Foundation
import SwiftData

/// Reads a Classroom snapshot staged by the Safari extension (via the shared App Group) and
/// turns it into `.classroom` assignments for one kid. Called automatically when the app comes
/// back to the foreground after a sync, so the user never does a separate "save" step.
enum ClassroomImporter {

    /// Imports the pending snapshot for `kidID`. Returns how many assignments were written,
    /// or nil if there was nothing staged. Safe to call on every foreground.
    @MainActor
    @discardableResult
    static func importPending(into context: ModelContext, kidID: UUID?) -> Int? {
        guard let url = try? ClassroomWebSnapshot.inbox().appendingPathComponent("pending.json"),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(ClassroomWebSnapshot.self, from: data),
              snapshot.isValid else { return nil }

        // Which kid? The screen that launched the sync recorded it; fall back to the only kid.
        let children = (try? context.fetch(FetchDescriptor<Child>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        let kid = children.first { $0.id == kidID } ?? (children.count == 1 ? children.first : nil)
        guard let kid else { return nil }   // ambiguous: leave the file for the kid screen to claim

        let count = apply(snapshot, to: kid, context: context)
        try? context.save()
        try? FileManager.default.removeItem(at: url)
        return count
    }

    /// Upsert the snapshot's assignments onto a kid. Exposed for tests.
    @MainActor
    @discardableResult
    static func apply(_ snapshot: ClassroomWebSnapshot, to kid: Child, context: ModelContext, now: Date = .now) -> Int {
        let existing = Dictionary(kid.assignments.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()

        for item in snapshot.items {
            let key = "gc-web:\(kid.id):\(item.courseId):\(item.id)"
            seen.insert(key)
            let a = existing[key] ?? Assignment(key: key, source: .classroom, courseName: item.courseName, title: item.title)
            a.title = item.title
            a.courseName = item.courseName
            a.link = item.url
            a.classroomDueText = item.dueText
            a.dueDate = ClassroomDueParser.date(from: item.dueText, now: now)

            // Classroom is our source for UPCOMING homework (assigned work, with due dates, that
            // may not be in PowerSchool's gradebook yet). PowerSchool stays the source of truth for
            // missing/late — so we only mark Classroom items turned-in (from the Done list) and
            // never flag them missing/late here, to avoid double-counting against PowerSchool.
            if item.status == "turned-in" {
                a.isTurnedIn = true
            } else {
                a.isTurnedIn = false
            }
            a.isMissing = false
            a.isLate = false

            if existing[key] == nil { a.child = kid; context.insert(a) }
        }
        // The To-do list is the full current set of not-turned-in work, so anything we had under
        // gc-web: that's no longer listed was turned in or removed — drop it.
        for a in kid.assignments where a.key.hasPrefix("gc-web:\(kid.id):") && !seen.contains(a.key) {
            context.delete(a)
        }
        return snapshot.items.count
    }
}

/// Parses the human due text the extension scrapes ("Due Nov 7", "Due Today, 11:59 PM",
/// "Due Tomorrow", "No due date") into a real date, so imports feed Due soon and the dashboard.
enum ClassroomDueParser {
    static func date(from text: String?, now: Date = .now, calendar: Calendar = .current) -> Date? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.contains("no due date") { return nil }

        // Strip a leading "Due" and any weekday word.
        var s = raw.replacingOccurrences(of: "Due", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: CharacterSet(charactersIn: " :–-"))

        let time = clockTime(in: s) ?? (hour: 23, minute: 59)

        if lower.contains("today") {
            return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: now)
        }
        if lower.contains("tomorrow") {
            let t = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: t)
        }
        // A weekday name ("Thursday, 11:59 PM") → the next occurrence of that weekday.
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        if let wd = weekdays.firstIndex(where: { lower.contains($0) }) {
            let target = wd + 1   // Calendar weekday: Sunday = 1
            let todayWD = calendar.component(.weekday, from: now)
            var delta = (target - todayWD + 7) % 7
            if delta == 0 { delta = 7 }   // "Thursday" when today is Thursday means next Thursday
            let day = calendar.date(byAdding: .day, value: delta, to: now) ?? now
            return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day)
        }

        // Drop a trailing time clause so the date parser sees just the date part.
        if let comma = s.firstIndex(of: ",") { s = String(s[..<comma]) }
        s = s.trimmingCharacters(in: .whitespaces)

        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["MMM d, yyyy", "MMMM d, yyyy", "MMM d", "MMMM d", "M/d/yyyy", "M/d"] {
            f.dateFormat = fmt
            if let parsed = f.date(from: s) {
                return assembleNearestYear(parsed, time: time, now: now, calendar: calendar)
            }
        }
        return nil
    }

    /// Month/day with no year: choose the year that lands the date closest to now
    /// (handles a Jan due date seen in December, and vice-versa).
    private static func assembleNearestYear(_ parsed: Date, time: (hour: Int, minute: Int), now: Date, calendar: Calendar) -> Date? {
        var c = calendar.dateComponents([.year, .month, .day], from: parsed)
        let hadYear = (c.year ?? 0) > 1900 && calendar.component(.year, from: parsed) != 2000
        c.hour = time.hour; c.minute = time.minute
        if hadYear { return calendar.date(from: c) }
        let yearNow = calendar.component(.year, from: now)
        let candidates = [yearNow - 1, yearNow, yearNow + 1].compactMap { y -> Date? in
            var cc = c; cc.year = y; return calendar.date(from: cc)
        }
        return candidates.min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
    }

    private static func clockTime(in s: String) -> (hour: Int, minute: Int)? {
        guard let m = try? NSRegularExpression(pattern: #"(\d{1,2})(?::(\d{2}))?\s*([AaPp][Mm])"#)
            .firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func grp(_ i: Int) -> String? { Range(m.range(at: i), in: s).map { String(s[$0]) } }
        var h = Int(grp(1) ?? "") ?? 23
        let min = Int(grp(2) ?? "0") ?? 0
        let pm = (grp(3) ?? "").lowercased() == "pm"
        if pm && h != 12 { h += 12 }
        if !pm && h == 12 { h = 0 }
        return (h, min)
    }
}
