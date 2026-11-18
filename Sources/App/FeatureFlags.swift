import Foundation

/// Simple compile-time feature switches.
enum FeatureFlags {
    /// Google Classroom is used for **upcoming homework + due dates** — it lists assigned work (often
    /// due this week) before it ever reaches PowerSchool's gradebook. PowerSchool remains the source
    /// of truth for grades, scores and missing/late status. (Earlier inspection confirmed the school
    /// Classroom account carries assignments PowerSchool doesn't yet have.)
    static let classroomEnabled = true
}
