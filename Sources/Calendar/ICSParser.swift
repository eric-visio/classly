import Foundation

/// Minimal iCalendar (RFC 5545) reader for school website calendar feeds.
/// Handles line folding, all-day DATE values, UTC and TZID DATE-TIME values.
enum ICSParser {
    struct Event: Equatable {
        var uid: String
        var summary: String
        var start: Date
        var end: Date?
        var allDay: Bool
    }

    static func parse(_ text: String) -> [Event] {
        // Unfold: a CRLF followed by space/tab continues the previous line.
        let unfolded = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n ", with: "").replacingOccurrences(of: "\n\t", with: "")
        var events: [Event] = []
        var cur: [String: (params: String, value: String)]?
        for line in unfolded.components(separatedBy: "\n") {
            if line == "BEGIN:VEVENT" { cur = [:]; continue }
            if line == "END:VEVENT" {
                if let c = cur, let s = c["DTSTART"], let parsed = date(s.value, params: s.params) {
                    let (start, allDay) = parsed
                    let end = c["DTEND"].flatMap { date($0.value, params: $0.params)?.0 }
                    events.append(Event(uid: c["UID"]?.value ?? "\(start.timeIntervalSince1970)-\(c["SUMMARY"]?.value ?? "")",
                                        summary: unescape(c["SUMMARY"]?.value ?? "Event"),
                                        start: start, end: end, allDay: allDay))
                }
                cur = nil; continue
            }
            guard cur != nil, let colon = line.firstIndex(of: ":") else { continue }
            let head = line[..<colon]; let value = String(line[line.index(after: colon)...])
            let name = head.split(separator: ";").first.map(String.init) ?? ""
            let params = head.split(separator: ";").dropFirst().joined(separator: ";")
            cur?[name] = (params, value)
        }
        return events
    }

    /// Classify a school event from its title.
    static func kind(for title: String) -> EventKind {
        let t = title.lowercased()
        if ["no school", "school closed", "closed", "holiday", "recess", "break", "vacation", "no classes"].contains(where: t.contains) { return .noSchool }
        if t.contains("early dismissal") || t.contains("half day") || t.contains("single session") || t.contains("delayed opening") { return .earlyDismissal }
        if t.contains("test") || t.contains("exam") || t.contains("assessment") { return .test }
        if t.contains("due") || t.contains("deadline") || t.contains("last day to") || t.contains("orders close") { return .deadline }
        return .event
    }

    private static func date(_ v: String, params: String) -> (Date, Bool)? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        if params.contains("VALUE=DATE") || v.count == 8 {
            f.dateFormat = "yyyyMMdd"; f.timeZone = .current
            return f.date(from: v).map { ($0, true) }
        }
        if v.hasSuffix("Z") {
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; f.timeZone = TimeZone(identifier: "UTC")
        } else {
            f.dateFormat = "yyyyMMdd'T'HHmmss"
            let tzid = params.split(separator: ";").first { $0.hasPrefix("TZID=") }.map { String($0.dropFirst(5)) }
            f.timeZone = tzid.flatMap(TimeZone.init(identifier:)) ?? .current
        }
        return f.date(from: v).map { ($0, false) }
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func normalizedFeedURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("webcal://") { s = "https://" + s.dropFirst("webcal://".count) }
        return URL(string: s)
    }
}
