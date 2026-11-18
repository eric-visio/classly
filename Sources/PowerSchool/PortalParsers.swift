import Foundation
import SwiftSoup

// Parsers for the PowerSchool parent portal pages.
//
// Districts can relabel columns and reorder tables, so these parsers find tables by their
// header text instead of fixed CSS paths. Every parser has fixture tests in Tests/; when a
// district's layout differs, add its saved page as a fixture and adjust here.

struct PortalStudent: Equatable { var id: String; var name: String }

struct PortalTermGrade: Equatable {
    var term: String          // header text, e.g. "Q1", "S1"
    var letter: String?
    var percent: Double?
    var scoresURL: URL?       // link to the class score detail page
}

struct PortalCourse: Equatable {
    var key: String           // stable id: section id from the scores link, else name+period
    var name: String
    var teacher: String?
    var teacherEmail: String?
    var period: String?
    var room: String?
    var terms: [PortalTermGrade]
    var absences: Int
    var tardies: Int
    /// Attendance codes shown for the last two weeks, oldest first (e.g. ["", "T", "", "A", ...]).
    var recentDayCodes: [(header: String, code: String)]

    static func == (l: PortalCourse, r: PortalCourse) -> Bool {
        l.key == r.key && l.name == r.name && l.terms == r.terms && l.absences == r.absences && l.tardies == r.tardies
    }

    /// The grade for the term currently in progress = right-most term column with a grade.
    var currentGrade: PortalTermGrade? { terms.last { $0.letter != nil || $0.percent != nil } }
}

struct PortalAssignment: Equatable {
    var dueDate: Date?
    var category: String?
    var title: String
    var earned: Double?
    var possible: Double?
    var letter: String?
    var missing = false, late = false, exempt = false, collected = false
}

enum PortalParsers {

    // MARK: Students on the parent account

