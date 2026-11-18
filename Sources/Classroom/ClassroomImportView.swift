import SwiftUI
import SwiftData

/// One-tap Classroom sync. Tap Sync → Safari opens the To-do list → the extension scrapes it and
/// bounces back → assignments appear below. No passwords are stored; you're using your own Safari
/// session. First run shows iOS permission prompts; after that it's a single tap.
struct ClassroomImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var sync: ClassroomSync
    @Query private var assignments: [Assignment]
    let kid: Child

    private var imported: [Assignment] {
        assignments.filter { $0.child?.id == kid.id && $0.key.hasPrefix("gc-web:") }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    var body: some View {
        List {
            Section {
                Button {
                    openURL(sync.begin(for: kid))
                } label: {
                    Label(sync.syncing ? "Syncing… finish in Safari, then return" : "Sync Classroom for \(kid.firstName)",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(sync.syncing)
                if let message = sync.lastMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Opens your To-do list in Safari and imports every class's upcoming work at once. You stay signed in to Google in Safari — Classly never sees your password.")
            }

            Section {
                stepRow(1, "Open the **Settings** app on your iPhone.")
                stepRow(2, "Tap **Apps**, then tap **Safari**.")
                stepRow(3, "Tap **Extensions**, then tap **Classly**.")
                stepRow(4, "Turn on **Allow Extension**.")
                stepRow(5, "On the same screen under **Permissions**, tap **classroom.google.com** and choose **Allow**.")
                stepRow(6, "Open **Safari**, go to **classroom.google.com**, and sign in with your child's **school** Google account.")
                stepRow(7, "Come back here and tap **Sync Classroom** above.")
            } header: {
                Text("First-time setup · about a minute")
            } footer: {
                Text("You only do this once. It turns on the Classly helper inside Safari so it can read your child's assignment list — nothing else.")
            }

            Section("Imported homework") {
                if imported.isEmpty {
                    Text("Nothing yet. Tap Sync above.").foregroundStyle(.secondary)
                } else {
                    ForEach(imported) { a in
                        if let url = a.link {
                            Link(destination: url) { row(a) }
                        } else {
                            row(a)
                        }
                    }
                }
            }
        }
        .navigationTitle("Classroom Sync")
    }

    private func stepRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "\(n).circle.fill")
                .foregroundStyle(Theme.accent)
            Text(LocalizedStringKey(text))
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ a: Assignment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(a.title)
            Text([a.courseName, a.dueDate?.formatted(.dateTime.month().day()) ?? a.classroomDueText]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
