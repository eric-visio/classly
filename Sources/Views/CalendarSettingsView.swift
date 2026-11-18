import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Settings › School calendars: one entry per kid, plus a file-import fallback.
struct CalendarSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Child.sortOrder) private var children: [Child]
    @State private var importing = false
    @State private var importMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(children) { kid in
                    NavigationLink { CalendarLinkEditor(kid: kid) } label: {
                        LabeledContent(kid.firstName, value: kid.calendarSummary)
                    }
                }
            } header: { Text("Subscribe to a feed") } footer: {
                Text("Days off, early dismissals and events come from the school website. Paste the calendar page link; the app finds the feed on it.")
            }

            Section {
                Button {
                    importing = true
                } label: {
                    Label("Import a calendar file (.ics)", systemImage: "square.and.arrow.down")
                }
                if let importMessage { Text(importMessage).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("For districts that only publish a PDF or web page with no feed. Save or AirDrop the .ics to this iPhone, then import it here. It applies to all your kids.")
            }
        }
        .navigationTitle("School calendars")
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "ics") ?? .data, .text, .data],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard let url = (try? result.get())?.first else { importMessage = "Import cancelled."; return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            importMessage = "Couldn't read that file."; return
        }
        let n = SyncEngine(context: context).importCalendarText(
            text, feedKey: "file:\(url.lastPathComponent)", kidIDs: children.map(\.id))
        importMessage = n > 0 ? "Imported \(n) events. See the Calendar tab." : "No calendar events found in that file."
    }
}

extension Child {
    var calendarSummary: String {
        let n = allCalendarFeeds.count
        return n == 0 ? "Not set" : "\(n) calendar\(n == 1 ? "" : "s")"
    }
}

struct CalendarLinkEditor: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Child.sortOrder) private var children: [Child]
    @Bindable var kid: Child

    @State private var text = ""
    @State private var searching = false
    @State private var found: [CalendarFeed.Found] = []
    @State private var selected: Set<URL> = []
    @State private var error: String?
    @State private var savedNote: String?

    var body: some View {
        Form {
            Section {
                TextField("School or district calendar page", text: $text, axis: .vertical)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(searching ? "Looking for calendars…" : "Find calendars") { Task { await search() } }
                    .disabled(searching || text.trimmingCharacters(in: .whitespaces).isEmpty)
                if searching { ProgressView() }
            } header: {
                Text("\(kid.firstName)'s calendars")
            } footer: {
                Text("Paste the calendar page from the school or district website, or a Subscribe / iCal link.")
            }

            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.attention) }
            }

            if !found.isEmpty {
                Section {
                    FoundCalendarsList(found: found, selected: $selected)
                    Button("Use \(selected.count) selected for \(kid.firstName)") { save(for: [kid]) }
                        .disabled(selected.isEmpty)
                    let others = children.filter { $0.id != kid.id }
                    if !others.isEmpty {
                        Button("Use for all kids (\(children.map(\.firstName).joined(separator: ", ")))") { save(for: children) }
                            .disabled(selected.isEmpty)
                    }
                } header: {
                    Text("Found \(found.count) calendar\(found.count == 1 ? "" : "s") — pick the ones for \(kid.firstName)")
                }
            }

            if let savedNote {
                Section { Label(savedNote, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
            }

            if !kid.allCalendarFeeds.isEmpty {
                Section("In use") {
                    ForEach(kid.allCalendarFeeds, id: \.self) { u in
                        Text(u.host ?? u.absoluteString).font(.footnote)
                    }
                    Button("Remove all calendars for \(kid.firstName)", role: .destructive) {
                        kid.setCalendarFeeds([]); try? context.save(); savedNote = nil
                    }
                }
            }
        }
        .navigationTitle("School calendars")
    }

    private func search() async {
        searching = true; error = nil; found = []; savedNote = nil
        defer { searching = false }
        do {
            found = try await CalendarFeed.discover(text)
            // Pre-select a single result, or any already in use.
            selected = found.count == 1 ? [found[0].feedURL] : Set(found.map(\.feedURL)).intersection(kid.allCalendarFeeds)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(for kids: [Child]) {
        let urls = found.map(\.feedURL).filter(selected.contains)
        for k in kids { k.setCalendarFeeds(urls) }
        try? context.save()
        savedNote = "Saved. Events will show on the Calendar tab."
        Task { await SyncEngine(context: context).refreshCalendarsOnly() }
    }
}

/// Checklist of calendars found on a page, with a peek at what's coming up in each.
struct FoundCalendarsList: View {
    let found: [CalendarFeed.Found]
    @Binding var selected: Set<URL>

    var body: some View {
        ForEach(found) { f in
            Button {
                if selected.contains(f.feedURL) { selected.remove(f.feedURL) } else { selected.insert(f.feedURL) }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: selected.contains(f.feedURL) ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(f.name ?? f.feedURL.host ?? "Calendar").font(.subheadline.bold()).foregroundStyle(.primary)
                        Text("\(f.upcoming.count) upcoming of \(f.total) events").font(.caption).foregroundStyle(.secondary)
                        ForEach(f.upcoming.prefix(3), id: \.uid) { e in
                            Text("\(e.start.formatted(.dateTime.month(.abbreviated).day())) · \(e.summary)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .accessibilityAddTraits(selected.contains(f.feedURL) ? .isSelected : [])
        }
    }
}
