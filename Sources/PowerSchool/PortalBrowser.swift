import Foundation
import WebKit

/// Drives the district's PowerSchool parent portal exactly like the parent's own browser would:
/// a (hidden) WKWebView signs in with the parent's saved login, opens the same pages the parent
/// can open, and hands us the rendered HTML. No PowerSchool server-side integration is needed and
/// no school data passes through any server of ours.
///
/// Why a web view instead of plain URLSession:
///  - the portal's sign-in form prepares the password in page JavaScript before posting
///  - newer portal versions render class score detail client-side from JSON
///  - SSO districts (Google / Clever / ClassLink) only work through a real browser
@MainActor
final class PortalBrowser: NSObject, WKNavigationDelegate {
    enum PortalError: LocalizedError {
        case signInRequired, timeout, unexpectedPage(String)
        var errorDescription: String? {
            switch self {
            case .signInRequired: "PowerSchool needs you to sign in again."
            case .timeout: "PowerSchool took too long to respond."
            case .unexpectedPage(let p): "PowerSchool showed an unexpected page (\(p))."
            }
        }
    }

    let baseURL: URL
    let webView: WKWebView
    private var pending: CheckedContinuation<Void, Error>?
    private var generation = 0

    init(baseURL: URL, dataStore: WKWebsiteDataStore = .nonPersistent()) {
        self.baseURL = baseURL
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    // MARK: Session

    /// Restores saved cookies, then (if needed) signs in again with the saved username/password.
    func ensureSignedIn(credential: PowerSchoolCredential) async throws -> PowerSchoolCredential {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for c in credential.cookies.compactMap(\.httpCookie) { await store.setCookie(c) }

        try await load(path: "guardian/home.html")
        if isOnGuardianPage { return credential }

        // Session expired. Districts with SSO can't be signed in silently: ask the parent.
        guard let user = credential.username, let pass = credential.password else {
            throw PortalError.signInRequired
        }
        try await load(path: "public/")
        try await submitSignIn(username: user, password: pass)
        guard isOnGuardianPage else { throw PortalError.signInRequired }

        var updated = credential
        let host = baseURL.host ?? ""
        updated.cookies = await store.allCookies()
            .filter { host.hasSuffix($0.domain.trimmingCharacters(in: ["."])) }
            .map(StoredCookie.init)
        return updated
    }

    var isOnGuardianPage: Bool { webView.url?.path.contains("/guardian/") == true }

    /// Field ids below match the stock PowerSchool sign-in page. Districts can customize it,
    /// so this is one of the first things to verify against a real portal (see README).
    private func submitSignIn(username: String, password: String) async throws {
        let js = """
        (function(u, p) {
          var a = document.getElementById('fieldAccount') || document.querySelector('input[name="account"]');
          var b = document.getElementById('fieldPassword') || document.querySelector('input[type="password"]');
          if (!a || !b) { return 'no-form'; }
          a.value = u; b.value = p;
          var btn = document.getElementById('btn-enter-sign-in') || document.querySelector('form button[type="submit"]');
          if (btn) { btn.click(); } else { a.form.submit(); }
          return 'ok';
        })(\(jsString(username)), \(jsString(password)));
        """
        try await navigate(timeout: 20) { [webView] in
            let result = try await webView.evaluateJavaScript(js) as? String
            if result != "ok" { throw PortalError.unexpectedPage("sign-in form not found") }
        }
    }

    // MARK: Pages

    func load(path: String) async throws {
        try await load(url: baseURL.appendingPathComponent(path))
    }

    func load(url: URL) async throws {
        try await navigate(timeout: 25) { [webView] in webView.load(URLRequest(url: url)) }
    }

    /// Switches the portal to another student on the same parent account using the page's own
    /// `switchStudent(id)` function, so we don't depend on its internal URL format.
    func switchStudent(id: String) async throws {
        let n = Int(id) ?? 0
        // Trailing `true` because evaluateJavaScript throws on an `undefined` result.
        try await navigate(timeout: 20) { [webView] in _ = try await webView.evaluateJavaScript("switchStudent(\(n)); true") }
    }

    /// Rendered DOM (after the page's own JavaScript ran). `settle` gives client-rendered pages
    /// such as class score detail a moment to fill in.
    func html(settle: Duration = .milliseconds(600)) async throws -> String {
        if settle > .zero { try await Task.sleep(for: settle) }
        return (try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String) ?? ""
    }

    // MARK: Navigation plumbing

    /// Runs `action` (which should start a main-frame navigation) and waits for it to finish.
    /// The continuation is registered before the action runs, so a fast load can't be missed.
    private func navigate(timeout seconds: Double, _ action: @escaping @MainActor () async throws -> Void) async throws {
        generation += 1
        let gen = generation
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pending = c
            Task { @MainActor in
                do { try await action() } catch { self.complete(gen, .failure(error)) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                self.complete(gen, .failure(PortalError.timeout))
            }
        }
    }

    /// Resumes the waiting navigation once. `gen == nil` means "whatever is pending" (delegate callbacks).
    private func complete(_ gen: Int?, _ result: Result<Void, Error>) {
        guard let c = pending, gen == nil || gen == generation else { return }
        pending = nil
        c.resume(with: result)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.complete(nil, .success(())) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.complete(nil, .failure(error)) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // A navigation cancelled by a newer one (e.g. JS redirect) isn't a failure.
        if (error as NSError).code == NSURLErrorCancelled { return }
        Task { @MainActor in self.complete(nil, .failure(error)) }
    }

    private func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())   // JSON-escaped string literal
    }
}
