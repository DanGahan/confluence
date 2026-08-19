import Foundation
import Observation

/// Owns Bluesky auth state for the UI: log in, restore on launch, refresh, log out.
/// The session is persisted in the Keychain and nowhere else.
@MainActor
@Observable
public final class BlueskyAccountStore {
    public private(set) var session: BlueskySession?
    /// An OAuth session, if the user signed in via ATProto OAuth (#105). Stored separately from the
    /// app-password `session`; slice 3 routes calls through DPoP when this is present.
    public private(set) var oauthSession: ATProtoOAuthSession?

    private let client: BlueskyClient
    private let keychain: any SecureStore
    private let authenticator: (any WebAuthenticator)?
    private var inFlightRefresh: Task<Void, Error>?
    private static let account = "session"
    private static let oauthAccount = "oauth-session"

    public var isLoggedIn: Bool { session != nil || oauthSession != nil }

    /// The active account's DID/handle regardless of auth type — for display and `repoDID`.
    public var currentDID: String? { session?.did ?? oauthSession?.did }
    public var currentHandle: String? { session?.handle ?? oauthSession?.handle }

    /// Base URL for authenticated Bluesky XRPC. Under OAuth this MUST be the account's own PDS:
    /// DPoP access tokens are bound to it and the proof's `htu` must match the real host, so the
    /// bsky.social entryway can't be used (same reason chat needs the PDS, #202). App-password
    /// sessions keep using the entryway.
    public var pdsBaseURL: URL { oauthSession?.pdsURL ?? URL(string: "https://bsky.social")! }

    /// A `BlueskyClient` pointed at the right host for the active session. Use for all authed calls.
    public func blueskyClient() -> BlueskyClient { BlueskyClient(pdsURL: pdsBaseURL) }

    public init(
        client: BlueskyClient = BlueskyClient(),
        keychain: any SecureStore = Keychain(service: "com.dangahan.confluence.bluesky"),
        authenticator: (any WebAuthenticator)? = nil
    ) {
        self.client = client
        self.keychain = keychain
        self.authenticator = authenticator
    }

    /// Restores a persisted session (if any) from the Keychain.
    ///
    /// The Keychain read happens on a detached task, off the main actor, so the app remains
    /// interactive while it runs — including if the OS shows an access prompt (#131). Call
    /// after the UI is up, not from `init` (#126). Corrupt/absent item = logged-out.
    public func restore() async {
        let store = keychain
        let account = Self.account
        let oauthAccount = Self.oauthAccount
        let restored: (BlueskySession?, ATProtoOAuthSession?) = await Task.detached {
            (try? store.value(BlueskySession.self, for: account),
             try? store.value(ATProtoOAuthSession.self, for: oauthAccount))
        }.value
        session = restored.0
        oauthSession = restored.1
    }

    /// ATProto OAuth sign-in (#105): resolve → discover → PAR → browser → token exchange, then
    /// persist the OAuth session. Requires an injected `WebAuthenticator` for the browser step.
    public func logInWithOAuth(handle: String, client oauthClient: ATProtoOAuthClient = .confluence) async throws {
        guard let authenticator else { throw BlueskyError.invalidCredentials }
        let flow = ATProtoOAuthFlow(client: oauthClient)
        let request = try await flow.begin(handle: handle)
        let callbackURL = try await authenticator.authenticate(url: request.authorizationURL, callbackScheme: request.callbackScheme)
        let oauth = try await flow.complete(request, callbackURL: callbackURL, handle: handle)
        try keychain.set(oauth, for: Self.oauthAccount)
        oauthSession = oauth
    }

    public func logIn(identifier: String, appPassword: String) async throws {
        let handle = identifier.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let newSession = try await client.createSession(identifier: handle, appPassword: appPassword)
        try keychain.set(newSession, for: Self.account)
        session = newSession
    }

    /// Exchanges the stored refresh token for fresh tokens.
    public func refresh() async throws {
        guard let current = session else { return }
        let refreshed = try await client.refreshSession(refreshJwt: current.refreshJwt)
        try keychain.set(refreshed, for: Self.account)
        session = refreshed
    }

    public func logOut() throws {
        try keychain.deleteAll()
        session = nil
        oauthSession = nil
    }

