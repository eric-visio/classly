import Foundation
import UserNotifications
import SwiftData

/// Local notifications only — built on the phone from the refresh diff. No push server.
enum Notifier {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    static func deliver(_ changes: [Change], settings: AppSettings) async {
        let center = UNUserNotificationCenter.current()
        for (i, change) in changes.enumerated() {
            guard let message = text(for: change, settings: settings) else { continue }
            let (title, body) = message
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body; content.sound = .default
            content.threadIdentifier = threadID(change)
            let req = UNNotificationRequest(identifier: "chg-\(Date.now.timeIntervalSince1970)-\(i)", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            try? await center.add(req)
        }
    }

    static func text(for c: Change, settings s: AppSettings) -> (String, String)? {
        switch c {
        case let .newMissing(child, course, title) where s.notifyMissing:
            return ("\(child): missing assignment", "\(course) — \(title)")
        case let .gradeDropped(child, course, from, to, letter) where s.notifyGradeDrop && to < s.gradeDropFloor:
            return ("\(child)'s \(course) grade dropped", "\(Int(from))% → \(Int(to))%\(letter.map { " (\($0))" } ?? "")")
        case let .newScore(child, course, title, pct) where s.notifyNewScores:
            return ("\(child) — new score in \(course)", "\(title): \(Int(pct.rounded()))%")
        case let .attendance(child, kind, date, period) where s.notifyAttendance:
            let what = kind == .tardy ? "Tardy" : "Absent"
            return ("\(child): \(what)\(period.map { " · Period \($0)" } ?? "")", date.formatted(date: .abbreviated, time: .omitted))
        case let .dayOff(title, date) where s.notifyDaysOff:
            return ("No school \(date.formatted(.dateTime.weekday(.wide).month().day()))", title)
        case let .needsSignIn(source, detail):
            return ("Reconnect \(source)", "Sign in again for \(detail) to keep updates coming.")
        default:
            return nil
        }
    }

    private static func threadID(_ c: Change) -> String {
        switch c {
        case .newMissing(let k, _, _), .gradeDropped(let k, _, _, _, _), .newScore(let k, _, _, _), .attendance(let k, _, _, _): return k
        default: return "school"
        }
    }

    /// Rebuilds tonight's "due tomorrow" digest from the store. Called after every refresh.
    @MainActor
    static func scheduleEveningDigest(context: ModelContext, settings: AppSettings, now: Date = .now) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["digest"])
        guard settings.eveningDigest else { return }
        let cal = Calendar.current
        guard let fire = cal.date(bySettingHour: settings.digestHour, minute: 0, second: 0, of: now), fire > now,
              let tomorrowStart = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)),
              let tomorrowEnd = cal.date(byAdding: .day, value: 1, to: tomorrowStart) else { return }
        let due = ((try? context.fetch(FetchDescriptor<Assignment>())) ?? [])
            .filter { a in !a.isTurnedIn && (a.dueDate.map { $0 >= tomorrowStart && $0 < tomorrowEnd } ?? false) }
        guard !due.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "Due tomorrow: \(due.count) item\(due.count == 1 ? "" : "s")"
        content.body = due.prefix(4).map { "\($0.child?.firstName ?? "") · \($0.courseName): \($0.title)" }.joined(separator: "\n")
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        try? await center.add(UNNotificationRequest(identifier: "digest", content: content,
                                                    trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }
}
