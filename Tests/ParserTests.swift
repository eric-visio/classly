import XCTest
@testable import Classly

/// Synthetic fixtures shaped like the stock PowerSchool parent portal. Replace / add real saved
/// pages from your district (Settings › Developer › Save portal pages) under Tests/Fixtures and
/// add a test per district so layout differences are caught.
final class ParserTests: XCTestCase {
    let base = URL(string: "https://demo.powerschool.com/")!

    let home = """
    <html><body>
    <ul id="students-list">
      <li class="selected"><a href="javascript:switchStudent(1111);">Chen, Maya</a></li>
      <li><a href="javascript:switchStudent(2222);">Chen, Leo</a></li>
    </ul>
    <h1>Grades and Attendance: Chen, Maya</h1>
    <table class="linkDescList grid">
      <tr><th rowspan="2">Exp</th><th colspan="5">Last Week</th><th colspan="5">This Week</th><th rowspan="2">Course</th>
          <th rowspan="2">Q1</th><th rowspan="2">Q2</th><th rowspan="2">Absences</th><th rowspan="2">Tardies</th></tr>
      <tr><th>M</th><th>T</th><th>W</th><th>H</th><th>F</th><th>M</th><th>T</th><th>W</th><th>H</th><th>F</th></tr>
      <tr><td>1(A)</td><td></td><td></td><td></td><td></td><td></td><td></td><td>T</td><td></td><td></td><td></td>
          <td>Math 7 <br><a href="mailto:patel@x.org">Email Patel, Raj</a> - Rm: 214</td>
          <td><a href="scores.html?frn=00412345&amp;fg=Q1">A 94</a></td><td><a href="scores.html?frn=00412345&amp;fg=Q2">A- 91</a></td>
          <td>0</td><td>1</td></tr>
      <tr><td>3(A)</td><td></td><td>E</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td>
          <td>Life Science <br><a href="mailto:kim@x.org">Email Kim, Dana</a> - Rm: 108</td>
          <td><a href="scores.html?frn=00499999&amp;fg=Q1">B+ 88</a></td><td><a href="scores.html?frn=00499999&amp;fg=Q2">[ i ]</a></td>
          <td>1</td><td>0</td></tr>
      <tr><td colspan="11"></td><td>Attendance Totals</td><td></td><td></td><td>1</td><td>1</td></tr>
    </table>
    <p>Attendance Codes: A Absent Unexcused E Absent Excused T Tardy</p>
    </body></html>
    """

    let scores = """
    <table><tr><th>Due Date</th><th>Category</th><th>Assignment</th><th><img alt="Collected"></th><th><img alt="Late"></th>
      <th><img alt="Missing"></th><th><img alt="Exempt"></th><th>Score</th><th>%</th><th>Grade</th></tr>
    <tr><td>11/03/2026</td><td>Quizzes</td><td>Quiz 5 - Mitosis</td><td></td><td></td><td></td><td></td><td>14/20</td><td>70</td><td>C-</td></tr>
    <tr><td>10/30/2026</td><td>Labs</td><td>Cell Structure lab</td><td></td><td></td><td><img src="missing.gif"></td><td></td><td>--/40</td><td></td><td>--</td></tr>
    </table>
    """

    func testStudents() {
        let s = PortalParsers.students(homeHTML: home)
        XCTAssertEqual(s, [PortalStudent(id: "1111", name: "Chen, Maya"), PortalStudent(id: "2222", name: "Chen, Leo")])
        XCTAssertEqual(PowerSchoolStep.firstName("Chen, Maya"), "Maya")
    }

