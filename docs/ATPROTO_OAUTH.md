# ATProto OAuth — design & rollout

This is the plan for repaying **G2 / #105**: migrating Bluesky auth from app
passwords (which bypass 2FA and are on Bluesky's deprecation path) to ATProto
OAuth. The work is split across several PRs to keep each reviewable.

## Why it's more work than Mastodon's OAuth

Mastodon is plain OAuth 2.0 authorization-code: register the app, open the
authorize URL, exchange the code for a bearer token, put the token in every
request's `Authorization` header. Done.

ATProto adds three layers on top:

1. **Multi-step discovery.** A user's identity lives on their PDS (Personal Data
   Server), which the client must find before it can even locate the
   authorization server. The chain is:
   ```
   handle → DID → DID document → PDS → oauth-protected-resource
                                     → oauth-authorization-server
   ```
2. **PAR** (Pushed Authorization Requests, RFC 9126). The client pushes the
   authorization parameters to the server first, receives a `request_uri`, then
   opens the browser using that opaque URI rather than putting the params in
   the browser URL. Required by ATProto's AS metadata.
3. **DPoP** (Demonstrating Proof of Possession, RFC 9449). Every token request
   and every subsequent XRPC call must carry a `DPoP:` header whose value is
   a per-request JWT signed with a key the client holds. The AS/RS can also
   demand a `DPoP-Nonce` — the client retries the request including the nonce
   in the next JWT.

Combined with the "zero third-party dependencies" rule in `CLAUDE.md`, this
means we hand-roll a small JWS/DPoP signer using `CryptoKit`. The signer is a
security surface and gets a review pass and unit tests before it wires into
any real request.

## Rollout plan

Split into three vertical slices so each is reviewable on its own.

### Slice 1 — scaffolding (this PR, #105 part 1)

- `docs/ATPROTO_OAUTH.md` (this file).
- `DPoP.swift` — JWS/ES256 signer with:
  - P-256 key pair generation via `CryptoKit`.
  - Persistence via the existing `SecureStore` protocol.
  - Compact JWS assembly with the ATProto DPoP claim set
    (`htm`, `htu`, `iat`, `jti`, optional `nonce`, optional `ath`).
- `ATProtoDiscovery.swift` — the discovery pipeline:
  - DID → DID document (`did:plc:*` via `plc.directory`, `did:web:*` via
    `/.well-known/did.json`).
  - DID document → PDS URL (from `service` entry with id `#atproto_pds`).
  - PDS → `/.well-known/oauth-protected-resource` → authorization server URL.
  - Authorization server → `/.well-known/oauth-authorization-server` →
    endpoints (PAR, authorization, token, revocation).
- Unit tests for both, hitting `MockURLProtocol` — no live network in tests.
- **Not in this PR:** the OAuth flow, client metadata JSON, any UI, or wiring
  DPoP into existing XRPC calls.

### Slice 2 — OAuth flow end-to-end (#105 part 2)

- Handle resolution: DNS TXT `_atproto.{handle}` first, HTTP well-known
  `https://{handle}/.well-known/atproto-did` fallback.
- Client metadata JSON — hosted at a public URL that Bluesky's AS can fetch.
  Options: GitHub Pages under a Confluence-owned domain, or dynamically
  generated. Placeholder URL until this is set up; localhost is not accepted
  by production Bluesky.
- PAR request + PKCE (S256).
- `ASWebAuthenticationSession` (same hygiene as the Mastodon flow — state
  verified, no embedded webviews).
- Code exchange with DPoP + nonce retry.
- Refresh flow with DPoP + nonce retry.
- Session persistence in Keychain: DID, access token, refresh token, DPoP
  private key, PDS URL, token endpoint. All fields sensitive, none logged.

### Slice 3 — wire DPoP into every XRPC call (#105 part 3)

- Every authenticated Bluesky call in `ConfluenceKit` (~22 sites) adds the
  `DPoP:` header alongside `Authorization: DPoP <token>` (note: the auth
  scheme is `DPoP`, not `Bearer`).
- Handle 401 with `DPoP-Nonce` — retry once with the nonce.
- Migration: if the stored session is app-password shape (has `accessJwt` /
  `refreshJwt` fields), keep working via the current path; on the next
  successful refresh window, offer re-auth via OAuth. Once a user has an
  OAuth session, the app-password path is unreachable.

## Key management

The DPoP key is a P-256 signing key. It's per-account and never leaves the
device. It lives in the Keychain under the existing Bluesky service
(`com.dangahan.confluence.bluesky`) using the same `SecureStore` interface as
the session — one item per account. Losing the key = losing the ability to
prove possession = forced re-auth. That's an acceptable failure mode.

Rotation: not implemented in slice 2. If needed later, generate a new key,
register it during the next refresh, discard the old one.

## Security notes (baked in)

- The DPoP JWT is short-lived by design (`iat` + typically 60 s validity from
  the server's perspective). We don't cache DPoP JWTs across requests.
- `jti` is a fresh UUID per request so replay windows are minimal.
- `ath` (access token hash) is `base64url(sha256(access_token))` — included on
  requests that carry an access token, so a stolen DPoP JWT can't be paired
  with a different token.
- `nonce`, when required, is echoed exactly as sent. We surface the retry
  transparently; callers never see the nonce dance.
- The private key never appears in logs. Public-key JWK components (`x`, `y`)
  are fine — they're in every DPoP header the server sees anyway.

## Testing strategy

Unit tests only in this scaffolding PR; no live-network integration tests
because the whole point of the scaffolding is that it can be exercised
against `MockURLProtocol` responses that match the real server's shape.

- **DPoP signer**: round-trip a JWT and verify the signature using the same
  public key. Verify claim set contents. Verify `jti` uniqueness across calls.
- **Discovery**: for both `did:plc:*` and `did:web:*` inputs, drive the
  multi-step pipeline through a scripted MockURLProtocol responding to each
  well-known URL in turn. Verify the emitted endpoint URLs.
- Slice 2 will add integration tests for the OAuth flow (PAR, token exchange
  with nonce retry) using the same pattern.
