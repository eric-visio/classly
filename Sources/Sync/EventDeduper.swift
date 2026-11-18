import Foundation
import SwiftData
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Cross-source calendar de-duplication
//
// The exact-content pass in SyncEngine.dedupeEvents() collapses events that share a
// title. But the district (Thrillshare) feed and the school / PTO feed routinely post
// the SAME real event under different wording and casing on the same day — e.g.
//   "No School – Thanksgiving"            vs  "SCHOOLS AND DISTRICT CLOSED - THANKSGIVING"
//   "Early Dismissal"                     vs  "DISTRICT EARLY DISMISSAL - THANKSGIVING"
//   "Delayed Opening – Staff PD"          vs  "DELAYED OPENING STUDENTS - STAFF PD"
// Those never match on text, so this pass judges same-day pairs by meaning: on-device
// Apple Intelligence when available, a deterministic keyword rule otherwise. Verdicts are
// cached per title-pair, so the model is asked at most once for any new pairing and later
// syncs re-merge for free.

extension SyncEngine {

    /// Merge same-day events that are the same real event under different names. Runs after
    /// the exact-content dedup; safe to call every sync (cached + cheap after the first time).
    func mergeDuplicateEventsWithAI() async {
        let cal = Calendar.current
        let all = (try? context.fetch(FetchDescriptor<SchoolEvent>())) ?? []

        // Cross-source duplicates always land on the same calendar day, so only compare
        // within a day (and matching all-day flag). This keeps the work tiny — most days
        // have one or two events.
        // Bucket by calendar day only (NOT by all-day flag): the same closure is often
        // posted by one feed as a timed event and by another as all-day, and those must
        // still be compared. isSameEvent() keeps genuinely different same-day events apart.
        var byDay: [Int: [SchoolEvent]] = [:]
        for e in all {
            let day = Int(cal.startOfDay(for: e.start).timeIntervalSince1970)
            byDay[day, default: []].append(e)
        }
        for (_, group) in byDay where group.count > 1 {
            await mergeGroup(group)
        }
    }

    /// Cluster one day's events by "is this the same event?" and collapse each cluster to one.
    private func mergeGroup(_ group: [SchoolEvent]) async {
        var parent = Array(0..<group.count)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }

        for i in 0..<group.count {
            for j in (i + 1)..<group.count where find(i) != find(j) {
                if await isSameEvent(group[i].title, group[j].title) { union(i, j) }
            }
        }

