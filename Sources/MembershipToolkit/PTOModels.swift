import Foundation
import SwiftData

/// The family's connection to a Membership Toolkit PTO site (e.g. the middle-school PTO).
/// One per device. The parent signs in once; we keep the session cookies in the Keychain and
/// the discovered *public* calendar feed URL so the daily sync needs no further login for the
/// calendar. Newsletter discovery reuses the cookies and re-prompts if the session expires.
@Model
final class PTOAccount {
    @Attribute(.unique) var id: String          // always "pto" — single instance
    var host: String                            // e.g. millburnmspto.membershiptoolkit.com
    var displayName: String                     // e.g. "Millburn MS PTO"
    /// The main parent calendar's webcal/ICS subscription feed (cookieless, so sync needs no login).
    var calendarFeedURLString: String?
    /// Newsletter list pages to scrape, one per grade the parent picked (e.g. "/newsletters/31952").
    var gradePaths: [String]
    var gradeLabels: [String]
    var keychainKey: String                     // session cookies live in Keychain under this key
    var connectedAt: Date?
    var lastNewsRefresh: Date?
    /// Set when the stored session no longer works, so the UI can ask the parent to reconnect.
    /// The calendar keeps syncing regardless (its feed is public).
    var needsReconnect: Bool

    init(host: String, displayName: String) {
        self.id = "pto"
        self.host = host
        self.displayName = displayName
        self.gradePaths = []
        self.gradeLabels = []
        self.keychainKey = "pto.\(UUID().uuidString)"
        self.needsReconnect = false
    }

    var calendarFeedURL: URL? { calendarFeedURLString.flatMap(URL.init(string:)) }
    var isConnected: Bool { connectedAt != nil }
}

/// One PTO newsletter, with its on-device AI summary. The full newsletter lives on the public
/// permalink; we store just the title, date, a short summary and the key dates we pulled out.
@Model
final class PTONewsItem {
    @Attribute(.unique) var permalink: String   // e.g. /newsletter/01884-NL2026... (stable id)
    var urlString: String                       // absolute public URL of the newsletter
    var title: String
    var publishedAt: Date?
    var gradeLabel: String?                      // first grade it was seen under (kept for compat)
    /// Every grade whose newsletter list this post appeared in — a general post shared across
    /// grades carries all of them, so a parent with multiple kids sees each matching grade tagged.
    var grades: [String] = []
    var summary: String                         // AI (or templated) 2–3 sentence summary
    var keyDates: [String]                      // pulled-out "important dates" lines
    var summarizedByAI: Bool
    var fetchedAt: Date
    var summarizedAt: Date?

    init(permalink: String, urlString: String, title: String, publishedAt: Date?, gradeLabel: String?) {
        self.permalink = permalink
        self.urlString = urlString
        self.title = title
        self.publishedAt = publishedAt
        self.gradeLabel = gradeLabel
        self.grades = gradeLabel.map { [$0] } ?? []
        self.summary = ""
        self.keyDates = []
        self.summarizedByAI = false
        self.fetchedAt = .now
    }

    /// Add a grade this post also belongs to (deduped).
    func addGrade(_ label: String?) {
        guard let label, !grades.contains(label) else { return }
        grades.append(label)
        if gradeLabel == nil { gradeLabel = label }
    }

    var url: URL? { URL(string: urlString) }
}
