import Foundation
import SwiftUI

/// Developer tool: saves the portal pages exactly as the app sees them (after sign-in and page
/// JavaScript), so parsers can be checked against a real district. Files stay on the phone
/// until you choose to share them. Review/redact before sharing — they contain your kids' data.
@MainActor
enum PortalCapture {
    static func capture(account: PowerSchoolAccount) async throws -> [URL] {
        guard let cred = Keychain.get(PowerSchoolCredential.self, for: account.keychainKey) else {
            throw PortalBrowser.PortalError.signInRequired
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PortalCapture", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let browser = PortalBrowser(baseURL: account.baseURL)
        _ = try await browser.ensureSignedIn(credential: cred)
        let home = try await browser.html()
        var files = [dir.appendingPathComponent("home.html")]
        try home.write(to: files[0], atomically: true, encoding: .utf8)

        // Daily attendance page (the one parents see under Attendance in the portal menu).
        if (try? await browser.load(path: "guardian/attendance.html")) != nil {
            let f = dir.appendingPathComponent("attendance.html")
            try await browser.html(settle: .seconds(2)).write(to: f, atomically: true, encoding: .utf8)
            files.append(f)
        }

        for (i, course) in PortalParsers.courses(homeHTML: home, baseURL: account.baseURL).prefix(2).enumerated() {
            guard let url = course.currentGrade?.scoresURL else { continue }
            try await browser.load(url: url)
            let f = dir.appendingPathComponent("scores-\(i + 1).html")
            try await browser.html(settle: .seconds(2)).write(to: f, atomically: true, encoding: .utf8)
            files.append(f)
        }
        // Parser summary alongside, so mismatches are obvious.
        let c = PortalParsers.courses(homeHTML: home, baseURL: account.baseURL)
        let summary = """
        students: \(PortalParsers.students(homeHTML: home).map(\.name))
        courses parsed: \(c.count)
        \(c.map { "- \($0.name) | \($0.teacher ?? "?") | \($0.currentGrade?.term ?? "?") \($0.currentGrade?.letter ?? "?") \($0.currentGrade?.percent.map { "\($0)" } ?? "?") | abs \($0.absences) tardy \($0.tardies)" }.joined(separator: "\n"))
        """
        let s = dir.appendingPathComponent("parser-summary.txt")
        try summary.write(to: s, atomically: true, encoding: .utf8)
        files.append(s)
        return files
    }
}

#if DEBUG
struct PortalCaptureButton: View {
    let account: PowerSchoolAccount
    @State private var files: [URL] = []
    @State private var error: String?
    var body: some View {
        Button("Save portal pages for parser check") {
            Task {
                do { files = try await PortalCapture.capture(account: account) }
                catch { self.error = error.localizedDescription }
            }
        }
        if !files.isEmpty { ShareLink("Share \(files.count) files", items: files) }
        if let error { Text(error).foregroundStyle(.red).font(.footnote) }
    }
}
#endif
