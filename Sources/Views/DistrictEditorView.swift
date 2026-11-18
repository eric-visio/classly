import SwiftUI

/// Change which district calendar Classly uses. Paste any district website URL (Thrillshare/
/// Apptegy, Google, Outlook…) and the app finds its public calendar feed — same discovery the
/// per-kid calendar setup uses. Defaults can be restored to Millburn.
struct DistrictEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var busy = false
    @State private var status: String?
    @State private var found: CalendarFeed.Found?
    let onSaved: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("District website URL", text: $input)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button("Find calendar") { Task { await find() } }
                        .disabled(busy || input.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: { Text("Switch district") } footer: {
                    Text("Paste your district's website address. Classly looks for its public calendar automatically — no iCal link or file needed.")
                }

                if busy { Section { HStack { ProgressView(); Text("Looking for the calendar…").foregroundStyle(.secondary) } } }

                if let status { Section { Text(status).font(.footnote).foregroundStyle(.secondary) } }

                if let found {
                    Section {
                        LabeledContent(found.name ?? "District calendar", value: "\(found.total) events")
                        Button("Use this district") { save(found) }.tint(Theme.accent)
                    }
                }

                Section {
                    Button("Restore Millburn default") {
                        DistrictDefault.restoreMillburn(); onSaved(); dismiss()
                    }
                }
            }
            .navigationTitle("District calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func find() async {
        busy = true; status = nil; found = nil
        do {
            let results = try await CalendarFeed.discover(input)
            if let first = results.first {
                found = first
                status = results.count > 1 ? "Found \(results.count) calendars — using the first." : nil
            } else {
                status = "No calendar found on that site."
            }
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? "Couldn't read that site."
        }
        busy = false
    }

    private func save(_ f: CalendarFeed.Found) {
        DistrictDefault.feedURLString = f.feedURL.absoluteString
        DistrictDefault.name = f.name ?? "District calendar"
        DistrictDefault.enabled = true
        onSaved()
        dismiss()
    }
}
