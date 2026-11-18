import Foundation
import SwiftData

// All data lives in an on-device SwiftData store (see Persistence.swift).
// Nothing in here is ever sent to a server we run.

enum DataSource: String, Codable { case powerSchool, classroom, calendar }

@Model
final class PowerSchoolAccount {
    @Attribute(.unique) var id: UUID
    /// e.g. https://yourdistrict.powerschool.com
    var baseURL: URL
    var displayName: String
    /// Key used to look up the credential / cookies in the Keychain. Never the password itself.
    var keychainKey: String
    var usesSSO: Bool
    var lastSync: Date?
    var lastError: String?
    @Relationship(deleteRule: .nullify, inverse: \Child.powerSchoolAccount) var children: [Child] = []

    init(baseURL: URL, displayName: String, usesSSO: Bool = false) {
        self.id = UUID()
        self.baseURL = baseURL
        self.displayName = displayName
        self.keychainKey = "ps.\(UUID().uuidString)"
        self.usesSSO = usesSSO
    }
}

@Model
final class Child {
    @Attribute(.unique) var id: UUID
    var firstName: String
    var colorHex: String
    var gradeLevel: String?
    var schoolName: String?
    var sortOrder: Int

    /// The student identifier PowerSchool uses in the parent portal (e.g. the `frn` / student tab id).
    var powerSchoolStudentID: String?
    var powerSchoolAccount: PowerSchoolAccount?

    /// Kid's school Google account; tokens live in Keychain under `googleKeychainKey`.
    var googleEmail: String?
    var googleKeychainKey: String?
    var googleStatus: GoogleLinkStatus

    /// School website iCal / webcal feed for days off and events.
    var calendarFeedURL: URL?
    /// More feeds for the same kid (e.g. district calendar + their school's calendar).
    var extraCalendarFeedURLs: [URL] = []

    var allCalendarFeeds: [URL] { ([calendarFeedURL].compactMap { $0 } + extraCalendarFeedURLs).uniqued() }

    func setCalendarFeeds(_ urls: [URL]) {
        let list = urls.uniqued()
        calendarFeedURL = list.first
        extraCalendarFeedURLs = Array(list.dropFirst())
    }

    @Relationship(deleteRule: .cascade, inverse: \Course.child) var courses: [Course] = []
    @Relationship(deleteRule: .cascade, inverse: \Assignment.child) var assignments: [Assignment] = []
    @Relationship(deleteRule: .cascade, inverse: \AttendanceRecord.child) var attendance: [AttendanceRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \GradeSnapshot.child) var gradeSnapshots: [GradeSnapshot] = []

    init(firstName: String, colorHex: String, sortOrder: Int) {
        self.id = UUID()
        self.firstName = firstName
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.googleStatus = .notLinked
    }
}

enum GoogleLinkStatus: String, Codable {
    case notLinked, linked, blockedBySchool, expired, skipped
}

@Model
final class Course {
    var externalID: String          // PowerSchool section id or Classroom course id
    var source: DataSource
    var name: String
    var teacher: String?
    var teacherEmail: String?       // from the mailto link in the gradebook
    var period: String?
    var room: String?
    var letterGrade: String?
    var percent: Double?
    var termCode: String?           // e.g. Q1, S1
    var scoresURLString: String?    // link to the class's full score detail page in PowerSchool
    var absences: Int
    var tardies: Int
    var child: Child?

    init(externalID: String, source: DataSource, name: String) {
        self.externalID = externalID
        self.source = source
        self.name = name
        self.absences = 0
        self.tardies = 0
    }
}

@Model
final class Assignment {
    /// Stable key: "<source>:<courseExternalID>:<assignmentID or title+date>"
    @Attribute(.unique) var key: String
    var source: DataSource
    var courseName: String
    var title: String
    var category: String?
    var dueDate: Date?
    var classroomDueText: String?
    var pointsEarned: Double?
    var pointsPossible: Double?
    var letter: String?
    var isMissing: Bool
    var isLate: Bool
    var isExempt: Bool
    var isTurnedIn: Bool
    var link: URL?
    var firstSeen: Date
    /// When a score first showed up for this assignment (nil until graded). Used to surface
    /// "new scores" without mistaking already-graded work on the first sync for fresh results.
    var scoredAt: Date?
    var child: Child?

    init(key: String, source: DataSource, courseName: String, title: String) {
        self.key = key
        self.source = source
        self.courseName = courseName
        self.title = title
        self.isMissing = false
        self.isLate = false
        self.isExempt = false
        self.isTurnedIn = false
        self.firstSeen = .now
    }

    var percent: Double? {
        guard let e = pointsEarned, let p = pointsPossible, p > 0 else { return nil }
        return e / p * 100
    }
}

enum AttendanceKind: String, Codable { case present, tardy, absentExcused, absentUnexcused, other }

@Model
final class AttendanceRecord {
    @Attribute(.unique) var key: String  // childID:date:period
    var date: Date
    var period: String?
    var code: String                     // raw district code, e.g. "T", "A", "E"
    var kind: AttendanceKind
    var child: Child?

    init(key: String, date: Date, period: String?, code: String, kind: AttendanceKind) {
        self.key = key
        self.date = date
        self.period = period
        self.code = code
        self.kind = kind
    }
}

/// One row per course per sync day, so we can draw grade trend charts over time.
/// PowerSchool only shows the *current* grade, so history is built up on-device.
@Model
final class GradeSnapshot {
    var courseName: String
    var percent: Double
    var day: Date
    var child: Child?

    init(courseName: String, percent: Double, day: Date) {
        self.courseName = courseName
        self.percent = percent
        self.day = day
    }
}

enum EventKind: String, Codable { case noSchool, earlyDismissal, test, event, deadline, other }

@Model
final class SchoolEvent {
    @Attribute(.unique) var key: String   // feed uid
    var title: String
    var start: Date
    var end: Date?
    var allDay: Bool
    var kind: EventKind
    var childIDs: [UUID]

    init(key: String, title: String, start: Date, end: Date?, allDay: Bool, kind: EventKind, childIDs: [UUID]) {
        self.key = key
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.kind = kind
        self.childIDs = childIDs
    }
}


extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}
