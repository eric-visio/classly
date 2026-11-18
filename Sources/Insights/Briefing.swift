import Foundation
import SwiftUI
import SwiftData

#if canImport(FoundationModels)
import FoundationModels
#endif

/// A short, parent-facing summary of a kid's school day.
///
/// Two layers, both on-device:
///  - `templated(_:)` composes a plain-language paragraph straight from the synced facts.
///    It's instant and always works, so the card never sits empty.
///  - `ai(_:)` upgrades that to a warmer paragraph using Apple Intelligence's on-device model
///    (Foundation Models, iOS 26+ on supported hardware). Nothing leaves the phone, and it only
///    ever sees the facts we hand it. On older devices or any failure, we keep the templated text.
enum Briefing {

    struct Facts {
        var name: String
        var upcoming: [(title: String, course: String, due: Date?)]
        var offTrackCount: Int
        var offTrackExample: String?        // e.g. "Mesopotamia map (Social Studies)"
        var gpa: Double?
        var recentAbsences: Int             // last 14 days
        var recentTardies: Int
        var nextNoSchool: (title: String, date: Date)?
        var hasAnyData: Bool

        /// Changes whenever anything the briefing depends on changes, so the card re-generates.
        var signature: String {
            let up = upcoming.first.map { "\($0.title)@\($0.due?.timeIntervalSince1970 ?? 0)" } ?? "-"
            let off = nextNoSchool.map { "\($0.title)@\($0.date.timeIntervalSince1970)" } ?? "-"
            return "\(name)|\(offTrackCount)|\(upcoming.count)|\(up)|\(gpa ?? -1)|\(recentAbsences)|\(recentTardies)|\(off)|\(hasAnyData)"
        }
    }

    // MARK: Gather facts

    @MainActor
    static func facts(for child: Child, events: [SchoolEvent], now: Date = .now) -> Facts {
        let soon = child.upcoming.prefix(3).map {
            (title: $0.title, course: $0.courseName, due: $0.dueDate)
        }
        // Only flag off-track work from the last two weeks. Older missing items tend to linger
        // in the portal and shouldn't keep resurfacing in the briefing day after day.
        let offCutoff = now.addingTimeInterval(-14 * 86_400)
        let off = child.offTrack.filter { $0.dueDate.map { $0 >= offCutoff } ?? true }
        let offExample = off.first.map { "\($0.title) (\($0.courseName))" }

        let twoWeeksAgo = now.addingTimeInterval(-14 * 86_400)
        let recent = child.attendance.filter { $0.date >= twoWeeksAgo && $0.date <= now }
        let absences = Set(recent.filter { $0.kind == .absentExcused || $0.kind == .absentUnexcused }
            .map { Calendar.current.startOfDay(for: $0.date) }).count
        let tardies = Set(recent.filter { $0.kind == .tardy }
            .map { Calendar.current.startOfDay(for: $0.date) }).count

        let horizon = now.addingTimeInterval(10 * 86_400)
        let nextOff = events
            .filter { $0.kind == .noSchool && $0.childIDs.contains(child.id)
                && $0.start >= Calendar.current.startOfDay(for: now) && $0.start <= horizon }
            .sorted { $0.start < $1.start }
            .first
            .map { (title: $0.title, date: $0.start) }

        let any = !child.assignments.isEmpty || !child.attendance.isEmpty || child.estimatedGPA != nil

        return Facts(
            name: child.firstName,
            upcoming: Array(soon),
            offTrackCount: off.count,
            offTrackExample: offExample,
            gpa: child.estimatedGPA,
            recentAbsences: absences,
            recentTardies: tardies,
            nextNoSchool: nextOff,
            hasAnyData: any
        )
    }

    // MARK: Templated fallback (instant, deterministic)

    static func templated(_ f: Facts) -> String {
        guard f.hasAnyData else {
            return "Once Classly finishes syncing, \(f.name)'s day — what's due, anything missing, and upcoming days off — will be summarized right here."
        }

        var parts: [String] = []

        // Work status leads.
        if f.offTrackCount == 0 {
            parts.append("\(f.name) is caught up — nothing missing or late right now.")
        } else if f.offTrackCount == 1 {
            parts.append("\(f.name) has 1 item that's missing or late" +
                         (f.offTrackExample.map { ": \($0)." } ?? "."))
        } else {
            parts.append("\(f.name) has \(f.offTrackCount) items that are missing or late" +
                         (f.offTrackExample.map { ", starting with \($0)." } ?? "."))
        }

        // What's coming due.
        if let next = f.upcoming.first {
            let due = next.due.map { " (due \(Self.short($0)))" } ?? ""
            if f.upcoming.count == 1 {
                parts.append("Next up is \(next.title) in \(next.course)\(due).")
            } else {
                parts.append("\(f.upcoming.count) things are coming due soon — next is \(next.title) in \(next.course)\(due).")
            }
        }

        // Attendance, only if notable.
        if f.recentAbsences + f.recentTardies > 0 {
            var a: [String] = []
            if f.recentAbsences > 0 { a.append("\(f.recentAbsences) absence\(f.recentAbsences == 1 ? "" : "s")") }
            if f.recentTardies > 0 { a.append("\(f.recentTardies) tardy\(f.recentTardies == 1 ? "" : "es")") }
            parts.append("The last two weeks show \(a.joined(separator: " and ")).")
        }

        // A day off worth knowing about.
        if let off = f.nextNoSchool {
            parts.append("Heads up: \(off.title) on \(Self.short(off.date)) — no school.")
        }

        return parts.prefix(3).joined(separator: " ")
    }

    // MARK: On-device AI upgrade

    /// Returns a model-written paragraph, or nil if Apple Intelligence isn't available or errors.
    static func ai(_ f: Facts) async -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        guard f.hasAnyData else { return nil }
        guard case .available = SystemLanguageModel.default.availability else { return nil }

        let instructions = """
        You write a one-paragraph daily briefing for a parent about their child's schoolwork, \
        shown on a home screen. Rules:
        - Use ONLY the facts provided. Never invent assignments, grades, dates, or events.
        - 2 to 3 short sentences. Warm, calm, plain language. No bullet points or headers.
        - Refer to the child by first name. Never be alarmist or judgmental about the child.
        - If nothing needs attention, briefly reassure. Don't give advice unless a fact calls for it.
        """

        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: promptBody(f))
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// The fact sheet handed to the model — plain lines, no instructions.
    private static func promptBody(_ f: Facts) -> String {
        var lines = ["Child's first name: \(f.name)"]
        if let gpa = f.gpa { lines.append("Estimated GPA: \(String(format: "%.2f", gpa)) out of 4.0") }
        lines.append("Missing or late assignments: \(f.offTrackCount)" +
                     (f.offTrackExample.map { " (e.g. \($0))" } ?? ""))
        if f.upcoming.isEmpty {
            lines.append("Nothing due in the next few days.")
        } else {
            let items = f.upcoming.map { "\($0.title) in \($0.course)" + ($0.due.map { " due \(short($0))" } ?? "") }
            lines.append("Coming due soon: " + items.joined(separator: "; "))
        }
        lines.append("Absences in the last 14 days: \(f.recentAbsences)")
        lines.append("Tardies in the last 14 days: \(f.recentTardies)")
        if let off = f.nextNoSchool { lines.append("Next no-school day: \(off.title) on \(short(off.date))") }
        return "Facts:\n" + lines.joined(separator: "\n")
    }

    private static func short(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
