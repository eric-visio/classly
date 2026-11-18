# Classly

An iPhone app for parents. Each morning it gathers each kid's PowerSchool grades and attendance, and the school calendar. Classroom homework can also be imported on demand from Safari. **All data and logins stay on the phone.** There's no backend.

## Build

1. `brew install xcodegen && xcodegen` (creates `Classly.xcodeproj` from `project.yml`)
2. Open it in Xcode 16+ and set your signing team. iOS 17 or later.
3. Optional legacy API setup. In Google Cloud Console, create a project, enable the **Google Classroom API**, and create an **iOS OAuth client**. Put the client ID in `project.yml` (`GIDClientID`, plus the reversed ID in `CFBundleURLSchemes`).
4. Run on a real device. Background refresh doesn't run in the simulator. To test it, use Xcode's debugger:
   `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.visiocapital.classly.refresh"]`

## Classroom sync on iPhone

1. Run XcodeGen again. In Signing & Capabilities, select the same team for
   Classly and ClassroomExtension. Register and enable
   `group.com.visiocapital.classly` for both targets. If your team needs a
   different App Group ID, update both entries in project.yml and the identifier
   in ClassroomWebSnapshot.swift. If you change the app bundle ID, update the
   extension bundle ID prefix and the native messaging identifier in popup.js.
2. Install Classly on your iPhone. Enable **Classly Classroom** in
   Safari Extensions and allow access to classroom.google.com. Google credentials
   are entered directly in Safari. The extension accesses only Classroom.
3. Select a student in **Homework**, tap **Classroom Sync**, then tap **Sync Classroom in Safari**. The same screen is available under **Settings → Classroom Sync**.
   On the signed-in Classroom site, open a class and its **Classwork** tab.
4. Open the Classly Classroom extension from Safari's page menu, tap
   **Import this class**, and return to the student's Classroom Sync screen.
   Review the class and tap **Save to [student]’s profile** before importing
   another class. The staging inbox holds one import at a time.
5. Saved homework is visible under Classroom imports in the Homework tab and in the student's Classroom Sync screen. Re-imports
   update matching assignments. Previously saved assignments are retained because
   a visible page may show only part of a class.

The extension hands off a local JSON file using the App Group. It makes no
requests to an app server. Visible due-date labels are preserved as text because
they may be relative or omit the year; they do not drive the app's deadline
alerts. The Safari import does not collect grades or submission status.
Verify the English Classwork link patterns and due text with a signed-in student
account. No Google Cloud configuration is needed for this Safari path.

## Where each piece of data comes from

| Screen data | Source | How |
|---|---|---|
| Kids on the account | PowerSchool parent portal | student switcher on `guardian/home.html` |
| Class grades (letter + %), teacher, room, period | PowerSchool | "Grades and Attendance" table on `guardian/home.html` |
| Assignment scores, missing/late/exempt flags, categories | PowerSchool | class score detail pages (`scores.html` links) |
| Absences/tardies per class + last 2 weeks' codes | PowerSchool | same home table + district code legend |
| Grade trend charts | Built on the phone | daily snapshot of each class grade (the portal only shows today's grade) |
| Homework titles, links, and visible due text | Safari Classroom import | Student Classwork tab, one class at a time |
| Turned-in state and Classroom grades | Optional legacy Google Classroom API | Read-only student submissions |
| Days off, picture day, early dismissal, events | School website calendar feed (iCal/webcal) | PowerSchool doesn't usually publish these to parents |
| GPA, attendance %, on-time % | Calculated on the phone | labeled as estimates |

## How the PowerSchool part works

The parent signs in on the district's own sign-in page, shown inside the app (`PowerSchoolSignInView`). The session cookies, plus the username and password for districts that use them, go into the Keychain with the setting *this device only, after first unlock*. The refresh then opens the same portal pages in a hidden `WKWebView` (`PortalBrowser`) and parses the rendered HTML (`PortalParsers`).

Districts that sign in through Google, Clever or ClassLink can't be signed back in silently. When their session expires, the app sends a "Reconnect PowerSchool" notification.

## Check before relying on it

- **Parsers vs. your district.** The fixtures in `Tests/ParserTests.swift` are made up and shaped like the standard portal. On your phone, open Settings › Developer › *Save portal pages for parser check*. Look the files over and remove anything private, then add them as fixtures and fix any parser mismatches.
- **Sign-in field IDs** (`fieldAccount`, `fieldPassword`, `btn-enter-sign-in`) in `PortalBrowser.swift` are the standard ones. Confirm them on your district's sign-in page.
- **Google approval for students under 18.** Google Workspace for Education blocks third-party apps for these students until the school's admin approves the app. The app detects this and shows "Ask school to approve."
- **Google OAuth verification.** Before other families can use the app, Google must verify it for the Classroom scopes. Until then only test users you add can sign in.
- **Terms of use.** Check PowerSchool's and the district's terms of use for automated access to the parent portal before a public launch.
- **Background refresh timing.** iOS decides when it runs. The app also refreshes on open and on pull-to-refresh.

## Layout

```
Sources/
  App/            app entry, lock screen, theme
  Models/         SwiftData models (on-device only, no CloudKit)
  Storage/        encrypted store setup, Keychain
  PowerSchool/    sign-in view, hidden portal browser, parsers, fetcher, capture tool
  Classroom/      Google OAuth (PKCE) + Classroom API client
  Calendar/       iCal feed parser
  Sync/           SyncEngine (diff → changes), background refresh, local notifications
  Onboarding/     6-step setup: school → parent login → kids → Classroom per kid → calendars → alerts
  Views/          Today, Grades + course detail, Homework, Attendance, Calendar, Settings
Tests/            parser + sync tests
```
