import Foundation

/// A batch of coursework the Safari extension scraped from the Classroom "To-do" page.
/// Covers every class at once, so each item carries its own course. Shared by the app and the
/// extension target, and staged as JSON in the App Group container.
struct ClassroomWebSnapshot: Codable {
    struct Item: Codable {
        let courseId: String
        let courseName: String
        let id: String
        let title: String
        let url: URL
        let dueText: String?
        /// Which Classroom list this came from: "turned-in" (Done) or "not-turned-in"
        /// (Assigned/Missing). Optional so older snapshots still decode.
        var status: String? = nil
        /// The visible status word scraped from the row, if any ("Missing", "Done late"…).
        var statusLabel: String? = nil
        var late: Bool? = nil
    }

    let items: [Item]

    static func inbox() throws -> URL {
        guard let folder = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.visiocapital.classly"
        ) else { throw CocoaError(.fileNoSuchFile) }
        let inbox = folder.appendingPathComponent("ClassroomInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var directory = inbox
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return inbox
    }

    private static let idPattern = "^[A-Za-z0-9_=-]{1,256}$"

    var isValid: Bool {
        guard !items.isEmpty, items.count <= 2000 else { return false }
        return items.allSatisfy { item in
            item.courseId.range(of: Self.idPattern, options: .regularExpression) != nil &&
            item.id.range(of: Self.idPattern, options: .regularExpression) != nil &&
            !item.title.isEmpty && item.title.count <= 1000 &&
            !item.courseName.isEmpty && item.courseName.count <= 500 &&
            (item.dueText?.count ?? 0) <= 300 &&
            (item.status?.count ?? 0) <= 40 &&
            (item.statusLabel?.count ?? 0) <= 80 &&
            item.url.scheme == "https" && item.url.host == "classroom.google.com"
        }
    }

    /// Items grouped by course, for upserting per class.
    var byCourse: [(courseId: String, courseName: String, items: [Item])] {
        var order: [String] = []
        var map: [String: (String, [Item])] = [:]
        for it in items {
            if map[it.courseId] == nil { order.append(it.courseId); map[it.courseId] = (it.courseName, []) }
            map[it.courseId]?.1.append(it)
        }
        return order.map { (courseId: $0, courseName: map[$0]!.0, items: map[$0]!.1) }
    }
}
