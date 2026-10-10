import CryptoKit
import Foundation

/// The developer's own service (a separate, private repository): sign in with an email or Google (Cognito), a few free
/// requests a day, more with a subscription (Stripe). Fill these in from `sam deploy`'s outputs and
/// the Stripe dashboard; while `baseURL` is empty, the provider isn't offered.
public enum HostedService {
    /// The function URL (output `Url`).
    public static let baseURL = "https://nijsd6m4tyals3k4odja2fj7be0vmvhm.lambda-url.us-west-2.on.aws"
    /// The sign-in page's host (output `AuthDomain`), e.g. "allinoneime-you.auth.us-east-1.amazoncognito.com".
    public static let authDomain = "allinoneime-c5d745.auth.us-west-2.amazoncognito.com"
    /// The app client of the user pool (output `ClientId`).
    public static let clientId = "7iesei7paeg1gur2sfu74q8omd"
    /// Whether the pool offers "Sign in with Google" (deployed with GoogleClientId).
    public static let googleEnabled = false
    /// The Stripe payment link of the subscription ($3 a month for 3000 requests).
    public static let paymentLink = "https://buy.stripe.com/8x29AU1bY3nd2Ig1aTdEs00"
    /// The Stripe customer portal's login link, where subscribers cancel or change their card.
    public static let portalLink = "https://billing.stripe.com/p/login/8x29AU1bY3nd2Ig1aTdEs00"

    public static var isConfigured: Bool { !baseURL.isEmpty && !authDomain.isEmpty && !clientId.isEmpty }

    /// Where the sign-in page sends the user back (an app client callback URL in the template).
    public static let callbackScheme = "allinoneime"
    public static let redirectURI = "allinoneime://auth"

    /// The checkout page for the user (Stripe sends their ID back with the payment).
    public static func checkoutURL(sub: String, email: String?, link: String = paymentLink) -> URL? {
        guard var components = URLComponents(string: link), !link.isEmpty else { return nil }
        components.queryItems = [URLQueryItem(name: "client_reference_id", value: sub)]
            + (email.map { [URLQueryItem(name: "prefilled_email", value: $0)] } ?? [])
        return components.url
    }
}

/// Signing in on the user pool's page in the browser: the authorization code flow with PKCE, back to
/// allinoneime://auth. The page signs in or signs up with an email (confirmed with a code), or goes
/// straight to Google (`Method.google`). The code becomes an ID token, which the service checks.
public struct HostedSignIn: Sendable {
    public enum Method: Sendable {
        /// The sign-in page: email and password, with "Sign up" and "Forgot your password?".
        case email
        case google
    }

    public let domain: String
    public let clientId: String
    public let verifier: String
    public let state: String

    public init(domain: String = HostedService.authDomain, clientId: String = HostedService.clientId) {
        self.domain = domain
        self.clientId = clientId
        verifier = Self.random(32)
        state = Self.random(16)
    }

    /// The page to open in the browser.
    public func authorizationURL(_ method: Method) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = domain
        components.path = "/oauth2/authorize"
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        components.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: HostedService.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ] + (method == .google ? [.init(name: "identity_provider", value: "Google")] : [])
        return components.url!
    }

    /// The code in the redirect, if it is the answer to this sign-in.
    public func code(from callback: URL) -> String? {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else { return nil }
        return items.first { $0.name == "code" }?.value
    }

    /// Exchanges the code for the pool's ID token.
    public func idToken(for code: String, session: URLSession = .shared) async throws -> String {
        var components = URLComponents()
        components.scheme = "https"
        components.host = domain
        components.path = "/oauth2/token"
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "grant_type", value: "authorization_code"), .init(name: "client_id", value: clientId),
            .init(name: "code", value: code), .init(name: "code_verifier", value: verifier),
            .init(name: "redirect_uri", value: HostedService.redirectURI),
        ]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await session.data(for: request)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let token = object?["id_token"] as? String else {
            throw ProviderError.http(provider: .hosted, status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                     type: object?["error"] as? String, message: object?["error_description"] as? String ?? "Sign-in failed")
        }
        return token
    }

    static func random(_ bytes: Int) -> String {
        Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).base64URL
    }
}

/// The signed-in account: its allowance, and signing in with the pool's ID token.
public struct HostedAccount: Codable, Equatable, Sendable {
    public var email: String?
    public var freeLimit: Int
    public var freeRemaining: Int
    public var credits: Int
    public var plan: String
    /// The user's ID (from the session token), for the checkout.
    public var sub: String?

    public var isSubscribed: Bool { plan == "plus" }

    /// Signs in with the pool's ID token: the service's session token is stored in the keychain.
    public static func signIn(idToken: String, baseURL: String = HostedService.baseURL,
                              session: URLSession = .shared) async throws -> HostedAccount {
        let body = try JSONSerialization.data(withJSONObject: ["idToken": idToken])
        let object = try await call("/login", method: "POST", body: body, token: nil, baseURL: baseURL, session: session)
        guard let token = object["token"] as? String else { throw ProviderError.invalidResponse(.hosted, "no token") }
        try APIKeys.save(token, for: .hosted)
        return try account(object, token: token)
    }

    /// The allowance as of now; nil when signed out.
    public static func current(baseURL: String = HostedService.baseURL, session: URLSession = .shared) async throws -> HostedAccount? {
        guard let token = APIKeys.keychainKey(.hosted) else { return nil }
        do {
            return try account(try await call("/me", method: "GET", body: nil, token: token, baseURL: baseURL, session: session), token: token)
        } catch ProviderError.signedOut {
            try? APIKeys.save("", for: .hosted)
            return nil
        }
    }

    public static func signOut() throws { try APIKeys.save("", for: .hosted) }

    static func account(_ object: [String: Any], token: String) throws -> HostedAccount {
        let data = try JSONSerialization.data(withJSONObject: object)
        var account = try JSONDecoder().decode(HostedAccount.self, from: data)
        account.sub = sessionSubject(token)
        return account
    }

    /// The user ID inside a session token ("v1.<payload>.<mac>"; the payload is plain JSON).
    static func sessionSubject(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let data = Data(base64URL: String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["sub"] as? String
    }

    static func call(_ path: String, method: String, body: Data?, token: String?, baseURL: String,
                     session: URLSession) async throws -> [String: Any] {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + path), url.host != nil else { throw ProviderError.invalidBaseURL(baseURL) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPProviders.httpError(provider: .hosted, status: status, body: Array(data))
        }
        return object
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