    static func students(homeHTML: String) -> [PortalStudent] {
        guard let doc = try? SwiftSoup.parse(homeHTML) else { return [] }
        var out: [PortalStudent] = []
        let links = (try? doc.select("#students-list a, a[href*=switchStudent], a[onclick*=switchStudent]").array()) ?? []
        for a in links {
            let attr = ((try? a.attr("href")) ?? "") + ((try? a.attr("onclick")) ?? "")
            guard let id = firstMatch(#"switchStudent\((\d+)\)"#, in: attr) else { continue }
            let name = ((try? a.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.contains(where: { $0.id == id }) { out.append(PortalStudent(id: id, name: name)) }
        }
        return out
    }

    /// Name of the student whose data the page currently shows.
    static func selectedStudentName(homeHTML: String) -> String? {
        guard let doc = try? SwiftSoup.parse(homeHTML) else { return nil }
        if let sel = try? doc.select("#students-list li.selected a").first()?.text(), !sel.isEmpty { return sel }
        if let h1 = try? doc.select("h1").first()?.text() {
            // Stock heading reads "Grades and Attendance: Lastname, Firstname"
            return h1.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: Grades and Attendance (guardian/home.html)

    static func courses(homeHTML: String, baseURL: URL) -> [PortalCourse] {
        // The grade links are relative ("scores.html?…") and the page lives at /guardian/home.html,
        // so resolve against that path — not the site root, which would drop "/guardian/" and 404.
        let docBase = baseURL.appendingPathComponent("guardian/home.html").absoluteString
        guard let doc = try? SwiftSoup.parse(homeHTML, docBase),
              let table = (try? doc.select("table").array())?.first(where: { t in
                  let text = ((try? t.select("th").text()) ?? "").lowercased()
                  return text.contains("course") && (text.contains("absences") || text.contains("tardies"))
              })
        else { return [] }

        let rows = (try? table.select("tr").array()) ?? []
        // Header rows are the rows made of <th>. Expand colspans so indexes line up with data cells.
        let headerRows = rows.filter { ((try? $0.select("td").size()) ?? 0) == 0 && ((try? $0.select("th").size()) ?? 0) > 0 }
        guard let main = headerRows.first(where: { ((try? $0.text()) ?? "").lowercased().contains("course") }) else { return [] }
        var headers = expandedHeaders(main)
        // A second header row (M T W H F under "Last Week"/"This Week") refines the day columns.
        if let dayRow = headerRows.first(where: { $0 !== main }) {
            let days = expandedHeaders(dayRow)
            var di = 0
            for i in headers.indices where isWeekHeader(headers[i]) && di < days.count {
                headers[i] = headers[i] + " " + days[di]; di += 1
            }
        }
        let lower = headers.map { $0.lowercased() }
        guard let courseIdx = lower.firstIndex(where: { $0.contains("course") }) else { return [] }
        let absIdx = lower.firstIndex(where: { $0.contains("absences") })
        let tarIdx = lower.firstIndex(where: { $0.contains("tardies") })
        let expIdx = lower.firstIndex(where: { $0 == "exp" || $0.contains("period") })
        let dayIdxs = headers.indices.filter { isWeekHeader(headers[$0]) }
        let termIdxs = headers.indices.filter { i in
            i > courseIdx && i != absIdx && i != tarIdx && looksLikeTerm(headers[i])
        }

        var out: [PortalCourse] = []
        for row in rows {
            let cells = tds(row)
            guard cells.count > courseIdx else { continue }
            let courseCell = cells[courseIdx]
            let (name, teacher, room, email) = splitCourseCell(courseCell)
            guard !name.isEmpty, !name.lowercased().hasPrefix("attendance totals") else { continue }

            var terms: [PortalTermGrade] = []
            for i in termIdxs where i < cells.count {
                let cell = cells[i]
                let link = try? cell.select("a").first()
                let hrefString: String? = link.flatMap { try? $0.absUrl("href") }
                let href = hrefString.flatMap { $0.isEmpty ? nil : URL(string: $0) }
                let (letter, pct) = parseGradeCell((try? cell.text()) ?? "")
                terms.append(PortalTermGrade(term: headers[i], letter: letter, percent: pct, scoresURL: href))
            }
            let key = terms.compactMap { $0.scoresURL.flatMap { queryValue("frn", in: $0) } }.first
                ?? "\(name)|\(expIdx.flatMap { cells.indices.contains($0) ? (try? cells[$0].text()) : nil } ?? "")"

            out.append(PortalCourse(
                key: key, name: name, teacher: teacher, teacherEmail: email,
                period: expIdx.flatMap { cells.indices.contains($0) ? (try? cells[$0].text()) : nil },
                room: room, terms: terms,
                absences: absIdx.flatMap { cells.indices.contains($0) ? Int((try? cells[$0].text()) ?? "") : nil } ?? 0,
                tardies: tarIdx.flatMap { cells.indices.contains($0) ? Int((try? cells[$0].text()) ?? "") : nil } ?? 0,
                recentDayCodes: dayIdxs.compactMap { i in
                    guard i < cells.count else { return nil }
                    return (headers[i], ((try? cells[i].text()) ?? "").trimmingCharacters(in: .whitespaces))
                }))
        }
        return out
    }

    // MARK: Class score detail (guardian/scores.html)

    static func assignments(scoresHTML: String) -> [PortalAssignment] {
        guard let doc = try? SwiftSoup.parse(scoresHTML) else { return [] }
        // Modern PowerSchool (Angular): each assignment is a <tr id="assignmentsection_…"> with
        // class-tagged cells. This is Millburn's layout. Fall back to the legacy table otherwise.
        if let rows = try? doc.select("tr[id^=assignmentsection_]"), rows.size() > 0 {
            return parseModernAssignments(rows)
        }
        return parseLegacyAssignments(doc)
    }

    /// Modern Angular scores table. Columns are identified by class, not header position:
    /// td[0]=Due Date, td.categorycol, td.assignmentcol, 7× td.codeCol (flags), td.score, then
    /// percent and letter grade in the trailing cells.
    static func parseModernAssignments(_ rows: Elements) -> [PortalAssignment] {
        var out: [PortalAssignment] = []
        for row in rows.array() {
            let title = ((try? row.select("td.assignmentcol").first()?.text()) ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            var a = PortalAssignment(title: title)

            let tds = tds(row)
            a.dueDate = parseDate((try? tds.first?.text()) ?? "")
            let cat = ((try? row.select("td.categorycol").first()?.text()) ?? "").trimmingCharacters(in: .whitespaces)
            a.category = cat.isEmpty ? nil : cat

            if let scoreCell = try? row.select("td.score").first() {
                (a.earned, a.possible) = parseScore((try? scoreCell.text()) ?? "")
                // The letter grade is the first A–F token in the cells after the score.
                if let idx = tds.firstIndex(where: { $0 === scoreCell }) {
                    for cell in tds[(idx + 1)...] {
                        let t = ((try? cell.text()) ?? "").trimmingCharacters(in: .whitespaces)
                        if firstMatch(#"^[A-F][+\-]?$"#, in: t) != nil { a.letter = t; break }
                    }
                }
            }

            // A flag cell holds only a screen-reader label until it's active, when an icon element
            // is added — so "active" = more than one child node. The label says which flag it is.
            for cc in ((try? row.select("td.codeCol").array()) ?? []) {
                guard ((try? cc.children().size()) ?? 0) > 1 else { continue }
                let label = ((try? cc.select("span.screen_readers_only").text()) ?? "").lowercased()
                if label.contains("collected") { a.collected = true }
                else if label.contains("late") { a.late = true }
                else if label.contains("missing") { a.missing = true }
                else if label.contains("exempt") { a.exempt = true }
            }
            out.append(a)
        }
        return out
    }

    static func parseLegacyAssignments(_ doc: Document) -> [PortalAssignment] {
        guard let table = (try? doc.select("table").array())?.first(where: { t in
                  let text = ((try? t.select("th").text()) ?? "").lowercased()
                  return text.contains("assignment") && text.contains("score")
              })
        else { return [] }

        let headerCells = (try? table.select("tr").first()?.select("th").array()) ?? []
        // Flag columns are often icons: read alt/title as well as text.
        let headers: [String] = headerCells.map { th in
            let t = ((try? th.text()) ?? "")
            let alt = ((try? th.select("img").attr("alt")) ?? "") + ((try? th.attr("title")) ?? "")
            return (t.isEmpty ? alt : t).lowercased()
        }
        func idx(_ needle: String) -> Int? { headers.firstIndex { $0.contains(needle) } }
        let dueIdx = idx("due"), catIdx = idx("category"), nameIdx = idx("assignment")
        let scoreIdx = idx("score"), gradeIdx = headers.lastIndex { $0 == "grade" || $0.hasSuffix("grade") }
        let flagIdx: [String: Int] = ["missing", "late", "exempt", "collected"]
            .reduce(into: [:]) { d, f in if let i = idx(f) { d[f] = i } }

        var out: [PortalAssignment] = []
        for row in ((try? table.select("tr").array()) ?? []).dropFirst() {
            let cells = tds(row)
            guard let nameIdx, cells.count > nameIdx else { continue }
            let title = ((try? cells[nameIdx].text()) ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            var a = PortalAssignment(title: title)
            if let i = dueIdx, i < cells.count { a.dueDate = parseDate((try? cells[i].text()) ?? "") }
            if let i = catIdx, i < cells.count { a.category = (try? cells[i].text()).flatMap { $0.isEmpty ? nil : $0 } }
            if let i = scoreIdx, i < cells.count { (a.earned, a.possible) = parseScore((try? cells[i].text()) ?? "") }
            if let i = gradeIdx, i < cells.count { a.letter = (try? cells[i].text()).flatMap { $0.isEmpty || $0 == "--" ? nil : $0 } }
            func flagged(_ f: String) -> Bool {
                guard let i = flagIdx[f], i < cells.count else {
                    // Newer portals mark flags with icon classes anywhere in the row.
                    return ((try? row.select("[class*=\(f)]").size()) ?? 0) > 0
                }
                let c = cells[i]
                let text = ((try? c.text()) ?? "").trimmingCharacters(in: .whitespaces)
                return !text.isEmpty || ((try? c.select("img, div, span, i").size()) ?? 0) > 0
            }
            a.missing = flagged("missing"); a.late = flagged("late")
            a.exempt = flagged("exempt"); a.collected = flagged("collected")
            out.append(a)
        }
        return out
    }

    // MARK: Helpers (internal for tests)

    static func parseGradeCell(_ raw: String) -> (String?, Double?) {
        // Typical cell text: "A- 92", "B+ 88.5", "[ i ]", "--", "92"
        let t = raw.replacingOccurrences(of: "\u{00a0}", with: " ").trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.contains("[ i ]") || t == "--" { return (nil, nil) }
        let letter = firstMatch(#"^([A-F][+\-−]?|P|NP|E|S|N|U)(?=\s|$)"#, in: t)
        let pct = firstMatch(#"(\d{1,3}(?:\.\d+)?)"#, in: t).flatMap(Double.init)
        return (letter, pct)
    }

    static func parseScore(_ raw: String) -> (Double?, Double?) {
        // "8/10", "8 / 10", "--/10", "8.5/10"
        let parts = raw.replacingOccurrences(of: " ", with: "").split(separator: "/")
        guard parts.count == 2 else { return (nil, nil) }
        return (Double(parts[0]), Double(parts[1]))
    }

    static func parseDate(_ raw: String, now: Date = .now) -> Date? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["MM/dd/yyyy", "M/d/yyyy", "yyyy-MM-dd", "MM/dd/yy"] {
            f.dateFormat = fmt
            if let d = f.date(from: t) { return d }
        }
        f.dateFormat = "M/d"
        if let d = f.date(from: t) {
            var c = Calendar.current.dateComponents([.month, .day], from: d)
            c.year = Calendar.current.component(.year, from: now)
            return Calendar.current.date(from: c)
        }
        return nil
    }

    private static func splitCourseCell(_ cell: Element) -> (name: String, teacher: String?, room: String?, email: String?) {
        // Stock cell: "Math 7 <br> <a href=mailto:patel@x.org>Email Patel, Raj</a> - Rm: 214"
        let link = try? cell.select("a[href^=mailto]").first()
        let teacher = (try? link?.text())?.replacingOccurrences(of: "Email ", with: "")
        let email = (try? link?.attr("href"))?.replacingOccurrences(of: "mailto:", with: "")
            .components(separatedBy: "?").first?.trimmingCharacters(in: .whitespaces)
        let full = (try? cell.text()) ?? ""
        var name = full
        if let t = try? link?.text(), let r = full.range(of: t) {
            name = String(full[..<r.lowerBound])
        }
        let room = firstMatch(#"Rm:\s*([\w\-]+)"#, in: full)
        return (name.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "-"))),
                teacher, room, email?.isEmpty == false ? email : nil)
    }

    /// Direct <td> children of a row (not cells of nested tables).
    private static func tds(_ row: Element) -> [Element] {
        row.children().array().filter { $0.tagName() == "td" }
    }

    private static func expandedHeaders(_ row: Element) -> [String] {
        ((try? row.select("th").array()) ?? []).flatMap { th -> [String] in
            let span = Int((try? th.attr("colspan")) ?? "") ?? 1
            let text = ((try? th.text()) ?? "").trimmingCharacters(in: .whitespaces)
            return Array(repeating: text, count: max(1, span))
        }
    }

    private static func isWeekHeader(_ h: String) -> Bool {
        let l = h.lowercased(); return l.hasPrefix("last week") || l.hasPrefix("this week")
    }

    private static func looksLikeTerm(_ h: String) -> Bool {
        // Q1..Q4, S1/S2, T1..T3, F1, Y1, E1, "P1" progress periods, etc.
        firstMatch(#"^([QSTPFYEMR]\d|Year|Final)$"#, in: h.trimmingCharacters(in: .whitespaces)) != nil
    }

    static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        let r = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
        return Range(r, in: s).map { String(s[$0]) }
    }

    private static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}
