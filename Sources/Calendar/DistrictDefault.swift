import Foundation

/// The district calendar Classly ships with, so parents don't have to add one.
///
/// Defaults to Millburn Township Public Schools (the launch district). It's applied to every kid
/// automatically on each calendar sync. Parents can turn it off or point it at a different
/// district in Settings — those choices are stored here, separate from the main settings blob so
/// adding this never disturbs existing saved preferences.
enum DistrictDefault {
    // Millburn's public Apptegy/Thrillshare events iCal (org 18140). Public + cookieless.
    static let millburnFeed = "https://thrillshare-cmsv2.services.thrillshare.com/api/v4/o/18140/cms/events/generate_ical"
    static let millburnName = "Millburn Township Public Schools"
    // The district-calendars page parents would paste. Its HTML carries the Apptegy org id
    // (18140, in the asset paths), which CalendarFeed.discover turns into the iCal above.
    static let millburnCalendarPage = "https://www.millburn.org/page/district-calendars/"

    private static let kEnabled = "district.enabled"
    private static let kFeed = "district.feedURL"
    private static let kName = "district.name"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: kEnabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: kEnabled) }
    }
    static var feedURLString: String {
        get { UserDefaults.standard.string(forKey: kFeed) ?? millburnFeed }
        set { UserDefaults.standard.set(newValue, forKey: kFeed) }
    }
    static var name: String {
        get { UserDefaults.standard.string(forKey: kName) ?? millburnName }
        set { UserDefaults.standard.set(newValue, forKey: kName) }
    }

    /// The feed to merge, or nil when the parent turned the district calendar off.
    static var feedURL: URL? { enabled ? URL(string: feedURLString) : nil }

    static func restoreMillburn() {
        feedURLString = millburnFeed
        name = millburnName
        enabled = true
    }
}