    func testCourses() {
        let c = PortalParsers.courses(homeHTML: home, baseURL: base)
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c[0].name, "Math 7")
        XCTAssertEqual(c[0].teacher, "Patel, Raj")
        XCTAssertEqual(c[0].teacherEmail, "patel@x.org")
        XCTAssertEqual(c[0].room, "214")
        XCTAssertEqual(c[0].key, "00412345")
        XCTAssertEqual(c[0].currentGrade?.term, "Q2")
        XCTAssertEqual(c[0].currentGrade?.letter, "A-")
        XCTAssertEqual(c[0].currentGrade?.percent, 91)
        XCTAssertTrue(c[0].currentGrade?.scoresURL?.absoluteString.contains("/guardian/scores.html") ?? false)
        XCTAssertEqual(c[0].tardies, 1)
        // Q2 is "[ i ]" (no grade yet) for Science, so the current grade falls back to Q1.
        XCTAssertEqual(c[1].currentGrade?.term, "Q1")
        XCTAssertEqual(c[1].absences, 1)
        XCTAssertTrue(c[0].recentDayCodes.contains { $0.header == "This Week T" && $0.code == "T" })
    }

    func testAssignments() {
        let a = PortalParsers.assignments(scoresHTML: scores)
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(a[0].earned, 14); XCTAssertEqual(a[0].possible, 20); XCTAssertFalse(a[0].missing)
        XCTAssertTrue(a[1].missing); XCTAssertNil(a[1].earned); XCTAssertEqual(a[1].possible, 40)
    }

    func testAttendanceLegend() {
        let l = AttendanceCodes.legend(homeHTML: home)
        XCTAssertEqual(l["E"], .absentExcused)
        XCTAssertEqual(l["A"], .absentUnexcused)
        XCTAssertEqual(l["T"], .tardy)
    }

    func testICS() {
        let ics = """
        BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:abc\r\nDTSTART;VALUE=DATE:20261111\r\nSUMMARY:No School - Veterans\r\n  Day\r\nEND:VEVENT\r\n\
        BEGIN:VEVENT\r\nUID:def\r\nDTSTART;TZID=America/New_York:20261119T123000\r\nSUMMARY:Early Dismissal\\, Conferences\r\nEND:VEVENT\r\nEND:VCALENDAR
        """
        let e = ICSParser.parse(ics)
        XCTAssertEqual(e.count, 2)
        XCTAssertTrue(e[0].allDay)
        XCTAssertEqual(e[0].summary, "No School - Veterans Day")
        XCTAssertEqual(ICSParser.kind(for: e[0].summary), .noSchool)
        XCTAssertEqual(ICSParser.kind(for: e[1].summary), .earlyDismissal)
        XCTAssertEqual(ICSParser.normalizedFeedURL("webcal://x.org/cal.ics")?.scheme, "https")
    }

    func testURLNormalize() {
        XCTAssertEqual(SchoolStep.normalize("Demo.PowerSchool.com/public/home.html")?.absoluteString, "https://demo.powerschool.com/")
        XCTAssertNil(SchoolStep.normalize("not a url"))
    }

    @MainActor
    func testApplySnapshotCreatesMissingAndAttendance() throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let kid = Child(firstName: "Maya", colorHex: "2D5BE3", sortOrder: 0)
        ctx.insert(kid)
        let courses = PortalParsers.courses(homeHTML: home, baseURL: base)
        var snap = PortalSnapshot(studentID: "1111", studentName: nil, courses: courses,
                                  assignmentsByCourseKey: ["00499999": PortalParsers.assignments(scoresHTML: scores)],
                                  attendanceLegend: AttendanceCodes.legend(homeHTML: home))
        // Thursday Nov 5 2026: "This Week T" = Tue Nov 3, "Last Week T" = Tue Oct 27.
        let today = DateComponents(calendar: .current, year: 2026, month: 11, day: 5, hour: 9).date!
        let changes = SyncEngine(context: ctx).apply(snap, to: kid, today: today)
        XCTAssertTrue(changes.contains(.newMissing(child: "Maya", course: "Life Science", title: "Cell Structure lab")))
        XCTAssertEqual(kid.attendance.count, 2)
        // A second identical refresh produces no repeat notifications.
        snap.studentName = "Chen, Maya"
        XCTAssertTrue(SyncEngine(context: ctx).apply(snap, to: kid, today: today).isEmpty)
    }
}

final class ClassroomImportTests: XCTestCase {
    private func now() -> Date { DateComponents(calendar: .current, year: 2026, month: 11, day: 6, hour: 10).date! }

