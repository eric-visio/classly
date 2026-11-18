import Foundation
import SwiftSoup

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Fetches a PTO newsletter (from its public permalink) and produces an on-device summary.
///
/// The newsletter permalinks are public, so the fetch needs no login. Summarizing runs on the
/// phone with Apple Intelligence when available, and falls back to a clean templated summary
/// (first lines + pulled-out "important dates") everywhere else. Nothing leaves the device.
enum NewsletterSummarizer {

    struct Content {
        var bodyText: String
        var publishedAt: Date?
        var keyDates: [String]
    }

    // MARK: Fetch + extract

    static func fetch(_ url: URL) async -> Content? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let html = String(data: data, encoding: .utf8) else { return nil }
        guard let doc = try? SwiftSoup.parse(html) else { return nil }

        // Prefer the rich-text newsletter blocks; fall back to the whole body.
        var body = ""
        if let blocks = try? doc.select(".mtk-nl-rich-text-editable"), blocks.size() > 0 {
            body = blocks.array().compactMap { try? $0.text() }.joined(separator: "\n\n")
        }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).count < 40 {
            body = (try? doc.body()?.text()) ?? ""
        }
        let fullText = (try? doc.body()?.text()) ?? body

        return Content(bodyText: body,
                       publishedAt: publishedDate(in: fullText),
                       keyDates: keyDates(in: fullText))
    }

    /// "Originally delivered on 11/9/2026 7:01 am" → a Date.
    private static func publishedDate(in text: String) -> Date? {
        if let m = text.range(of: #"delivered on\s+(\d{1,2})/(\d{1,2})/(\d{4})"#, options: .regularExpression) {
            let nums = text[m].components(separatedBy: CharacterSet(charactersIn: "/ ")).compactMap { Int($0) }
            if nums.count >= 3 { return date(month: nums[0], day: nums[1], year: nums[2]) }
        }
        return nil
    }

    /// Lines under "Important dates" that start with a month — kept short and literal.
    private static func keyDates(in text: String) -> [String] {
        let months = "JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC|JANUARY|FEBRUARY|MARCH|APRIL|JUNE|JULY|AUGUST|SEPTEMBER|OCTOBER|NOVEMBER|DECEMBER"
        let lines = text.components(separatedBy: CharacterSet(charactersIn: "\n•")).map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        for l in lines where (4...120).contains(l.count) {
            if l.range(of: "^(\(months))\\b", options: [.regularExpression, .caseInsensitive]) != nil {
                out.append(l)
                if out.count >= 6 { break }
            }
        }
        return out
    }

    private static func date(month: Int, day: Int, year: Int) -> Date? {
        var c = DateComponents(); c.month = month; c.day = day; c.year = year; c.hour = 9
        return Calendar.current.date(from: c)
    }

    // MARK: Summarize

    /// Returns (summary, usedAI). Always returns a usable summary.
    static func summarize(title: String, content: Content) async -> (text: String, byAI: Bool) {
        if let ai = await aiSummary(title: title, content: content) { return (ai, true) }
        return (templated(title: title, content: content), false)
    }

    static func templated(title: String, content: Content) -> String {
        let clean = content.bodyText
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // First ~2 sentences.
        let sentences = clean.components(separatedBy: CharacterSet(charactersIn: ".!?")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 20 }
        let lead = sentences.prefix(2).joined(separator: ". ")
        if !lead.isEmpty { return lead.count > 280 ? String(lead.prefix(277)) + "…" : lead + "." }
        return "Open the newsletter to read this week's PTO update."
    }

    private static func aiSummary(title: String, content: Content) async -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        let body = content.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count > 60 else { return nil }
        guard case .available = SystemLanguageModel.default.availability else { return nil }

        let instructions = """
        You summarize a school PTO newsletter for a busy parent, shown as a card in an app. Rules:
        - Use ONLY the newsletter text provided. Never invent events, dates, or details.
        - 2 to 3 short sentences. Warm, plain, specific. No bullet points or headers.
        - Lead with what a parent most needs to act on (deadlines, sign-ups, dates).
        - Don't restate the title. No greetings or sign-offs.
        """
        let prompt = "Title: \(title)\n\nNewsletter:\n\(String(body.prefix(3500)))"
        let session = LanguageModelSession(instructions: instructions)
        do {
            let resp = try await session.respond(to: prompt)
            let t = resp.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}
