import Foundation
import BackgroundTasks
import SwiftData

/// Daily refresh. iOS decides when a BGAppRefreshTask actually runs (battery, usage, network),
/// so `earliestBeginDate` is a request, not a promise. The app also refreshes whenever it opens.
enum BackgroundRefresh {
    static let taskID = "com.visiocapital.classly.refresh"

    /// Call once, before the app finishes launching.
    static func register(container: ModelContainer) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            schedule()   // always queue the next one first
            let work = Task { @MainActor in
                let engine = SyncEngine(context: container.mainContext)
                let changes = await engine.refreshAll()
                await Notifier.deliver(changes, settings: .load())
                AppSettings.markRefreshed()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel(); task.setTaskCompleted(success: false) }
        }
    }

    /// Requests the next run at the next morning or after-school slot.
    static func schedule(settings: AppSettings = .load(), now: Date = .now) {
        let req = BGAppRefreshTaskRequest(identifier: taskID)
        req.earliestBeginDate = nextSlot(after: now, settings: settings)
        try? BGTaskScheduler.shared.submit(req)
    }

    static func nextSlot(after now: Date, settings: AppSettings) -> Date {
        let cal = Calendar.current
        var slots = [settings.morningHour]
        if let h = settings.afterSchoolHour { slots.append(h) }
        let candidates = (0...1).flatMap { dayOffset in
            slots.compactMap { hour -> Date? in
                guard let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now)) else { return nil }
                return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)
            }
        }
        return candidates.filter { $0 > now }.min() ?? now.addingTimeInterval(6 * 3600)
    }
}

struct AppSettings: Codable {
    var morningHour = 6
    var afterSchoolHour: Int? = 16
    var notifyMissing = true
    var notifyGradeDrop = true
    var gradeDropFloor = 80.0          // notify when a class falls below this percent
    var notifyAttendance = true
    var notifyNewScores = false
    var notifyDaysOff = true
    var eveningDigest = true
    var digestHour = 19
    var faceIDLock = true

    private static let key = "settings.v1"
    static func load() -> AppSettings {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key) }

    static func markRefreshed() { UserDefaults.standard.set(Date.now, forKey: "lastRefresh") }
    static var lastRefresh: Date? { UserDefaults.standard.object(forKey: "lastRefresh") as? Date }
}
