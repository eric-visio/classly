import Foundation
import SwiftData

enum Persistence {
    static let schema = Schema([
        PowerSchoolAccount.self, Child.self, Course.self, Assignment.self,
        AttendanceRecord.self, GradeSnapshot.self, SchoolEvent.self,
        PTOAccount.self, PTONewsItem.self,
    ])

    /// On-device only. `cloudKitDatabase: .none` keeps SwiftData from syncing to iCloud.
    /// File protection is "until first unlock" so the morning background refresh can still
    /// write while the phone is locked; the data is still encrypted at rest by iOS.
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        if inMemory {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
            .appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var url = dir.appendingPathComponent("school.store")
        // Keep the store out of iCloud / iTunes backups.
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)

        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: config)
    }

    /// "Erase all data & sign-ins from this iPhone"
    @MainActor
    static func eraseEverything(_ context: ModelContext) throws {
        try context.delete(model: PTONewsItem.self)
        try context.delete(model: PTOAccount.self)
        try context.delete(model: SchoolEvent.self)
        try context.delete(model: GradeSnapshot.self)
        try context.delete(model: AttendanceRecord.self)
        try context.delete(model: Assignment.self)
        try context.delete(model: Course.self)
        try context.delete(model: Child.self)
        try context.delete(model: PowerSchoolAccount.self)
        try context.save()
        Keychain.deleteAll()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
    }
}
