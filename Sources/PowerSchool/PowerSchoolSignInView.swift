import SwiftUI
import WebKit

/// Shows the district's real PowerSchool sign-in page. When the parent lands on the guardian
/// home page we capture the session cookies, and (for username/password districts) the login
/// they typed, so the daily refresh can sign in again. Everything goes to the Keychain.
struct PowerSchoolSignInView: UIViewRepresentable {
    let baseURL: URL
    var onSignedIn: (_ credential: PowerSchoolCredential, _ homeHTML: String, _ usedSSO: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Remember what the parent typed into the stock sign-in form (only on this page, only on submit).
        let capture = """
        document.addEventListener('submit', function () {
          var a = document.getElementById('fieldAccount') || document.querySelector('input[name="account"]');
          var b = document.getElementById('fieldPassword') || document.querySelector('input[type="password"]');
          if (a && b) { window.webkit.messageHandlers.login.postMessage({u: a.value, p: b.value}); }
        }, true);
        """
        config.userContentController.addUserScript(WKUserScript(source: capture, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.add(context.coordinator, name: "login")

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: baseURL.appendingPathComponent("public/")))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: PowerSchoolSignInView
        var typed: (String, String)?
        var leftPortalHost = false
        var done = false

        init(_ parent: PowerSchoolSignInView) { self.parent = parent }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            if let d = message.body as? [String: String], let u = d["u"], let p = d["p"], !u.isEmpty {
                typed = (u, p)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            if url.host != parent.baseURL.host { leftPortalHost = true }   // went to Google/Clever SSO
            guard !done, url.host == parent.baseURL.host, url.path.contains("/guardian/") else { return }
            done = true
            Task { @MainActor in
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                    .filter { url.host?.hasSuffix($0.domain.trimmingCharacters(in: ["."])) ?? false }
                let html = (try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String) ?? ""
                let usedSSO = typed == nil && leftPortalHost
                let cred = PowerSchoolCredential(username: typed?.0, password: typed?.1,
                                                 cookies: cookies.map(StoredCookie.init))
                parent.onSignedIn(cred, html, usedSSO)
            }
        }
    }
}
