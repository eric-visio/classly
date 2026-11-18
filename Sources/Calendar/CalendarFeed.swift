import Foundation

/// Finds the school calendar feed(s) behind whatever the parent pasted.
///
/// Most district sites (Apptegy/Thrillshare, Finalsite, Edlio, SchoolMessenger, Blackboard…)
/// don't publish events in the page HTML. They embed a Google or Outlook calendar, or offer a
/// Subscribe / iCal button. So we:
///   1. try the link directly (it may already be an .ics / webcal feed)
///   2. look in the raw HTML for feed links and embedded calendars
///   3. if nothing, open the page in a hidden web view (so its JavaScript runs, like Safari)
///      and look again in the rendered page
/// Every candidate is downloaded and checked, and the parent picks which ones to use
/// (a "District calendars" page often has one per school).
enum CalendarFeed {
    struct Found: Identifiable {
        var id: URL { feedURL }
        let feedURL: URL
        let name: String?            // X-WR-CALNAME from the feed, e.g. "Millburn Middle School"
        let upcoming: [ICSParser.Event]
        let total: Int
    }

    enum CheckError: LocalizedError {
        case notAURL, unreachable(String), noFeedFound
        var errorDescription: String? {
            switch self {
            case .notAURL: "That doesn't look like a web address."
            case .unreachable(let m): "Couldn't open the link (\(m))."
            case .noFeedFound: "No calendar was found on that page. If the school only posts its calendar as a PDF, the app can't read it. Look for a Subscribe, iCal or Google Calendar link on the page instead."
            }
        }
    }

    // MARK: Discover

    static func discover(_ raw: String) async throws -> [Found] {
        guard let url = ICSParser.normalizedFeedURL(raw), url.host != nil else { throw CheckError.notAURL }

        // 1. The link itself.
        let (text, finalURL) = try await fetch(url)
        if text.contains("BEGIN:VCALENDAR") { return [summarize(text, url: finalURL)] }

        // 2. Feeds referenced in the raw HTML.
        var found = await validate(candidates(inHTML: text, base: finalURL))
        if !found.isEmpty { return found }

        // 2b. Apptegy / Thrillshare districts publish a public events iCal on a service host,
        //     built from the org id. The id is in every page's raw HTML (e.g. "/o/18140/"),
        //     even though the generate_ical link itself only appears on the site's /events page.
        //     So we can construct the feed from whatever district page the parent pasted.
        found = await validate(thrillshareFeeds(inHTML: text, base: finalURL))
        if !found.isEmpty { return found }

        // 3. Rendered page (JavaScript sites like Thrillshare/Apptegy, Finalsite). We read the
        //    rendered DOM *and* the URLs the page actually requested (performance entries) and
        //    every link/iframe, so a feed built in JavaScript (e.g. .../generate_ical?...) is seen.
        let rendered = try await renderedContext(of: finalURL)
        found = await validate(candidates(inHTML: rendered, base: finalURL))
        if !found.isEmpty { return found }

        throw CheckError.noFeedFound
    }

    /// Downloads each candidate and keeps the ones that are real calendars with events.
    private static func validate(_ urls: [URL]) async -> [Found] {
        var out: [Found] = []
        for u in urls.prefix(12) {
            guard let response = try? await fetch(u), response.0.contains("BEGIN:VCALENDAR") else { continue }
            let f = summarize(response.0, url: response.1)
            if f.total > 0, !out.contains(where: { $0.feedURL == f.feedURL }) { out.append(f) }
        }
        return out
    }

