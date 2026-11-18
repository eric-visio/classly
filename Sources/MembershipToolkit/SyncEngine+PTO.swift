import Foundation
import SwiftData

extension SyncEngine {

    /// Keeps the PTO calendar feed merged and refreshes/ summarizes PTO newsletters.
    /// The calendar feed is public, so it syncs with no login; newsletters reuse the stored
    /// session and flag `needsReconnect` if it has expired (the calendar keeps working).
    func refreshPTO(_ children: [Child]) async {
        guard let acct = (try? context.fetch(FetchDescriptor<PTOAccount>()))?.first, acct.isConnected else { return }

        // 1) Make sure the (cookieless) calendar feed is in every kid's feed set, so the normal
        //    calendar merge picks it up — including kids added after the PTO was connected.
        if let feed = acct.calendarFeedURL {
            for kid in children where !kid.allCalendarFeeds.contains(feed) {
                kid.setCalendarFeeds(kid.allCalendarFeeds + [feed])
            }
        }

        // 2) Newsletters need the saved session. Throttle to ~12h; skip if we need a reconnect.
        guard !acct.needsReconnect else { return }
        if let last = acct.lastNewsRefresh, last > .now.addingTimeInterval(-12 * 3600) { return }
        guard let cred = Keychain.get(PTOCredential.self, for: acct.keychainKey), !cred.cookies.isEmpty else {
            acct.needsReconnect = true; return
        }

        let portal = PTOPortal(host: acct.host)
        await portal.restore(cookies: cred.cookies)
        do {
            for (i, path) in acct.gradePaths.enumerated() {
                let label = i < acct.gradeLabels.count ? acct.gradeLabels[i] : nil
                let refs = try await portal.scrapeNewsletters(gradePath: path)
                for ref in refs { await upsertNewsItem(ref, gradeLabel: label) }
            }
            acct.lastNewsRefresh = .now
            acct.needsReconnect = false
        } catch {
            acct.needsReconnect = true   // session likely expired — UI will offer reconnect
        }
        pruneOldNews()
    }

    private func upsertNewsItem(_ ref: PTOPortal.NewsletterRef, gradeLabel: String?) async {
        let permalink = ref.permalink
        let fetch = FetchDescriptor<PTONewsItem>(predicate: #Predicate { $0.permalink == permalink })
        if let existing = (try? context.fetch(fetch))?.first {
            existing.addGrade(gradeLabel)   // same post can appear under several grades
            return   // already fetched + summarized
        }
        let item = PTONewsItem(permalink: permalink, urlString: ref.url,
                               title: ref.title.trimmingCharacters(in: .whitespacesAndNewlines),
                               publishedAt: dateFromPermalink(permalink), gradeLabel: gradeLabel)
        if let url = item.url, let content = await NewsletterSummarizer.fetch(url) {
            if let d = content.publishedAt { item.publishedAt = d }
            let (summary, byAI) = await NewsletterSummarizer.summarize(title: item.title, content: content)
            item.summary = summary
            item.summarizedByAI = byAI
            item.keyDates = content.keyDates
            item.summarizedAt = .now
        } else {
            item.summary = "Tap to read this PTO update."
        }
        context.insert(item)
    }

    /// permalink like /newsletter/01884-NL20261102070307-... → 2026-11-02
    private func dateFromPermalink(_ p: String) -> Date? {
        guard let m = p.range(of: #"NL(\d{8})"#, options: .regularExpression) else { return nil }
        let s = String(p[m].dropFirst(2))
        guard s.count == 8, let y = Int(s.prefix(4)),
              let mo = Int(s.dropFirst(4).prefix(2)), let d = Int(s.dropFirst(6).prefix(2)) else { return nil }
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = 9
        return Calendar.current.date(from: c)
    }

    private func pruneOldNews() {
        let cutoff = Date.now.addingTimeInterval(-90 * 86_400)
        let old = ((try? context.fetch(FetchDescriptor<PTONewsItem>())) ?? [])
            .filter { ($0.publishedAt ?? $0.fetchedAt) < cutoff }
        for o in old { context.delete(o) }
    }
}
