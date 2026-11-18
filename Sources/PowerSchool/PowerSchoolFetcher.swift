import Foundation
import SwiftSoup

/// Everything we read from the portal for one student in one refresh.
struct PortalSnapshot {
    var studentID: String
    var studentName: String?
    var courses: [PortalCourse]
    var assignmentsByCourseKey: [String: [PortalAssignment]]
    var attendanceLegend: [String: AttendanceKind]
}

@MainActor
struct PowerSchoolFetcher {
    let account: PowerSchoolAccount

    /// Signs in (reusing the saved session when possible) and reads every linked student.
    /// Returns the possibly-refreshed credential so the caller can save new cookies.
    func fetchAll(studentIDs: [String]) async throws -> (PowerSchoolCredential, [PortalSnapshot]) {
        guard var cred = Keychain.get(PowerSchoolCredential.self, for: account.keychainKey) else {
            throw PortalBrowser.PortalError.signInRequired
        }
        let browser = PortalBrowser(baseURL: account.baseURL)
        cred = try await browser.ensureSignedIn(credential: cred)

        var homeHTML = try await browser.html(settle: .zero)
        let listed = PortalParsers.students(homeHTML: homeHTML)
        var snapshots: [PortalSnapshot] = []

        for id in studentIDs {
            // Only switch when the account has more than one student.
            if listed.count > 1 {
                try await browser.switchStudent(id: id)
                homeHTML = try await browser.html(settle: .zero)
            }
            let courses = PortalParsers.courses(homeHTML: homeHTML, baseURL: account.baseURL)
            var byCourse: [String: [PortalAssignment]] = [:]
            // Score detail only for the term in progress, to keep the refresh short.
            for course in courses {
                guard let url = course.currentGrade?.scoresURL else { continue }
                do {
                    try await browser.load(url: url)
                    let scoresHTML = try await browser.html()
                    byCourse[course.key] = PortalParsers.assignments(scoresHTML: scoresHTML)
                } catch {
                    continue   // one class failing shouldn't sink the whole refresh
                }
            }
            // Go back home so the next switchStudent() is available.
            try await browser.load(path: "guardian/home.html")
            snapshots.append(PortalSnapshot(
                studentID: id,
                studentName: PortalParsers.selectedStudentName(homeHTML: homeHTML),
                courses: courses, assignmentsByCourseKey: byCourse,
                attendanceLegend: AttendanceCodes.legend(homeHTML: homeHTML)))
            homeHTML = try await browser.html(settle: .zero)
        }
        return (cred, snapshots)
    }
}

/// Districts define their own attendance codes; the home page prints a legend such as
/// "Attendance Codes: A Absent Unexcused  E Absent Excused  T Tardy ...". We read it and fall
/// back to common defaults.
enum AttendanceCodes {
    static let defaults: [String: AttendanceKind] = [
        "A": .absentUnexcused, "U": .absentUnexcused, "E": .absentExcused, "X": .absentExcused,
        "T": .tardy, "L": .tardy, "TE": .tardy, "TU": .tardy, "P": .present, "": .present,
    ]

    static func legend(homeHTML: String) -> [String: AttendanceKind] {
        guard let doc = try? SwiftSoup.parse(homeHTML) else { return defaults }
        let text = ((try? doc.body()?.text()) ?? "")
        guard let r = text.range(of: "Attendance Codes", options: .caseInsensitive) else { return defaults }
        let tail = String(text[r.upperBound...].prefix(600))
        var map = defaults
        // pairs like "A Absent Unexcused" or "T Tardy"
        let re = try? NSRegularExpression(pattern: #"\b([A-Z0-9]{1,3})\s+([A-Za-z][A-Za-z \-]+?)(?=\s+[A-Z0-9]{1,3}\s+[A-Z]|\s*Citizenship|$)"#)
        re?.enumerateMatches(in: tail, range: NSRange(tail.startIndex..., in: tail)) { m, _, _ in
            guard let m, let c = Range(m.range(at: 1), in: tail), let d = Range(m.range(at: 2), in: tail) else { return }
            map[String(tail[c])] = classify(String(tail[d]))
        }
        return map
    }

    static func classify(_ description: String) -> AttendanceKind {
        let d = description.lowercased()
        if d.contains("tard") || d.contains("late") { return .tardy }
        if d.contains("absent") || d.contains("absence") {
            return (d.contains("excused") && !d.contains("unexcused")) ? .absentExcused : .absentUnexcused
        }
        if d.contains("present") { return .present }
        return .other
    }
}