    /// Runs `body` with the current session; if the access token has expired
    /// (`BlueskyError.invalidCredentials`), refreshes once and retries. Centralises the
    /// refresh-retry that every authenticated Bluesky call in the app otherwise repeats.
    /// `nonisolated` so `body` (the network call) runs off the main actor as before; only the
    /// session read and refresh hop to the main actor.
    public nonisolated func withFreshSession<T: Sendable>(
        _ body: @Sendable (BlueskySession) async throws -> T
    ) async throws -> T {
        guard let session = await session else { throw BlueskyError.invalidCredentials }
        do {
            return try await body(session)
        } catch BlueskyError.invalidCredentials {
            try await coalescedRefresh()
            guard let fresh = await self.session else { throw BlueskyError.invalidCredentials }
            return try await body(fresh)
        }
    }

    /// Like `withFreshSession`, but hands `body` a `BlueskyAuth` (Bearer for app-password, DPoP
    /// for OAuth) so authed calls work under either sign-in (#105 slice 3). Refreshes once on
    /// `invalidCredentials` via the matching path. Prefer this for all authenticated calls.
    /// `body` receives the auth plus the account's own DID (needed as `repoDID` for writes).
    public nonisolated func withAuth<T: Sendable>(
        _ body: @Sendable (BlueskyAuth, _ did: String) async throws -> T
    ) async throws -> T {
        if let oauth = await oauthSession {
            do {
                return try await body(.dpop(accessToken: oauth.accessToken, key: try oauth.dpopKey()), oauth.did)
            } catch BlueskyError.invalidCredentials {
                try await coalescedRefresh()
                guard let fresh = await oauthSession else { throw BlueskyError.invalidCredentials }
                return try await body(.dpop(accessToken: fresh.accessToken, key: try fresh.dpopKey()), fresh.did)
            }
        }
        guard let session = await session else { throw BlueskyError.invalidCredentials }
        do {
            return try await body(.bearer(session.accessJwt), session.did)
        } catch BlueskyError.invalidCredentials {
            try await coalescedRefresh()
            guard let fresh = await self.session else { throw BlueskyError.invalidCredentials }
            return try await body(.bearer(fresh.accessJwt), fresh.did)
        }
    }

    /// Refreshes an OAuth access token via the DPoP-signed refresh grant, rotating stored tokens.
    public func refreshOAuth() async throws {
        guard let oauth = oauthSession else { throw BlueskyError.invalidCredentials }
        let tokens: ATProtoTokens
        do {
            tokens = try await ATProtoOAuthService().refresh(
                tokenEndpoint: oauth.tokenEndpoint, refreshToken: oauth.refreshToken,
                dpop: DPoPProofBuilder(key: try oauth.dpopKey()))
        } catch let ATProtoOAuthError.server(_, error, _) where error == "invalid_grant" {
            // The refresh token is permanently dead — rotated away by a prior refresh, or that
            // refresh's response was lost to a timeout (the server rotated, we never got the new
            // token). It can't be recovered, so clear the session and let the app prompt a fresh
            // sign-in instead of looping forever on "couldn't refresh" (#217).
            try? keychain.delete(Self.oauthAccount)
            oauthSession = nil
            throw BlueskyError.invalidCredentials
        }
        let updated = ATProtoOAuthSession(
            did: oauth.did, handle: oauth.handle,
            accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
            dpopPrivateKey: oauth.dpopPrivateKey, pdsURL: oauth.pdsURL,
            authorizationServer: oauth.authorizationServer, tokenEndpoint: oauth.tokenEndpoint)
        try keychain.set(updated, for: Self.oauthAccount)
        oauthSession = updated
    }

    /// Refreshes the active session (OAuth or app-password), coalescing concurrent callers so a
    /// burst of 401s on token expiry triggers exactly one refresh (#217). ATProto rotates the
    /// refresh token on use, so a second concurrent refresh with the same token fails; without
    /// coalescing that surfaced as an intermittent "couldn't refresh" with no posts on launch.
    /// The check-and-set is on the main actor with no `await` between, so it can't interleave.
    func coalescedRefresh() async throws {
        if let inFlightRefresh {
            try await inFlightRefresh.value
            return
        }
        let task = Task<Void, Error> { [self] in
            if oauthSession != nil { try await refreshOAuth() } else { try await refresh() }
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        try await task.value
    }

    /// True when the active session is OAuth (DPoP) rather than an app password. Lets wiring that
    /// still constructs Bearer requests from `session.accessJwt` fall back correctly.
    public var isOAuth: Bool { oauthSession != nil }
}
