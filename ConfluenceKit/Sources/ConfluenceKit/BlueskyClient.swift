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
    case rateLimited
    case server(String)
    case network
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Incorrect handle or app password. Use your full handle (e.g. alice.bsky.social) and an app password from bsky.app — not your main password."
        case .twoFactorRequired:
            return "This account needs a sign-in code. App passwords bypass 2FA — create one at bsky.app → Settings → App Passwords and use that."
        case .rateLimited:
            return "Bluesky is rate-limiting requests. Try again in a moment."
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
    let nonceStore: DPoPNonceStore

    public init(pdsURL: URL = URL(string: "https://bsky.social")!, session: URLSession = .shared,
                nonceStore: DPoPNonceStore = .shared) {
        self.pdsURL = pdsURL
        self.session = session
        self.nonceStore = nonceStore
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
            (data, response) = try await session.dataWithRateLimit(for: request)
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
            if http.statusCode == 429 { throw BlueskyError.rateLimited }
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

/// How an authenticated XRPC request is signed. App-password sessions use `Bearer`; ATProto
/// OAuth sessions (#105) use `DPoP` — a `DPoP <token>` authorization scheme plus a per-request
/// proof header. Chosen by `BlueskyAccountStore.withAuth` based on which session is active.
public enum BlueskyAuth: Sendable {
    case bearer(String)
    case dpop(accessToken: String, key: DPoPKey)
}

extension BlueskyClient {
    /// Signs and performs an authed request, returning the raw `(Data, HTTPURLResponse)` so each
    /// caller keeps its existing status handling. For DPoP, a per-request proof is attached and the
    /// request is retried once if the server challenges with a `DPoP-Nonce`. A still-401 after that
    /// is a genuine expired token — the caller throws `.invalidCredentials` and `withAuth` refreshes.
    func performAuthed(_ request: URLRequest, auth: BlueskyAuth) async throws -> (Data, HTTPURLResponse) {
        func run(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let data: Data
            let response: URLResponse
            do { (data, response) = try await session.dataWithRateLimit(for: req) }
            catch let error as BlueskyError { throw error }
            catch { throw BlueskyError.network }
            guard let http = response as? HTTPURLResponse else { throw BlueskyError.malformedResponse }
            return (data, http)
        }
        switch auth {
        case .bearer(let token):
            var req = request
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return try await run(req)
        case .dpop(let token, let key):
            let builder = DPoPProofBuilder(key: key)
            let method = request.httpMethod ?? "GET"
            guard let url = request.url else { throw BlueskyError.malformedResponse }
            let host = url.host ?? ""
            // One signed attempt with the given nonce; returns the result + any fresh nonce the
            // server handed back (which we always cache, success or not).
            func attempt(_ nonce: String?) async throws -> (Data, HTTPURLResponse, String?) {
                var req = request
                req.setValue("DPoP \(token)", forHTTPHeaderField: "Authorization")
                req.setValue(try builder.proof(htm: method, htu: url, nonce: nonce, accessToken: token),
                             forHTTPHeaderField: "DPoP")
                let (data, http) = try await run(req)
                return (data, http, http.value(forHTTPHeaderField: "DPoP-Nonce"))
            }
            var (data, http, fresh) = try await attempt(await nonceStore.nonce(for: host))
            await nonceStore.store(fresh, for: host)
            // Retry once if the server rejected with a nonce to use (first call, or the cached
            // nonce rotated). A still-401 after is a real expired token → withAuth refreshes.
            if http.statusCode == 401, let retryNonce = fresh {
                let retried = try await attempt(retryNonce)
                data = retried.0; http = retried.1
                await nonceStore.store(retried.2, for: host)
            }
            return (data, http)
        }
    }
}
