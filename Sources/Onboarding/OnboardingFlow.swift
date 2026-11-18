import SwiftUI
import SwiftData

/// Setup: Welcome → school → parent PowerSchool sign-in → confirm kids → school calendars →
/// alerts & lock. "Add a kid at another school" loops back to the school step with a second
/// PowerSchool account. (Google Classroom is intentionally left out — most districts block it
/// for under-18 student accounts; the code lives behind `ClassroomStep` if a district approves.)
struct OnboardingFlow: View {
    enum Step: Int, CaseIterable { case welcome, school, powerSchool, kids, calendar, pto, finish }

    @Environment(\.modelContext) private var context
    @State private var step: Step = .welcome
    @State private var draft = OnboardingDraft()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if step != .welcome {
                    ProgressView(value: Double(step.rawValue), total: 6).tint(Theme.accent)
                    Text("Step \(step.rawValue) of 6").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                switch step {
                case .welcome: WelcomeStep { step = .school }
                case .school: SchoolStep(draft: $draft) { step = .powerSchool } skip: { step = .kids }
                case .powerSchool: PowerSchoolStep(draft: $draft) { step = .kids }
                case .kids: KidsStep(draft: $draft, addAnotherSchool: { draft.startAnotherSchool(); step = .school }) { step = .calendar }
                case .calendar: CalendarStep(draft: $draft) { step = .pto }
                case .pto: PTOStep { step = .finish }
                case .finish: FinishStep { settings in finish(settings) }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.bg)
            .toolbar {
                if step.rawValue > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { step = Step(rawValue: step.rawValue - 1) ?? .welcome } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("Back")
                    }
                }
            }
        }
    }

    private func finish(_ settings: AppSettings) {
        settings.save()
        draft.commit(into: context)
        try? context.save()
        BackgroundRefresh.schedule(settings: settings)
        Task { _ = await Notifier.requestPermission() }
    }
}

/// Everything collected during setup, written to the store only on "Finish".
struct OnboardingDraft {
    struct School: Identifiable {
        let id = UUID()
        var baseURL: URL?
        var displayName = ""
        var credential: PowerSchoolCredential?
        var usedSSO = false
        var kids: [DraftKid] = []
    }
    struct DraftKid: Identifiable {
        let id = UUID()
        var firstName: String
        var powerSchoolStudentID: String?
        var colorHex: String
        var include = true
        var googleEmail: String?
        var googleTokens: GoogleTokens?
        var googleStatus: GoogleLinkStatus = .notLinked
        var calendarURL: String = DistrictDefault.millburnCalendarPage   // Millburn by default
        var calendarFeeds: [URL] = []      // chosen after "Check link"
    }

    var schools: [School] = [School()]
    var current: Int = 0

    var allKids: [DraftKid] { schools.flatMap(\.kids).filter(\.include) }

    mutating func startAnotherSchool() { schools.append(School()); current = schools.count - 1 }

    mutating func updateKid(_ id: UUID, _ change: (inout DraftKid) -> Void) {
        for s in schools.indices { if let k = schools[s].kids.firstIndex(where: { $0.id == id }) { change(&schools[s].kids[k]) } }
    }

    func nextColor() -> String { Theme.kidColors[schools.flatMap(\.kids).count % Theme.kidColors.count] }

    func commit(into context: ModelContext) {
        var order = 0
        for school in schools {
            var account: PowerSchoolAccount?
            if let url = school.baseURL, let cred = school.credential {
                let a = PowerSchoolAccount(baseURL: url, displayName: school.displayName.isEmpty ? (url.host ?? "PowerSchool") : school.displayName,
                                           usesSSO: school.usedSSO)
                try? Keychain.set(cred, for: a.keychainKey)
                context.insert(a); account = a
            }
            for k in school.kids where k.include {
                let child = Child(firstName: k.firstName, colorHex: k.colorHex, sortOrder: order); order += 1
                child.powerSchoolStudentID = k.powerSchoolStudentID
                child.powerSchoolAccount = account
                child.setCalendarFeeds(k.calendarFeeds.isEmpty ? [ICSParser.normalizedFeedURL(k.calendarURL)].compactMap { $0 } : k.calendarFeeds)
                child.googleStatus = k.googleStatus
                if let t = k.googleTokens {
                    let key = "g.\(child.id.uuidString)"
                    try? Keychain.set(t, for: key)
                    child.googleKeychainKey = key; child.googleEmail = t.email ?? k.googleEmail
                }
                context.insert(child)
            }
        }
    }
}
