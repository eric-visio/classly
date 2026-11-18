import SwiftUI
import SwiftData
import LocalAuthentication

@main
struct ClasslyApp: App {
    let container: ModelContainer

    init() {
        do { container = try Persistence.makeContainer() }
        catch { fatalError("Could not open the on-device store: \(error)") }
        BackgroundRefresh.register(container: container)
    }

    @StateObject private var classroomSync = ClassroomSync()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(classroomSync)
                .onOpenURL { url in
                    if url.scheme == "classly" {
                        classroomSync.handleReturn(url, context: container.mainContext)
                    }
                }
        }
        .modelContainer(container)
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @EnvironmentObject private var classroomSync: ClassroomSync
    @Query(sort: \Child.sortOrder) private var children: [Child]
    @State private var unlocked = !AppSettings.load().faceIDLock
    @State private var refreshing = false

    var body: some View {
        Group {
            if children.isEmpty {
                OnboardingFlow()
            } else if !unlocked {
                LockView(onUnlock: { unlocked = true })
            } else {
                MainTabs(refreshing: refreshing, refresh: refresh)
            }
        }
        // First refresh right after setup finishes (and on any launch that has never synced).
        .onChange(of: children.count) { old, new in
            if old == 0 && new > 0 { unlocked = true; Task { await refresh() } }
        }
        .task {
            if !children.isEmpty && AppSettings.lastRefresh == nil { await refresh() }
        }
        .onChange(of: phase) { _, p in
            if p == .background { unlocked = !AppSettings.load().faceIDLock; BackgroundRefresh.schedule() }
            if p == .active, !children.isEmpty {
                // If a Classroom sync was in flight, finish it when we come back to the foreground.
                if classroomSync.syncing { classroomSync.importStaged(context: context) }
                if (AppSettings.lastRefresh ?? .distantPast) < .now.addingTimeInterval(-15 * 60) {
                    Task { await refresh() }
                }
            }
        }
        // The UI is built on a fixed light palette (white cards, light backgrounds).
        // Pin the app to light mode so every screen stays readable even when the
        // phone is in dark mode — otherwise default text turns white on white cards.
        .preferredColorScheme(.light)
    }

    /// Foreground refresh (on open and pull-to-refresh).
    @MainActor
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        let changes = await SyncEngine(context: context).refreshAll()
        AppSettings.markRefreshed()
        // While the app is open the Today screen shows changes; only nag about sign-ins.
        await Notifier.deliver(changes.filter { if case .needsSignIn = $0 { true } else { false } }, settings: .load())
        await Notifier.scheduleEveningDigest(context: context, settings: .load())
    }
}

struct LockView: View {
    var onUnlock: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image("ClasslyLogo")
                .resizable().scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Classly").font(.largeTitle.bold())
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                    Text("Locked")
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Unlock with Face ID", action: authenticate)
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 8)
            Text("Your kids' school data stays on this iPhone")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.bottom, 24)
        }
        .padding()
        .onAppear(perform: authenticate)
    }

    func authenticate() {
        let ctx = LAContext()
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your kids' school info") { ok, _ in
            if ok { DispatchQueue.main.async(execute: onUnlock) }
        }
    }
}

enum Theme {
    static let accent = Color(hex: "2D5BE3")
    static let attention = Color(hex: "B4530F")
    static let attentionBG = Color(hex: "FFF4EA")
    static let bg = Color(hex: "F4F6FA")
    static let kidColors = ["2D5BE3", "E07A1F", "7B4FD6", "0F8C8C", "C23D7A"]
}

extension Color {
    init(hex: String) {
        let v = UInt64(hex.trimmingCharacters(in: ["#"]), radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
