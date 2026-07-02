import Foundation
import os

private let log = Logger(subsystem: "com.dangahan.confluence", category: "bluesky")

/// A logged-in AT Protocol session. Persisted (JSON) in the Keychain — never logged.
public struct BlueskySession: Codable, Sendable, Equatable {
    public let did: String
    public let handle: String
    public var accessJwt: String
    public var refreshJwt: String
}

public enum BlueskyError: Error, Equatable, LocalizedError {
    case invalidCredentials
    case twoFactorRequired
    case server(String)
    case network
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Incorrect handle or app password. Use your full handle (e.g. alice.bsky.social) and an app password from bsky.app — not your main password."
        case .twoFactorRequired:
            return "This account needs a sign-in code. App passwords bypass 2FA — create one at bsky.app → Settings → App Passwords and use that."
        case .server(let message):
            return message
        case .network:
            return "Couldn't reach Bluesky. Check your connection and try again."
        case .malformedResponse:
            return "Bluesky returned an unexpected response."
        }
    }
}

/// Minimal AT Protocol XRPC client for authentication.
/// Treats all responses as hostile: typed decode, no crashes on malformed input.
public struct BlueskyClient: Sendable {
    public let pdsURL: URL
    let session: URLSession

    public init(pdsURL: URL = URL(string: "https://bsky.social")!, session: URLSession = .shared) {
        self.pdsURL = pdsURL
        self.session = session
    }

    /// `com.atproto.server.createSession` — exchanges handle + app password for tokens.
    public func createSession(identifier: String, appPassword: String) async throws -> BlueskySession {
        var request = xrpcRequest("com.atproto.server.createSession")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["identifier": identifier, "password": appPassword]
        )
        return try await send(request)
    }

    /// `com.atproto.server.refreshSession` — swaps a refresh JWT for fresh tokens.
    // ponytail: the store calls this explicitly; the automatic 401-retry interceptor
    // belongs to the feed networking layer (F3), not here.
    public func refreshSession(refreshJwt: String) async throws -> BlueskySession {
        var request = xrpcRequest("com.atproto.server.refreshSession")
        request.setValue("Bearer \(refreshJwt)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    private func xrpcRequest(_ method: String) -> URLRequest {
        var request = URLRequest(url: pdsURL.appending(path: "xrpc/\(method)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func send(_ request: URLRequest) async throws -> BlueskySession {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BlueskyError.network
        }
        guard let http = response as? HTTPURLResponse else { throw BlueskyError.malformedResponse }

        guard (200..<300).contains(http.statusCode) else {
            let xrpcError = try? JSONDecoder().decode(XRPCError.self, from: data)
            // Error codes are public (no secrets); helps diagnose sign-in failures.
            log.error("XRPC \(request.url?.lastPathComponent ?? "?", privacy: .public) failed: status \(http.statusCode, privacy: .public) error \(xrpcError?.error ?? "nil", privacy: .public)")
            if xrpcError?.error == "AuthFactorTokenRequired" {
                throw BlueskyError.twoFactorRequired
            }
            if http.statusCode == 401 || xrpcError?.error == "AuthenticationRequired" {
                throw BlueskyError.invalidCredentials
            }
            throw BlueskyError.server(xrpcError?.message ?? "Bluesky returned status \(http.statusCode).")
        }

        do {
            return try JSONDecoder().decode(BlueskySession.self, from: data)
        } catch {
            throw BlueskyError.malformedResponse
        }
    }

    private struct XRPCError: Decodable {
        let error: String?
        let message: String?
    }
}