    private static func summarize(_ text: String, url: URL) -> Found {
        let all = ICSParser.parse(text)
        let today = Calendar.current.startOfDay(for: .now)
        let upcoming = all.filter { $0.start >= today }.sorted { $0.start < $1.start }
        let name = text.components(separatedBy: .newlines)
            .first { $0.hasPrefix("X-WR-CALNAME:") }
            .map { String($0.dropFirst("X-WR-CALNAME:".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return Found(feedURL: url, name: name?.isEmpty == false ? name : nil, upcoming: upcoming, total: all.count)
    }

    // MARK: Find candidate feed URLs in a page

    static func candidates(inHTML html: String, base: URL) -> [URL] {
        let cleaned = html.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "\\/", with: "/")
        var out: [URL] = []
        func add(_ u: URL?) { if let u, !out.contains(u) { out.append(u) } }

        // Any URL-ish string in attributes, scripts or JSON on the page.
        let urlPattern = #"((?:https?:|webcal:)?//[^\s"'<>\\)]+|/[^\s"'<>\\)]*(?:\.ics|ical)[^\s"'<>\\)]*)"#
        guard let re = try? NSRegularExpression(pattern: urlPattern, options: [.caseInsensitive]) else { return [] }
        re.enumerateMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) { m, _, _ in
            guard let m, let r = Range(m.range(at: 1), in: cleaned) else { return }
            var s = String(cleaned[r])
            let l = s.lowercased()
            if l.hasPrefix("webcal:") { s = "https:" + s.dropFirst("webcal:".count) }
            if s.hasPrefix("//") { s = "https:" + s }
            guard let u = URL(string: s, relativeTo: base)?.absoluteURL else { return }

            // Google Calendar embed → public iCal feed for each calendar shown.
            if u.host?.contains("calendar.google.com") == true {
                for id in googleCalendarIDs(u) {
                    let enc = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "._-"))) ?? id
                    add(URL(string: "https://calendar.google.com/calendar/ical/\(enc)/public/basic.ics"))
                }
                if l.contains("/ical/") { add(u) }
                return
            }
            // Outlook / Office 365 published calendar → its .ics twin.
            if u.host?.contains("outlook") == true, u.path.hasSuffix("calendar.html") {
                add(URL(string: u.absoluteString.replacingOccurrences(of: "calendar.html", with: "calendar.ics")))
                return
            }
            if l.contains(".ics") || l.contains("webcal:") || l.contains("ical") || l.contains("format=ics") || l.contains("icalendar") {
                add(u)
            }
        }
        return out
    }

    /// For an Apptegy/Thrillshare district site, the public events iCal feed(s), built from the
    /// numeric org id found in the page. Works from any page of the district site (home, a page,
    /// or /events) and needs no login — the feed is public and cookieless.
    static func thrillshareFeeds(inHTML html: String, base: URL) -> [URL] {
        let host = base.host ?? ""
        let isThrillshare = host.contains("thrillshare.com") || host.contains("apptegy")
            || html.contains("thrillshare") || html.contains("apptegy") || html.contains("cmsv2")
        guard isThrillshare else { return [] }

        var ids = Set<String>()
        for pattern in [#"/o/(\d+)/"#, #"uploads/(\d+)/"#] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            re.enumerateMatches(in: html, range: NSRange(html.startIndex..., in: html)) { m, _, _ in
                guard let m, let r = Range(m.range(at: 1), in: html) else { return }
                ids.insert(String(html[r]))
            }
        }
        return ids.sorted().compactMap {
            URL(string: "https://thrillshare-cmsv2.services.thrillshare.com/api/v4/o/\($0)/cms/events/generate_ical")
        }
    }

    /// `src=` (can repeat) or `cid=` (base64 of the id) on a Google Calendar URL.
    static func googleCalendarIDs(_ u: URL) -> [String] {
        let items = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var ids = items.filter { $0.name == "src" }.compactMap(\.value)
        for cid in items.filter({ $0.name == "cid" }).compactMap(\.value) {
            var b = cid; while b.count % 4 != 0 { b += "=" }
            if let d = Data(base64Encoded: b), let s = String(data: d, encoding: .utf8), s.contains("@") { ids.append(s) }
            else if cid.contains("@") { ids.append(cid) }
        }
        return ids.map { $0.removingPercentEncoding ?? $0 }
    }

    // MARK: Network

    private static func fetch(_ url: URL) async throws -> (String, URL) {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("text/calendar, text/html;q=0.8, */*;q=0.5", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(code) else { throw CheckError.unreachable("error \(code)") }
            return (String(decoding: data, as: UTF8.self), resp.url ?? url)
        } catch let e as CheckError {
            throw e
        } catch {
            throw CheckError.unreachable(error.localizedDescription)
        }
    }

    @MainActor
    private static func renderedContext(of url: URL) async throws -> String {
        let browser = PortalBrowser(baseURL: url)
        try await browser.load(url: url)
        // Calendar widgets usually load a second or two after the page.
        let html = try await browser.html(settle: .seconds(4))
        // Also collect requested resource URLs and all link/iframe targets — a JS-built feed URL
        // (Google embed, Apptegy generate_ical, .ics) shows up here even when it's not in the DOM.
        let js = """
        (function(){
          var out = [];
          try { out = out.concat(performance.getEntriesByType('resource').map(function(e){return e.name;})); } catch(e){}
          try { out = out.concat([].slice.call(document.querySelectorAll('a[href],iframe[src],link[href]')).map(function(e){return e.href||e.src||'';})); } catch(e){}
          return out.join('\\n');
        })();
        """
        let extras = (try? await browser.webView.evaluateJavaScript(js)) as? String ?? ""
        return html + "\n" + extras
    }
}
