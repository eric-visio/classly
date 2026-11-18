# Classroom Sync (Safari extension) — setup

The app reads grades, missing work and attendance from PowerSchool automatically. Google
Classroom blocks third-party apps and the Calendar feed for Millburn's under-18 student
accounts, so upcoming Classroom homework is pulled a different way: a **Safari Web Extension**
that reads your own To-do page while you're signed in, triggered by a Sync button in the app.

No password is stored and no headless/automated login happens — it reads the page you are
already allowed to see, only when you tap Sync.

## How it works
1. In the app: Homework tab → **Classroom Sync** → **Sync Classroom**.
2. The app opens `classroom.google.com/a/not-turned-in/all` in Safari with a `#classly-sync`
   marker.
3. `content.js` runs only when that marker is present, waits for the list to render, scrapes
   every class's assignment (course, title, due text, link), and sends it to `background.js`.
4. `background.js` forwards it to the native `SafariWebExtensionHandler`, which validates it and
   writes `pending.json` into the shared App Group container.
5. `content.js` redirects to `classly://classroom-imported`, bringing you back to the app,
   which imports the staged file for the kid whose screen started the sync and parses the due
   dates so the work shows under Due soon and on the dashboard.

## One-time device setup
- **Enable the extension:** Settings → Apps → Safari → Extensions (or the Safari toolbar ⟨ᴀA⟩ →
  Manage Extensions) → turn on **Classly Classroom** and **Allow** it on
  `classroom.google.com`.
- **Sign in once:** open `classroom.google.com` in Safari as the student. The session persists.

## Xcode / signing
- `xcodegen` generates both targets (`Classly`, `ClassroomExtension`) and the App Group
  entitlement `group.com.visiocapital.classly` on both. In Xcode, set your Team on **both**
  targets and confirm the App Group is enabled on both under Signing & Capabilities.
- The `classly://` return scheme is registered in `project.yml`.

## Limits / fragility
- Gives titles, due dates and links only — no grades or turn-in status (those stay PowerSchool's job).
- Scraping reads Classroom's current page markup. If Google changes it, update the selectors in
  `content.js` (`scrape()`), which keys off assignment links matching `/c/<course>/a/<assignment>`.
- It needs the student's Google session to be the active one in Safari. If multiple Google
  accounts are signed in, make the student's the default, or the To-do page may show the wrong
  account.