        var clusters: [Int: [Int]] = [:]
        for i in 0..<group.count { clusters[find(i), default: []].append(i) }
        for (_, idxs) in clusters where idxs.count > 1 {
            let events = idxs.map { group[$0] }
            guard let keeper = canonicalEvent(events) else { continue }
            for e in events where e !== keeper {
                keeper.childIDs = Array(Set(keeper.childIDs + e.childIDs))
                // If the survivor had a vague kind, inherit the duplicate's more specific one.
                if keeper.kind == .event || keeper.kind == .other { keeper.kind = e.kind }
                context.delete(e)
            }
        }
    }

    /// The entry a parent should keep. Honor the school-district calendar first: if any
    /// event in the cluster came from the district feed, that one wins (it's the
    /// authoritative source and carries the fuller description). Otherwise keep the
    /// cleaner-cased, shorter title.
    private func canonicalEvent(_ events: [SchoolEvent]) -> SchoolEvent? {
        if let districtPrefix = DistrictDefault.feedURL.map({ $0.absoluteString + "#" }) {
            let district = events.filter { $0.key.hasPrefix(districtPrefix) }
            if let keep = district.min(by: { $0.title.count < $1.title.count }) { return keep }
        }
        return events.min { a, b in
            let ua = uppercaseRatio(a.title), ub = uppercaseRatio(b.title)
            if abs(ua - ub) > 0.15 { return ua < ub }
            return a.title.count < b.title.count
        }
    }

    private func uppercaseRatio(_ s: String) -> Double {
        let letters = s.filter { $0.isLetter }
        guard !letters.isEmpty else { return 0 }
        return Double(letters.filter { $0.isUppercase }.count) / Double(letters.count)
    }

    // MARK: Same-event judgement (cache → AI → heuristic)

    private func isSameEvent(_ a: String, _ b: String) async -> Bool {
        let na = Self.normalize(a), nb = Self.normalize(b)
        if na == nb { return true }
        // Deterministic rule decides the obvious cases FIRST — it always merges a clear
        // same-day duplicate (same closure / delayed opening / early dismissal) regardless
        // of whether Apple Intelligence is available or what a past AI verdict was cached as.
        // This keeps the merge predictable and immune to a stale cached "NO".
        if Self.heuristicSameEvent(na, nb) { return true }
        // Only genuinely ambiguous pairs reach the model (then cache its verdict).
        let cacheKey = [na, nb].sorted().joined(separator: "\u{1}")
        if let cached = EventMatchCache.shared.verdict(cacheKey) { return cached }
        if let verdict = await aiSameEvent(a, b) {
            EventMatchCache.shared.store(cacheKey, verdict)
            return verdict
        }
        return false
    }

    /// On-device verdict, or nil when Apple Intelligence can't answer (so we fall back).
    private func aiSameEvent(_ a: String, _ b: String) async -> Bool? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        guard case .available = SystemLanguageModel.default.availability else { return nil }

        let instructions = """
        You compare two entries from a school calendar. A school district and an individual \
        school often post the SAME real event under different names and capitalization — a \
        holiday closure, a delayed opening, an early dismissal, a conference. The two entries \
        you are given already fall on the same day. Decide whether they are the same real \
        event. Rules:
        - Wording and capitalization differences do not matter; meaning does.
        - A delayed opening and an early dismissal are NOT the same event.
        - Two genuinely different events that merely share a day are NOT the same.
        Answer with exactly one word: YES or NO.
        """
        let session = LanguageModelSession(instructions: instructions)
        let prompt = "Entry A: \"\(a)\"\nEntry B: \"\(b)\"\nSame real event? Answer YES or NO."
        do {
            let text = try await session.respond(to: prompt).content.uppercased()
            if text.contains("YES") { return true }
            if text.contains("NO") { return false }
            return nil
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: Deterministic fallback

    /// Keyword rule used when Apple Intelligence isn't available. Inputs are normalized.
    static func heuristicSameEvent(_ a: String, _ b: String) -> Bool {
        // Recognizable schedule change (closure / delayed opening / early dismissal)?
        if let sig = scheduleSignature(a), sig == scheduleSignature(b) {
            // Same kind of schedule change on the same day. Block only if each names a
            // DIFFERENT specific occasion (e.g. "thanksgiving" vs "winter break").
            if let oa = occasion(a), let ob = occasion(b), oa != ob { return false }
            return true
        }
        // Otherwise require strong overlap among meaningful words.
        let ta = meaningfulTokens(a), tb = meaningfulTokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        let shared = Double(ta.intersection(tb).count)
        let union = Double(ta.union(tb).count)
        return union > 0 && shared / union >= 0.5
    }

    private static func scheduleSignature(_ t: String) -> String? {
        if t.contains("delayed opening") { return "delayed" }
        if t.contains("early dismissal") || t.contains("half day") || t.contains("single session") { return "dismissal" }
        for k in ["no school", "closed", "holiday", "recess", "break", "vacation", "no classes"] where t.contains(k) { return "closure" }
        return nil
    }

    private static func occasion(_ t: String) -> String? {
        if t.contains("staff pd") || t.contains("professional development") || t.contains(" pd ") || t.hasSuffix(" pd") || t == "pd" { return "pd" }
        for k in ["thanksgiving", "winter", "spring", "summer", "columbus", "veterans", "memorial",
                  "labor", "presidents", "mlk", "martin luther", "rosh", "yom kippur", "diwali",
                  "lunar new year", "good friday", "election", "conference"] where t.contains(k) { return k }
        return nil
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "for", "of", "to", "in", "on", "at", "day", "days",
        "students", "student", "school", "schools", "district", "districts", "mms", "no",
        "is", "are", "this", "week", "all"
    ]

    private static func meaningfulTokens(_ t: String) -> Set<String> {
        Set(t.split(separator: " ").map(String.init).filter { $0.count > 1 && !stopWords.contains($0) })
    }

    /// Lowercase, turn dashes and punctuation into spaces, collapse runs of spaces.
    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }
}

/// Persists AI same-event verdicts per title-pair so the model is consulted at most once
/// for any given pairing. Backed by UserDefaults (JSON) — survives app upgrades.
final class EventMatchCache {
    static let shared = EventMatchCache()
    private let storeKey = "eventMatchVerdicts.v2"
    private var map: [String: Bool]

    private init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) {
            map = decoded
        } else {
            map = [:]
        }
    }

    func verdict(_ key: String) -> Bool? { map[key] }

    func store(_ key: String, _ value: Bool) {
        map[key] = value
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}

/// Normalizes calendar titles to proper (Title) case so entries read consistently and
/// cross-source duplicates look alike before de-duplication. The district feed SHOUTS
/// ("SCHOOLS AND DISTRICT CLOSED") while the school feed uses normal casing; this brings
/// the shouty ones down to "Schools and District Closed". Titles that already contain
/// lowercase letters are assumed intentional and left untouched. Known school acronyms
/// (PD, MMS, PTO…) are preserved in uppercase.
enum DisplayTitle {
    private static let minorWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "of", "on",
        "or", "the", "to", "vs", "with", "via", "per", "nor"
    ]
    private static let acronyms: Set<String> = [
        "pd", "mms", "hs", "ms", "es", "pto", "pta", "boe", "asc", "sgo", "iep", "ptc", "stem"
    ]

    static func proper(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        // Already mixed-case → intentional, leave as the source wrote it.
        if trimmed.contains(where: { $0.isLowercase }) { return trimmed }

        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var out: [String] = []
        for (i, w) in words.enumerated() {
            let lower = w.lowercased()
            let bare = lower.trimmingCharacters(in: CharacterSet(charactersIn: "()[]-–—:;,.!?\"'"))
            if acronyms.contains(bare) {
                out.append(w.uppercased())                             // keep acronyms shouting
            } else if i != 0 && i != words.count - 1 && minorWords.contains(bare) {
                out.append(lower)                                      // interior minor word
            } else {
                out.append(capitalizeFirstLetter(lower))
            }
        }
        return out.joined(separator: " ")
    }

    private static func capitalizeFirstLetter(_ s: String) -> String {
        var chars = Array(s)
        for i in chars.indices where chars[i].isLetter {
            chars[i] = Character(chars[i].uppercased())
            break
        }
        return String(chars)
    }
}
