import Foundation
import WebKit

/// Drives the PTO's Membership Toolkit site in a WKWebView, exactly like the parent's own browser.
///
/// The parent signs in once on Membership Toolkit's own login page (we never see the password);
/// we keep the resulting session cookies. With those we:
///   - discover the main parent **calendar feed** URL from the Subscriptions page (one time — the
///     feed is public/cookieless, so after that the daily sync fetches it with no login), and
///   - scrape the **newsletter list** for the parent's grade(s).
///
/// Nothing goes through any server of ours; this all runs on the phone.
///
/// NOTE FOR MAINTAINERS: the CSS/text selectors below match Membership Toolkit's markup as of
/// the Nov-2026 inspection of millburnmspto.membershiptoolkit.com. If MT restyles, update the
/// small JS scrapers here (kept isolated on purpose) — the rest of the app is unaffected.
@MainActor
final class PTOPortal: NSObject, WKNavigationDelegate {
    enum PTOError: LocalizedError {
        case notSignedIn, timeout, noCalendarFound
        var errorDescription: String? {
            switch self {
            case .notSignedIn: "Please sign in to the PTO site."
            case .timeout: "The PTO site took too long to respond."
            case .noCalendarFound: "Couldn't find the PTO calendar on your account."
            }
        }
    }

    struct NewsletterRef: Codable { let permalink: String; let url: String; let title: String }
    struct GradeRef: Codable { let label: String; let path: String }

    let host: String
    let webView: WKWebView
    private var pending: CheckedContinuation<Void, Error>?
    private var generation = 0

    init(host: String) {
        self.host = host
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Safari/604.1"
    }

    private var base: URL { URL(string: "https://\(host)/")! }

    // MARK: Session

    func restore(cookies: [StoredCookie]) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for c in cookies.compactMap(\.httpCookie) { await store.setCookie(c) }
    }

    func capturedCookies() async -> [StoredCookie] {
        let all = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        return all.filter { host.hasSuffix($0.domain.trimmingCharacters(in: ["."])) }.map(StoredCookie.init)
    }

    /// True when the current page shows a logged-in Membership Toolkit session.
    func isSignedIn() async -> Bool {
        let js = "(/Logged in as/i.test(document.body.innerText) || !!document.querySelector('a[href*=\"logout\" i]')) ? 'yes' : 'no'"
        let r = (try? await webView.evaluateJavaScript(js)) as? String
        return r == "yes"
    }

    // MARK: Discovery / scraping

    /// Loads the Subscriptions page and returns the main **parent** calendar feed (webcal/ICS),
    /// skipping the Executive Board and per-weekday After-School-Clubs calendars.
    func discoverCalendarFeed() async throws -> URL {
        try await load(path: "user_subscriptions")
        guard await isSignedIn() else { throw PTOError.notSignedIn }
        let js = """
        (function(){
          var links = Array.prototype.slice.call(document.querySelectorAll('a'))
            .filter(function(a){ return /\\/subscription\\/[^/]+\\/cal\\/\\d+/.test(a.href); });
          function label(a){ var n=a; for (var i=0;i<5&&n;i++){ n=n.parentElement;
            if(n){ var t=(n.innerText||'').replace(/subscribe/ig,'').trim(); if(t && t.length<180) return t; } } return ''; }
          var main=null, fallback=null;
          for (var i=0;i<links.length;i++){ var l=label(links[i]).toLowerCase();
            if(/executive|board meeting|\\basc\\b|monday|tuesday|wednesday|thursday|friday/.test(l)) continue;
            if(/pto calendar|events|activities/.test(l)) { main=links[i].href; break; }
            if(!fallback) fallback=links[i].href;
          }
          return main || fallback || '';
        })()
        """
        let raw = ((try? await webView.evaluateJavaScript(js)) as? String) ?? ""
        let https = raw.replacingOccurrences(of: "webcal://", with: "https://")
        guard let url = URL(string: https), url.host != nil else { throw PTOError.noCalendarFound }
        return url
    }

    /// The grade newsletter lists available on this site (e.g. "6th Grade" → /newsletters/31952).
    func discoverGrades() async throws -> [GradeRef] {
        try await load(path: "newsletters")
        let js = """
        (function(){
          var out=[];
          var as=document.querySelectorAll('a');
          for (var i=0;i<as.length;i++){ var a=as[i]; var t=(a.innerText||'').trim();
            var m=t.match(/^(\\d)(st|nd|rd|th)\\s+Grade$/i);
            if(m && /\\/newsletters\\/\\d+/.test(a.href)){ out.push({label:t, path:new URL(a.href).pathname}); }
          }
          var seen={}, uniq=[];
          for (var j=0;j<out.length;j++){ if(!seen[out[j].path]){ seen[out[j].path]=1; uniq.push(out[j]); } }
          return JSON.stringify(uniq);
        })()
        """
        let raw = ((try? await webView.evaluateJavaScript(js)) as? String) ?? "[]"
        return decodeJSON([GradeRef].self, raw) ?? []
    }

    /// Newsletter entries (title + permalink) on one grade's list page.
    func scrapeNewsletters(gradePath: String) async throws -> [NewsletterRef] {
        try await load(path: String(gradePath.drop(while: { $0 == "/" })))
        guard await isSignedIn() else { throw PTOError.notSignedIn }
        let js = """
        (function(){
          var out=[], seen={};
          var as=document.querySelectorAll('a[href*="/newsletter/"]');
          for (var i=0;i<as.length;i++){ var a=as[i]; var u;
            try{ u=new URL(a.href); }catch(e){ continue; }
            if(!/\\/newsletter\\//.test(u.pathname)) continue;
            var t=(a.innerText||'').trim(); if(!t) continue;
            if(seen[u.pathname]) continue; seen[u.pathname]=1;
            out.push({permalink:u.pathname, url:u.origin+u.pathname, title:t.slice(0,150)});
          }
          return JSON.stringify(out.slice(0,25));
        })()
        """
        let raw = ((try? await webView.evaluateJavaScript(js)) as? String) ?? "[]"
        return decodeJSON([NewsletterRef].self, raw) ?? []
    }

    // MARK: Plumbing

    func load(path: String) async throws {
        try await navigate(timeout: 25) { [webView, base] in
            webView.load(URLRequest(url: base.appendingPathComponent(path)))
        }
    }

    func loadHome() async throws {
        try await navigate(timeout: 25) { [webView, base] in webView.load(URLRequest(url: base)) }
    }

    private func navigate(timeout seconds: Double, _ action: @escaping @MainActor () -> Void) async throws {
        generation += 1
        let gen = generation
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pending = c
            action()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                self.complete(gen, .failure(PTOError.timeout))
            }
        }
    }

    private func complete(_ gen: Int?, _ result: Result<Void, Error>) {
        guard let c = pending, gen == nil || gen == generation else { return }
        pending = nil
        c.resume(with: result)
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, _ s: String) -> T? {
        guard let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.complete(nil, .success(())) }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.complete(nil, .failure(error)) }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        Task { @MainActor in self.complete(nil, .failure(error)) }
    }
}
