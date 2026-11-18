import SwiftUI
import SwiftData

/// Coordinates the one-tap Classroom sync: the app opens the To-do page in Safari, the extension
/// scrapes it and bounces back to `classly://classroom-imported`, and we import on return.
@MainActor
final class ClassroomSync: ObservableObject {
    @Published var lastMessage: String?
    @Published var syncing = false

    private let kidKey = "classroomSyncKidID"

    /// The To-do (Assigned) list for every class. The hash tells our content script to act;
    /// without it, normal Classroom browsing is ignored.
    static let todoURL = URL(string: "https://classroom.google.com/a/not-turned-in/all?classly-sync#classly-sync")!

    /// Record which kid this sync is for, then hand back the URL to open in Safari.
    func begin(for kid: Child) -> URL {
        UserDefaults.standard.set(kid.id.uuidString, forKey: kidKey)
        syncing = true
        lastMessage = nil
        return Self.todoURL
    }

    private var pendingKidID: UUID? {
        UserDefaults.standard.string(forKey: kidKey).flatMap(UUID.init)
    }

    /// Called when the app returns (via the classly:// URL or on foreground). Imports whatever
    /// the extension staged. `url` is the callback, if any, carrying a count or an error.
    func handleReturn(_ url: URL?, context: ModelContext) {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
        if let error = items?.first(where: { $0.name == "error" })?.value {
            syncing = false
            lastMessage = error.removingPercentEncoding
            return
        }
        // The extension ran but found no coursework on the page — almost always the extension
        // isn't allowed on classroom.google.com yet, or Safari is on a personal Google account.
        if items?.first(where: { $0.name == "count" })?.value == "0" {
            syncing = false
            lastMessage = "Opened Classroom but found no assignments. In Safari, tap “aA” → Manage Extensions, allow Classly for classroom.google.com, and confirm you’re signed in to the school Google account — then tap Sync again."
            return
        }
        importStaged(context: context)
    }

    /// Import the staged file if present. Safe to call on any foreground.
    func importStaged(context: ModelContext) {
        if let count = ClassroomImporter.importPending(into: context, kidID: pendingKidID) {
            lastMessage = "Imported \(count) assignment\(count == 1 ? "" : "s") from Classroom."
            UserDefaults.standard.removeObject(forKey: kidKey)
            syncing = false
        } else if syncing {
            // Returned from Safari with nothing staged — the extension never ran (not enabled
            // or not permitted on classroom.google.com).
            lastMessage = "No homework came back. In Safari, open “aA” → Manage Extensions, turn on Classly and set it to Allow for classroom.google.com, then tap Sync again."
            syncing = false
        }
    }
}