    func testDueParsing() {
        let n = now()
        func d(_ s: String?) -> Date? { ClassroomDueParser.date(from: s, now: n) }
        XCTAssertNil(d("No due date"))
        XCTAssertNil(d(nil))
        let today = d("Due Today, 11:59 PM")!
        XCTAssertTrue(Calendar.current.isDate(today, inSameDayAs: n))
        XCTAssertEqual(Calendar.current.component(.hour, from: today), 23)
        let tomorrow = d("Due Tomorrow")!
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: n, to: tomorrow).day, 1)
        let nov7 = d("Due Nov 7")!
        let c = Calendar.current.dateComponents([.year, .month, .day], from: nov7)
        XCTAssertEqual(c.month, 11); XCTAssertEqual(c.day, 7); XCTAssertEqual(c.year, 2026)
        // A January date seen in November should resolve to the coming January, not last.
        let jan = d("Due Jan 5")!
        XCTAssertEqual(Calendar.current.component(.year, from: jan), 2027)
    }

    @MainActor
    func testImportUpsertAndPrune() throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let kid = Child(firstName: "Evelyn", colorHex: "2D5BE3", sortOrder: 0)
        ctx.insert(kid)
        let snap1 = ClassroomWebSnapshot(items: [
            .init(courseId: "sci", courseName: "8B Science", id: "a1", title: "Viruses quiz",
                  url: URL(string: "https://classroom.google.com/c/sci/a/a1")!, dueText: "Due Nov 7"),
            .init(courseId: "ss", courseName: "Social Studies", id: "a2", title: "Mesopotamia",
                  url: URL(string: "https://classroom.google.com/c/ss/a/a2")!, dueText: "No due date"),
        ])
        XCTAssertTrue(snap1.isValid)
        _ = ClassroomImporter.apply(snap1, to: kid, context: ctx, now: now())
        XCTAssertEqual(kid.assignments.filter { $0.key.hasPrefix("gc-web:") }.count, 2)
        XCTAssertNotNil(kid.assignments.first { $0.title == "Viruses quiz" }?.dueDate)

        // Second sync: a2 turned in (gone from To-do), a3 added. Prune a2, keep a1, add a3.
        let snap2 = ClassroomWebSnapshot(items: [
            .init(courseId: "sci", courseName: "8B Science", id: "a1", title: "Viruses quiz",
                  url: URL(string: "https://classroom.google.com/c/sci/a/a1")!, dueText: "Due Nov 7"),
            .init(courseId: "sci", courseName: "8B Science", id: "a3", title: "Lab report",
                  url: URL(string: "https://classroom.google.com/c/sci/a/a3")!, dueText: "Due Nov 10"),
        ])
        _ = ClassroomImporter.apply(snap2, to: kid, context: ctx, now: now())
        let titles = Set(kid.assignments.filter { $0.key.hasPrefix("gc-web:") }.map(\.title))
        XCTAssertEqual(titles, ["Viruses quiz", "Lab report"])
    }

    @MainActor
    func testClassroomStatusMapping() throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let kid = Child(firstName: "Theo", colorHex: "2D5BE3", sortOrder: 0)
        ctx.insert(kid)
        let snap = ClassroomWebSnapshot(items: [
            .init(courseId: "m", courseName: "Math", id: "u1", title: "Upcoming pset",
                  url: URL(string: "https://classroom.google.com/c/m/a/u1")!, dueText: "Due Nov 30",
                  status: "not-turned-in", statusLabel: "Assigned", late: false),
            .init(courseId: "m", courseName: "Math", id: "x1", title: "Overdue pset",
                  url: URL(string: "https://classroom.google.com/c/m/a/x1")!, dueText: "Due Nov 1",
                  status: "not-turned-in", statusLabel: "Missing", late: false),
            .init(courseId: "e", courseName: "English", id: "d1", title: "Essay",
                  url: URL(string: "https://classroom.google.com/c/e/a/d1")!, dueText: "Due Nov 1",
                  status: "turned-in", statusLabel: "Done late", late: true),
        ])
        XCTAssertTrue(snap.isValid)
        _ = ClassroomImporter.apply(snap, to: kid, context: ctx, now: now())

        // Classroom contributes upcoming + done only; PowerSchool owns missing/late, so Classroom
        // items are never flagged missing or late.
        let up = kid.assignments.first { $0.title == "Upcoming pset" }!
        XCTAssertFalse(up.isTurnedIn); XCTAssertFalse(up.isMissing)
        let miss = kid.assignments.first { $0.title == "Overdue pset" }!
        XCTAssertFalse(miss.isMissing); XCTAssertFalse(miss.isTurnedIn)
        let done = kid.assignments.first { $0.title == "Essay" }!
        XCTAssertTrue(done.isTurnedIn); XCTAssertFalse(done.isMissing); XCTAssertFalse(done.isLate)
    }
}

