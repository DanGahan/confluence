import Foundation
import os

private let log = Logger(subsystem: "com.dangahan.confluence", category: "mastodon")

/// A registered OAuth client on a Mastodon instance. The secret is sensitive — Keychain only.
public struct MastodonApp: Codable, Sendable, Equatable {
    public let clientId: String
    public let clientSecret: String

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientSecret = "client_secret"
    }
}

/// A logged-in Mastodon account: which instance, its OAuth client, and the access token.
/// Persisted (JSON) in the Keychain — never logged.
public struct MastodonSession: Codable, Sendable, Equatable {
    public let host: String
    public let app: MastodonApp
    public var accessToken: String
}

public enum MastodonError: Error, Equatable, LocalizedError {
    case invalidInstance
    case registrationFailed
    case stateMismatch
    case authorizationDenied
    case tokenExchangeFailed
    case network
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidInstance:
            return "That doesn't look like a Mastodon server. Enter a domain like mastodon.social."
        case .registrationFailed:
            return "Couldn't register with that server. Please try again."
        case .stateMismatch:
            return "Sign in couldn't be verified. Please try again."
        case .authorizationDenied:
            return "Sign in was cancelled or denied."
        case .tokenExchangeFailed:
            return "The server rejected the sign-in. Please try again."
        case .network:
            return "Couldn't reach that server. Check the domain and your connection."
        case .malformedResponse:
            return "The server returned an unexpected response."
        }
    }
}

/// Mastodon REST client for the OAuth flow.
public struct MastodonClient: Sendable {
    public static let redirectURI = "confluence://oauth-callback"
    public static let callbackScheme = "confluence"
    public static let scopes = "read write follow"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Normalizes user input ("https://Mastodon.Social/", "@host") to a bare host.
    public static func normalizeHost(_ input: String) throws -> String {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let schemeRange = host.range(of: "://") { host = String(host[schemeRange.upperBound...]) }
        host = host.components(separatedBy: "/").first ?? host
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !host.isEmpty, host.contains("."), !host.contains(" ") else {
            throw MastodonError.invalidInstance
        }
        return host
    }

    /// Confirms the host actually answers as a Mastodon instance before opening a browser.
    public func validateInstance(host: String) async throws {
        let request = URLRequest(url: try url(host: host, path: "/api/v1/instance"))
        let (_, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else { throw MastodonError.invalidInstance }
    }

    /// `POST /api/v1/apps` — dynamic client registration.
    public func registerApp(host: String) async throws -> MastodonApp {
        var request = URLRequest(url: try url(host: host, path: "/api/v1/apps"))
        request.httpMethod = "POST"
        request.setFormBody([
            "client_name": "Confluence",
            "redirect_uris": Self.redirectURI,
            "scopes": Self.scopes,
            "website": "https://github.com/DanGahan/confluence",
        ])
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            log.error("registerApp failed: status \(response.statusCode, privacy: .public)")
            throw MastodonError.registrationFailed
        }
        return try decode(MastodonApp.self, from: data)
    }

    public func authorizationURL(host: String, clientId: String, state: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/oauth/authorize"
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else { throw MastodonError.invalidInstance }
        return url
    }

    /// `POST /oauth/token` — exchanges the authorization code for an access token.
    public func exchangeCode(_ code: String, host: String, app: MastodonApp) async throws -> String {
        var request = URLRequest(url: try url(host: host, path: "/oauth/token"))
        request.httpMethod = "POST"
        request.setFormBody([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": app.clientId,
            "client_secret": app.clientSecret,
            "redirect_uri": Self.redirectURI,
            "scope": Self.scopes,
        ])
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            log.error("token exchange failed: status \(response.statusCode, privacy: .public)")
            throw MastodonError.tokenExchangeFailed
        }
        return try decode(TokenResponse.self, from: data).accessToken
    }

    /// `POST /oauth/revoke` — best-effort token revocation on logout.
    public func revoke(session: MastodonSession) async {
        guard var request = try? URLRequest(url: url(host: session.host, path: "/oauth/revoke")) else { return }
        request.httpMethod = "POST"
        request.setFormBody([
            "client_id": session.app.clientId,
            "client_secret": session.app.clientSecret,
            "token": session.accessToken,
        ])
        _ = try? await perform(request)
    }

    // MARK: - Helpers

    private func url(host: String, path: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        guard let url = components.url else { throw MastodonError.invalidInstance }
        return url
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MastodonError.network
        }
        guard let http = response as? HTTPURLResponse else { throw MastodonError.malformedResponse }
        return (data, http)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MastodonError.malformedResponse
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }
}

private extension URLRequest {
    mutating func setFormBody(_ fields: [String: String]) {
        setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        httpBody = components.percentEncodedQuery?.data(using: .utf8)
    }
}
