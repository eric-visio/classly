import Foundation
import SwiftData

/// Something new since the last refresh that may deserve a notification.
enum Change: Equatable {
    case newMissing(child: String, course: String, title: String)
    case gradeDropped(child: String, course: String, from: Double, to: Double, letter: String?)
    case newScore(child: String, course: String, title: String, percent: Double)
    case attendance(child: String, kind: AttendanceKind, date: Date, period: String?)
    case dayOff(title: String, date: Date)
    case needsSignIn(source: String, detail: String)
}

/// Runs one full refresh: PowerSchool → Google Classroom → school calendars, writes everything
/// to the on-device store, and returns what changed.
@MainActor
final class SyncEngine {
    let context: ModelContext
    init(context: ModelContext) { self.context = context }

    @discardableResult
    func refreshAll() async -> [Change] {
        var changes: [Change] = []
        let accounts = (try? context.fetch(FetchDescriptor<PowerSchoolAccount>())) ?? []
        let children = (try? context.fetch(FetchDescriptor<Child>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []

        for account in accounts { changes += await refreshPowerSchool(account) }
        if FeatureFlags.classroomEnabled {
            for child in children where child.googleStatus == .linked { changes += await refreshClassroom(child) }
        }
        changes += await refreshCalendars(children)
        await refreshPTO(children)

        try? context.save()
        return changes
    }

    // MARK: PowerSchool

    private func refreshPowerSchool(_ account: PowerSchoolAccount) async -> [Change] {
        let kids = account.children.filter { $0.powerSchoolStudentID != nil }
        guard !kids.isEmpty else { return [] }
        do {
            let (cred, snapshots) = try await PowerSchoolFetcher(account: account)
                .fetchAll(studentIDs: kids.compactMap(\.powerSchoolStudentID))
            try? Keychain.set(cred, for: account.keychainKey)
            account.lastSync = .now; account.lastError = nil
            var changes: [Change] = []
            for snap in snapshots {
                guard let kid = kids.first(where: { $0.powerSchoolStudentID == snap.studentID }) else { continue }
                changes += apply(snap, to: kid)
            }
            return changes
        } catch PortalBrowser.PortalError.signInRequired {
            account.lastError = "Sign-in expired"
            return [.needsSignIn(source: "PowerSchool", detail: account.displayName)]
        } catch {
            account.lastError = error.localizedDescription
            return []
        }
    }

    func apply(_ snap: PortalSnapshot, to kid: Child, today: Date = .now) -> [Change] {
        var changes: [Change] = []
        let cal = Calendar.current
        let day = cal.startOfDay(for: today)

        // Courses: replace PowerSchool courses, noting grade drops.
        let old = Dictionary(kid.courses.filter { $0.source == .powerSchool }.map { ($0.externalID, $0) }, uniquingKeysWith: { a, _ in a })
        for c in kid.courses where c.source == .powerSchool { context.delete(c) }
        var portalAttendance: [(date: Date, code: String, kind: AttendanceKind, period: String)] = []
        for pc in snap.courses {
            let course = Course(externalID: pc.key, source: .powerSchool, name: pc.name)
            course.teacher = pc.teacher; course.teacherEmail = pc.teacherEmail
            course.period = pc.period; course.room = pc.room
            course.letterGrade = pc.currentGrade?.letter; course.percent = pc.currentGrade?.percent
            course.termCode = pc.currentGrade?.term; course.absences = pc.absences; course.tardies = pc.tardies
            course.scoresURLString = pc.currentGrade?.scoresURL?.absoluteString
            course.child = kid
            context.insert(course)

            if let was = old[pc.key]?.percent, let now = course.percent, now <= was - 2 {
                changes.append(.gradeDropped(child: kid.firstName, course: pc.name, from: was, to: now, letter: course.letterGrade))
            }
            if let pct = course.percent,
               !kid.gradeSnapshots.contains(where: { $0.courseName == pc.name && cal.isDate($0.day, inSameDayAs: day) }) {
                let s = GradeSnapshot(courseName: pc.name, percent: pct, day: day); s.child = kid
                context.insert(s)
            }

            // Assignments for the current term.
            for pa in snap.assignmentsByCourseKey[pc.key] ?? [] {
                let dueKey = pa.dueDate.map { String(Int($0.timeIntervalSince1970 / 86_400)) } ?? "nodate"
                let key = "ps:\(kid.id):\(pc.key):\(pa.title):\(dueKey)"
                let existing = kid.assignments.first { $0.key == key }
                let a = existing ?? Assignment(key: key, source: .powerSchool, courseName: pc.name, title: pa.title)
                let wasMissing = existing?.isMissing ?? false
                let hadScore = existing?.pointsEarned != nil
                a.category = pa.category; a.dueDate = pa.dueDate
                a.pointsEarned = pa.earned; a.pointsPossible = pa.possible; a.letter = pa.letter
                a.isMissing = pa.missing; a.isLate = pa.late; a.isExempt = pa.exempt
                a.isTurnedIn = pa.collected || pa.earned != nil
                if existing == nil { a.child = kid; context.insert(a) }
                if a.isMissing && !wasMissing { changes.append(.newMissing(child: kid.firstName, course: pc.name, title: pa.title)) }
                if !hadScore, let p = a.percent {
                    // Stamp "newly scored" for any assignment we'd already seen ungraded — so a test
                    // graded today still shows in "New scores" even if its due date was a while ago.
                    // (On the very first sync everything is new, so nothing is stamped — avoids a flood.)
                    if existing != nil { a.scoredAt = .now }
                    if existing != nil || pa.dueDate.map({ $0 > today.addingTimeInterval(-7 * 86_400) }) == true {
                        changes.append(.newScore(child: kid.firstName, course: pc.name, title: pa.title, percent: p))
                    }
                }
            }

            // Attendance from the "Last Week / This Week" day columns is collected for all
            // courses first, then the two-week window is rebuilt below.
            portalAttendance += attendanceRecords(pc, legend: snap.attendanceLegend, today: today)
                .map { (date: $0.date, code: $0.code, kind: $0.kind, period: pc.period ?? pc.name) }
        }

        // Rebuild the last-two-weeks window from what the portal shows now. This also clears
        // records from earlier versions that misread codes. Only genuinely new ones notify.
        let windowStart = cal.date(byAdding: .day, value: -14, to: day) ?? day
        let previousKeys = Set(kid.attendance.filter { $0.date >= windowStart }.map(\.key))
        for r in kid.attendance where r.date >= windowStart || r.kind == .other { context.delete(r) }
        for rec in portalAttendance {
            let key = "\(kid.id):\(Int(rec.date.timeIntervalSince1970)):\(rec.period)"
            let r = AttendanceRecord(key: key, date: rec.date, period: rec.period, code: rec.code, kind: rec.kind)
            r.child = kid; context.insert(r)
            if !previousKeys.contains(key) {
                changes.append(.attendance(child: kid.firstName, kind: rec.kind, date: rec.date, period: rec.period))
            }
        }
        return changes
    }

    /// Turns day-column headers like "This Week W" into dates.
    func attendanceRecords(_ c: PortalCourse, legend: [String: AttendanceKind], today: Date)
        -> [(date: Date, code: String, kind: AttendanceKind)] {
        var cal = Calendar(identifier: .gregorian); cal.firstWeekday = 2
        guard let monday = cal.dateInterval(of: .weekOfYear, for: today)?.start else { return [] }
        // Attendance for today is usually not final until late morning.
        let cutoff = cal.component(.hour, from: today) >= 11 ? today : cal.startOfDay(for: today)
        let offsets: [String: Int] = ["M": 0, "T": 1, "W": 2, "H": 3, "R": 3, "F": 4]
        return c.recentDayCodes.compactMap { h, raw in
            let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Blank, dashes, dots etc. mean "nothing recorded", not an absence.
            guard let first = code.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) else { return nil }
            // Only codes the district legend (or the common defaults) defines as absent/tardy count.
            guard let kind = legend[code] ?? AttendanceCodes.defaults[code],
                  kind == .tardy || kind == .absentExcused || kind == .absentUnexcused else { return nil }
            let parts = h.split(separator: " ")
            guard let letter = parts.last.map(String.init), let off = offsets[letter] else { return nil }
            let week = h.lowercased().hasPrefix("last") ? -7 : 0
            guard let d = cal.date(byAdding: .day, value: off + week, to: monday), d < cutoff else { return nil }
            return (d, code, kind)
        }
    }

    // MARK: Google Classroom

    private func refreshClassroom(_ kid: Child) async -> [Change] {
        guard let key = kid.googleKeychainKey else { return [] }
        do {
            let token = try await GoogleAuth().validAccessToken(keychainKey: key)
            let items = try await ClassroomClient(accessToken: token).allItems()
            var changes: [Change] = []
            for item in items {
                let k = "gc:\(kid.id):\(item.course.id):\(item.work.id)"
                let existing = kid.assignments.first { $0.key == k }
                let a = existing ?? Assignment(key: k, source: .classroom, courseName: item.course.name, title: item.work.title)
                let wasMissing = existing?.isMissing ?? false
                let hadScore = existing?.pointsEarned != nil
                a.dueDate = item.work.due; a.pointsPossible = item.work.maxPoints
                a.pointsEarned = item.submission?.assignedGrade
                a.isTurnedIn = item.isTurnedIn; a.isLate = item.submission?.late ?? false
                a.isMissing = item.isMissing
                if !hadScore, a.percent != nil, existing != nil { a.scoredAt = .now }
                a.category = item.work.workType?.replacingOccurrences(of: "_", with: " ").capitalized
                a.link = item.work.alternateLink.flatMap(URL.init(string:))
                if existing == nil { a.child = kid; context.insert(a) }
                if a.isMissing && !wasMissing && existing != nil {
                    changes.append(.newMissing(child: kid.firstName, course: item.course.name, title: item.work.title))
                }
            }
            return changes
        } catch GoogleAuth.AuthError.blockedBySchool {
            kid.googleStatus = .blockedBySchool; return []
        } catch ClassroomClient.ClassroomError.unauthorized {
            kid.googleStatus = .expired
            return [.needsSignIn(source: "Google Classroom", detail: kid.firstName)]
        } catch {
            return []
        }
    }

    // MARK: School calendars

    /// Just the school calendars (used right after a link is added or changed).
    func refreshCalendarsOnly() async {
        let children = (try? context.fetch(FetchDescriptor<Child>())) ?? []
        _ = await refreshCalendars(children)
        try? context.save()
    }

    /// Import events from a calendar file the user picked (for districts that publish only a PDF
    /// or HTML page, with no subscribable feed). `feedKey` namespaces the events so a re-import
    /// updates rather than duplicates. Returns how many events were imported.
    @discardableResult
    func importCalendarText(_ text: String, feedKey: String, kidIDs: [UUID]) -> Int {
        guard text.contains("BEGIN:VCALENDAR") else { return 0 }
        var n = 0
        for e in ICSParser.parse(text) {
            let key = "\(feedKey)#\(e.uid)"
            let fetch = FetchDescriptor<SchoolEvent>(predicate: #Predicate { $0.key == key })
            if let existing = try? context.fetch(fetch).first {
                existing.title = DisplayTitle.proper(e.summary); existing.start = e.start; existing.end = e.end
                existing.childIDs = Array(Set(existing.childIDs + kidIDs))
            } else {
                context.insert(SchoolEvent(key: key, title: DisplayTitle.proper(e.summary), start: e.start, end: e.end,
                                           allDay: e.allDay, kind: ICSParser.kind(for: e.summary), childIDs: kidIDs))
            }
            n += 1
        }
        try? context.save()
        return n
    }

    func refreshCalendars(_ children: [Child]) async -> [Change] {
        var byFeed: [URL: [UUID]] = [:]
        for c in children { for u in c.allCalendarFeeds { byFeed[u, default: []].append(c.id) } }
        // The default district calendar (Millburn out of the box) applies to every kid, with no
        // setup, unless the parent turned it off or changed it in Settings.
        if let districtURL = DistrictDefault.feedURL, !children.isEmpty {
            byFeed[districtURL] = Array(Set((byFeed[districtURL] ?? []) + children.map(\.id)))
        }
        var changes: [Change] = []
        for (url, kidIDs) in byFeed {
            guard let response = try? await URLSession.shared.data(from: url),
                  let text = String(data: response.0, encoding: .utf8) else { continue }
            let horizon = Date.now.addingTimeInterval(-30 * 86_400)
            for e in ICSParser.parse(text) where e.start >= horizon {
                let key = "\(url.absoluteString)#\(e.uid)"
                let fetch = FetchDescriptor<SchoolEvent>(predicate: #Predicate { $0.key == key })
                let title = DisplayTitle.proper(e.summary)
                if let existing = try? context.fetch(fetch).first {
                    existing.title = title; existing.start = e.start; existing.end = e.end
                    existing.childIDs = Array(Set(existing.childIDs + kidIDs))
                } else {
                    let kind = ICSParser.kind(for: e.summary)
                    context.insert(SchoolEvent(key: key, title: title, start: e.start, end: e.end,
                                               allDay: e.allDay, kind: kind, childIDs: kidIDs))
                    if kind == .noSchool, e.start < .now.addingTimeInterval(14 * 86_400), e.start > .now {
                        changes.append(.dayOff(title: title, date: e.start))
                    }
                }
            }
        }
        dedupeEvents()
        await mergeDuplicateEventsWithAI()
        return changes
    }

    /// Collapse duplicate calendar events by content. Feeds (especially the district
    /// Thrillshare feed) can hand out unstable UIDs across fetches, and across app
    /// upgrades the same feed may be stored under slightly different URLs — either way
    /// the UID-based key changes and stale copies pile up. This pass guarantees the
    /// parent only ever sees one entry per real event, and cleans up any that already
    /// accumulated. Grouping is by normalized title + start-of-day + all-day flag.
    func dedupeEvents() {
        let all = (try? context.fetch(FetchDescriptor<SchoolEvent>())) ?? []
        let cal = Calendar.current
        // Re-case EVERY stored event (not just newly-synced ones) so titles are consistent
        // regardless of which build inserted them. Stale events from older builds, whose
        // feed UIDs changed and are no longer refreshed, get cleaned up here too.
        for e in all {
            let proper = DisplayTitle.proper(e.title)
            if proper != e.title { e.title = proper }
        }
        var keepers: [String: SchoolEvent] = [:]
        for e in all {
            let title = e.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "\u{2013}", with: "-")   // en-dash → hyphen
                .replacingOccurrences(of: "\u{2014}", with: "-")   // em-dash → hyphen
            let dayAnchor = e.allDay ? cal.startOfDay(for: e.start) : e.start
            let groupKey = "\(title)|\(Int(dayAnchor.timeIntervalSince1970))|\(e.allDay)"
            if let keep = keepers[groupKey] {
                // Merge this duplicate's kids into the survivor, then drop it.
                keep.childIDs = Array(Set(keep.childIDs + e.childIDs))
                context.delete(e)
            } else {
                keepers[groupKey] = e
            }
        }
    }
}
