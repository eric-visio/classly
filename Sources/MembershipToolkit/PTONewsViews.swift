import SwiftUI
import SwiftData

/// Home-screen card: the latest PTO newsletters, each with its on-device summary.
struct PTONewsCard: View {
    @Query(sort: \PTONewsItem.publishedAt, order: .reverse) private var items: [PTONewsItem]
    @Query private var accounts: [PTOAccount]

    var body: some View {
        let account = accounts.first
        if let account, account.isConnected, !items.isEmpty {
            Card {
                HStack(spacing: 8) {
                    Text("PTO News").font(.headline)
                    Spacer()
                    NavigationLink("See all") { PTONewsListView() }
                        .font(.subheadline.weight(.semibold))
                }
                if account.needsReconnect {
                    reconnectNote
                }
                ForEach(Array(items.prefix(3))) { item in
                    NavigationLink { PTONewsDetailView(item: item) } label: { PTONewsRow(item: item) }
                        .buttonStyle(.plain)
                    if item.id != items.prefix(3).last?.id { Divider() }
                }
            }
        } else if let account, account.needsReconnect {
            Card { reconnectNote }
        }
    }

    private var reconnectNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise.circle").foregroundStyle(Theme.attention)
            Text("Your PTO sign-in expired. Reconnect in Settings to refresh news. (The calendar keeps syncing.)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Orange grade tag that tells a parent which of their kids a PTO post is for.
struct GradePill: View {
    let label: String
    private let orange = Color(hex: "E07A1F")
    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold)).foregroundStyle(orange)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(orange.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

struct PTONewsRow: View {
    let item: PTONewsItem
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            dateBadge
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                if !item.summary.isEmpty {
                    Text(item.summary).font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var dateBadge: some View {
        VStack(spacing: 0) {
            if let d = item.publishedAt {
                Text(d.formatted(.dateTime.month(.abbreviated))).font(.caption2.bold()).textCase(.uppercase)
                    .foregroundStyle(Theme.accent)
                Text(d.formatted(.dateTime.day())).font(.title3.bold())
            } else {
                Image(systemName: "newspaper").foregroundStyle(Theme.accent)
            }
        }
        .frame(width: 48, height: 52)
        .background(Theme.accent.opacity(0.1), in: .rect(cornerRadius: 12))
    }
}

/// Full list of PTO newsletters — same row format as the Today card.
struct PTONewsListView: View {
    @Query(sort: \PTONewsItem.publishedAt, order: .reverse) private var items: [PTONewsItem]
    var body: some View {
        ScrollView {
            Card {
                if items.isEmpty {
                    Text("No PTO newsletters yet. They'll appear here after the next sync.")
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    NavigationLink { PTONewsDetailView(item: item) } label: { PTONewsRow(item: item) }
                        .buttonStyle(.plain)
                    if item.id != items.last?.id { Divider() }
                }
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationTitle("PTO News")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One newsletter: its on-device summary, key dates, and a link to the full newsletter.
struct PTONewsDetailView: View {
    let item: PTONewsItem
    @Environment(\.openURL) private var openURL
    @Query private var ptoAccounts: [PTOAccount]
    private var grades: [String] { item.grades.isEmpty ? (ptoAccounts.first?.gradeLabels ?? []) : item.grades }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.title3.bold())
                    HStack(spacing: 8) {
                        if let d = item.publishedAt {
                            Text(d.formatted(.dateTime.weekday(.wide).month().day())).font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(grades, id: \.self) { GradePill(label: $0) }
                    }
                }

                Card {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                        Text("Summary").font(.headline)
                        Spacer()
                        if item.summarizedByAI {
                            Text("On-device AI").font(.caption2).foregroundStyle(Theme.accent)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Theme.accent.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(item.summary.isEmpty ? "Open the full newsletter to read this update." : item.summary)
                        .font(.subheadline).foregroundStyle(.primary).lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !item.keyDates.isEmpty {
                    Card(title: "Key dates") {
                        ForEach(Array(item.keyDates.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "calendar").font(.footnote).foregroundStyle(Theme.accent).padding(.top, 2)
                                Text(line).font(.subheadline)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if let url = item.url {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Read full newsletter", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).clipShape(.rect(cornerRadius: 16))
                }

                Label("Summarized on your iPhone", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationTitle("Newsletter")
        .navigationBarTitleDisplayMode(.inline)
    }
}
