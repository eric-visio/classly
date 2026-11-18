import Foundation

/// Read-only Google Classroom API client (v1) acting as the student ("me").
struct ClassroomClient {
    let accessToken: String
    var session: URLSession = .shared
    private let base = URL(string: "https://classroom.googleapis.com/v1/")!

    // MARK: API shapes (only the fields we use)

    struct Course: Decodable { let id: String; let name: String; let section: String?; let room: String?; let alternateLink: String? }
    struct DueDate: Decodable { let year: Int; let month: Int; let day: Int }
    struct DueTime: Decodable { let hours: Int?; let minutes: Int? }
    struct CourseWork: Decodable {
        let id: String; let courseId: String; let title: String
        let description: String?; let workType: String?; let maxPoints: Double?
        let dueDate: DueDate?; let dueTime: DueTime?; let alternateLink: String?; let state: String?
        /// Classroom gives due date/time in UTC.
        var due: Date? {
            guard let d = dueDate else { return nil }
            var c = DateComponents(); c.year = d.year; c.month = d.month; c.day = d.day
            c.hour = dueTime?.hours ?? 23; c.minute = dueTime?.minutes ?? 59
            c.timeZone = TimeZone(identifier: "UTC")
            return Calendar(identifier: .gregorian).date(from: c)
        }
    }
    struct Submission: Decodable {
        let courseWorkId: String; let state: String?; let late: Bool?
        let assignedGrade: Double?; let draftGrade: Double?
    }
    struct Announcement: Decodable { let id: String; let courseId: String; let text: String?; let updateTime: String? }

    /// One assignment joined with Maya's own submission.
    struct Item {
        let course: Course
        let work: CourseWork
        let submission: Submission?
        var isTurnedIn: Bool { ["TURNED_IN", "RETURNED"].contains(submission?.state ?? "") }
        /// Past due and not turned in. (Classroom has no explicit "missing" flag for students.)
        var isMissing: Bool { !isTurnedIn && (work.due.map { $0 < .now } ?? false) }
    }

    // MARK: Calls

    func activeCourses() async throws -> [Course] {
        struct R: Decodable { let courses: [Course]?; let nextPageToken: String? }
        return try await paged("courses", query: ["studentId": "me", "courseStates": "ACTIVE"]) { (r: R) in (r.courses ?? [], r.nextPageToken) }
    }

    func courseWork(courseID: String) async throws -> [CourseWork] {
        struct R: Decodable { let courseWork: [CourseWork]?; let nextPageToken: String? }
        return try await paged("courses/\(courseID)/courseWork", query: ["orderBy": "dueDate desc", "pageSize": "50"], maxPages: 2) {
            (r: R) in (r.courseWork ?? [], r.nextPageToken)
        }
    }

    func mySubmissions(courseID: String) async throws -> [Submission] {
        struct R: Decodable { let studentSubmissions: [Submission]?; let nextPageToken: String? }
        return try await paged("courses/\(courseID)/courseWork/-/studentSubmissions", query: ["userId": "me", "pageSize": "100"], maxPages: 3) {
            (r: R) in (r.studentSubmissions ?? [], r.nextPageToken)
        }
    }

    func recentAnnouncements(courseID: String) async throws -> [Announcement] {
        struct R: Decodable { let announcements: [Announcement]?; let nextPageToken: String? }
        return try await paged("courses/\(courseID)/announcements", query: ["pageSize": "10"], maxPages: 1) {
            (r: R) in (r.announcements ?? [], r.nextPageToken)
        }
    }

    /// All assignments across active classes with the student's submission state.
    func allItems() async throws -> [Item] {
        let courses = try await activeCourses()
        return try await withThrowingTaskGroup(of: [Item].self) { group in
            for course in courses {
                group.addTask {
                    async let work = courseWork(courseID: course.id)
                    async let subs = mySubmissions(courseID: course.id)
                    let byWork = Dictionary((try await subs).map { ($0.courseWorkId, $0) }, uniquingKeysWith: { a, _ in a })
                    return try await work.map { Item(course: course, work: $0, submission: byWork[$0.id]) }
                }
            }
            return try await group.reduce(into: []) { $0 += $1 }
        }
    }

    // MARK: Plumbing

    private func paged<R: Decodable, T>(_ path: String, query: [String: String], maxPages: Int = 5,
                                         extract: (R) -> ([T], String?)) async throws -> [T] {
        var out: [T] = []; var token: String?
        for _ in 0..<maxPages {
            var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } + (token.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            var req = URLRequest(url: c.url!)
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { throw ClassroomError.unauthorized }
            if code == 403 { throw ClassroomError.forbidden(String(data: data, encoding: .utf8) ?? "") }
            guard code == 200 else { throw ClassroomError.http(code) }
            let (items, next) = extract(try JSONDecoder().decode(R.self, from: data))
            out += items; token = next
            if token == nil { break }
        }
        return out
    }

    enum ClassroomError: Error { case unauthorized, forbidden(String), http(Int) }
}