final class ModernScoresTests: XCTestCase {
    let html = """
    <table id="scoreTable"><thead><tr><th>Due Date</th><th>Category</th><th>Assignment</th>
    <th colspan="7">Flags</th><th>Score</th><th>%</th><th>Grade</th><th>Comments</th></tr></thead><tbody>
    <tr id="assignmentsection_1"><td class="ng-binding">11/03/2026</td>
    <td class="categorycol"><span class="psonly">Classwork</span></td>
    <td class="assignmentcol"><span>Journal Check</span></td>
    <td class="codeCol"><span class="screen_readers_only">collected</span></td>
    <td class="codeCol"><span class="screen_readers_only">late</span></td>
    <td class="codeCol"><span class="screen_readers_only">missing</span></td>
    <td class="codeCol"><span class="screen_readers_only">exempt from final grade</span></td>
    <td class="codeCol"><span class="screen_readers_only">absent</span></td>
    <td class="codeCol"><span class="screen_readers_only">incomplete</span></td>
    <td class="codeCol"><span class="screen_readers_only">excluded from final grade</span></td>
    <td class="score">21/25</td><td>84</td><td>B</td><td></td></tr>
    <tr id="assignmentsection_2"><td class="ng-binding">11/10/2026</td>
    <td class="categorycol"><span class="psonly">Homework</span></td>
    <td class="assignmentcol"><span>IXL: Capitalization</span></td>
    <td class="codeCol"><span class="screen_readers_only">collected</span></td>
    <td class="codeCol"><span class="screen_readers_only">late</span></td>
    <td class="codeCol"><span class="screen_readers_only">missing</span><em class="ps-icon ps-flag"></em></td>
    <td class="codeCol"><span class="screen_readers_only">exempt from final grade</span></td>
    <td class="codeCol"><span class="screen_readers_only">absent</span></td>
    <td class="codeCol"><span class="screen_readers_only">incomplete</span></td>
    <td class="codeCol"><span class="screen_readers_only">excluded from final grade</span></td>
    <td class="score">--/10</td><td></td><td></td><td></td></tr>
    </tbody></table>
    """

    func testModernScores() {
        let a = PortalParsers.assignments(scoresHTML: html)
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(a[0].title, "Journal Check")
        XCTAssertEqual(a[0].category, "Classwork")
        XCTAssertEqual(a[0].earned, 21); XCTAssertEqual(a[0].possible, 25)
        XCTAssertEqual(a[0].letter, "B")
        XCTAssertFalse(a[0].missing)
        XCTAssertEqual(a[1].title, "IXL: Capitalization")
        XCTAssertEqual(a[1].category, "Homework")
        XCTAssertNil(a[1].earned); XCTAssertEqual(a[1].possible, 10)
        XCTAssertTrue(a[1].missing)   // the <em> icon makes the flag active
        XCTAssertNil(a[1].letter)
    }
}

final class ThrillshareFeedTests: XCTestCase {
    func testBuildsDistrictEventsFeedFromOrgId() {
        let html = """
        <html><head><link href="https://cmsv2-assets.apptegy.net/uploads/18140/logo/x.png"></head>
        <body data-site="thrillshare"><a href="/o/18140/page/district-calendars">District Calendars</a></body></html>
        """
        let base = URL(string: "https://millburntownshippsnj.sites.thrillshare.com/o/mtps/page/district-calendars")!
        let feeds = CalendarFeed.thrillshareFeeds(inHTML: html, base: base)
        XCTAssertEqual(feeds.first?.absoluteString,
            "https://thrillshare-cmsv2.services.thrillshare.com/api/v4/o/18140/cms/events/generate_ical")
    }

    func testIgnoresNonThrillshareSites() {
        let html = "<html><body><a href=\"/o/18140/\">x</a></body></html>"
        let base = URL(string: "https://example.org/calendar")!
        XCTAssertTrue(CalendarFeed.thrillshareFeeds(inHTML: html, base: base).isEmpty)
    }
}
