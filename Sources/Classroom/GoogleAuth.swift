import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

/// Google sign-in for a kid's school account using OAuth 2.0 for installed apps (PKCE, no
/// client secret). The browser sheet is Google's own page; we never see the password.
/// Tokens are stored per kid in the Keychain.
@MainActor
final class GoogleAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let scopes = [
        "openid", "email",
        "https://www.googleapis.com/auth/classroom.courses.readonly",
        "https://www.googleapis.com/auth/classroom.coursework.me.readonly",
        "https://www.googleapis.com/auth/classroom.announcements.readonly",
    ]

    enum AuthError: LocalizedError {
        case blockedBySchool, cancelled, failed(String)
        var errorDescription: String? {
            switch self {
            case .blockedBySchool: "Your child's school hasn't approved this app for student accounts yet."
            case .cancelled: "Sign-in was cancelled."
            case .failed(let m): m
            }
        }
    }

    private var clientID: String { Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String ?? "" }
    private var redirectScheme: String { clientID.components(separatedBy: ".").reversed().joined(separator: ".") }
    private var redirectURI: String { "\(redirectScheme):/oauthredirect" }

    /// Opens Google sign-in for one kid. `emailHint` pre-fills their school address.
    func signIn(emailHint: String?) async throws -> GoogleTokens {
        guard clientID.hasSuffix(".apps.googleusercontent.com"), !clientID.contains("REPLACE"),
              let schemes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
              schemes.contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains(redirectScheme) == true })
        else {
            throw AuthError.failed("Google sign-in isn't set up in this build yet. Add your iOS OAuth client ID to project.yml (GIDClientID and the reversed ID under CFBundleURLSchemes), run xcodegen, and rebuild.")
        }
        let verifier = Self.randomURLSafe(32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "prompt", value: "select_account consent"),
        ] + (emailHint.map { [URLQueryItem(name: "login_hint", value: $0)] } ?? [])

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: redirectScheme) { url, err in
                if let url { cont.resume(returning: url) }
                else if (err as? ASWebAuthenticationSessionError)?.code == .canceledLogin { cont.resume(throwing: AuthError.cancelled) }
                else { cont.resume(throwing: AuthError.failed(err?.localizedDescription ?? "Unknown error")) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true   // don't mix with the parent's own Google login
            session.start()
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            // Under-18 Workspace for Education accounts get these when the school hasn't configured the app.
            if ["admin_policy_enforced", "access_not_configured", "access_denied"].contains(error) {
                throw AuthError.blockedBySchool
            }
            throw AuthError.failed(error)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw AuthError.failed("No code returned") }

        var tokens = try await tokenRequest([
            "code": code, "client_id": clientID, "redirect_uri": redirectURI,
            "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        tokens.email = tokens.email ?? emailHint
        return tokens
    }

    /// Returns a valid access token, refreshing it if needed (used by the background refresh).
    func validAccessToken(keychainKey: String) async throws -> String {
        guard var t = Keychain.get(GoogleTokens.self, for: keychainKey) else { throw AuthError.failed("Not signed in") }
        if t.expiry > .now.addingTimeInterval(60) { return t.accessToken }
        guard let refresh = t.refreshToken else { throw AuthError.failed("Sign-in expired") }
        let fresh = try await tokenRequest(["refresh_token": refresh, "client_id": clientID, "grant_type": "refresh_token"])
        t.accessToken = fresh.accessToken; t.expiry = fresh.expiry
        try Keychain.set(t, for: keychainKey)
        return t.accessToken
    }

    private func tokenRequest(_ form: [String: String]) async throws -> GoogleTokens {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        struct R: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double; let id_token: String? }
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("admin_policy_enforced") { throw AuthError.blockedBySchool }
            throw AuthError.failed("Google sign-in failed")
        }
        let r = try JSONDecoder().decode(R.self, from: data)
        return GoogleTokens(accessToken: r.access_token, refreshToken: r.refresh_token,
                            expiry: .now.addingTimeInterval(r.expires_in), email: r.id_token.flatMap(Self.emailFromIDToken))
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }

    private static func emailFromIDToken(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["email"] as? String
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var s = CharacterSet.urlQueryAllowed; s.remove(charactersIn: "&+=?/"); return s
    }()
}
