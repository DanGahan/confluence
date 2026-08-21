# PROJECT.md — How Confluence works

A developer's guide to the codebase: architecture, data flow, the hacks we've
had to make, and why they look the way they do. Read this before your first PR.
The product spec (features + acceptance criteria) is [SPEC.md](SPEC.md); the
rules of engagement are [../CLAUDE.md](../CLAUDE.md); known tech debt is
[GAPS.md](GAPS.md).

## What this is

A native macOS app (macOS 26+, Swift 6, SwiftUI) showing a single combined,
chronological feed from one Bluesky account and one Mastodon account. Zero
third-party dependencies — both APIs are JSON over HTTPS, handled with
`URLSession` + `Codable`.

## Repo layout & build system

```
Confluence/            # App target: SwiftUI views + AppKit bridges. No business logic.
ConfluenceKit/         # Local SPM package: ALL logic — API clients, models, stores, auth.
  Sources/ConfluenceKit/
  Tests/ConfluenceKitTests/
ConfluenceUITests/     # XCUITest smoke tests (a handful, launch-level only)
docs/                  # SPEC.md (features), PROJECT.md (this file), GAPS.md (debt)
project.yml            # xcodegen source of truth — Confluence.xcodeproj is NOT committed
scripts/create-dev-cert.sh
```

**The `.xcodeproj` is generated.** After cloning or editing `project.yml`:

```bash
brew install xcodegen              # once
scripts/create-dev-cert.sh         # once: local "Confluence Dev" signing identity
xcodegen generate                  # after every project.yml change
swift test --package-path ConfluenceKit   # fast; run constantly
xcodebuild -scheme Confluence build       # full app
xcodebuild -scheme Confluence test        # includes UI smoke tests (slow, pre-merge)
```

The dev cert matters: a stable code signature is what makes macOS Keychain
"Always Allow" stick across rebuilds. Without it, every rebuild re-prompts for
the Keychain password on launch.

## Architecture in one paragraph

Two layers. **`ConfluenceKit`** owns every model, network call, parser, and
piece of state logic, structured as plain `Sendable` structs (clients) plus
`@MainActor @Observable` classes (stores). **`Confluence`** (the app) is
SwiftUI views that render store state and forward user intent. The seam
between them is *injected closures*: stores don't know about HTTP — they're
handed `@Sendable` async closures (`PageFetcher`, `Poster`, `FollowActions`,
`PostActions`, `NotificationFetcher`, `SearchFetcher`) that the app wires up
in `FeedView.makeFetchers()` etc. That single design decision is why ~95% of
the code is unit-testable without a network or a running app.

## ConfluenceKit file map

Naming convention: `<Network><Feature>.swift` for API code, `<Feature>Store.swift`
for observable state, plain nouns for models.

### Models (network-agnostic)
| File | What |
|---|---|
| `ConfluenceKit.swift` | `Network` enum (`.bluesky` / `.mastodon`) — the root type |
| `FeedItem.swift` | The normalized post: author, text, `AttributedString`, images, `PostVideo`s, `LinkCard`, repost attribution, thread info. Also `FeedPage`, `PostThread`, and the pure functions `mergeFeeds` / `chronological` |
| `NotificationItem.swift`, `Profile.swift`, `Search.swift` | Same idea for their domains |

### API clients (structs, one file per feature per network)
`BlueskyClient` (auth), `BlueskyFeed`, `BlueskyPost`, `BlueskyFollow`,
`BlueskyEngagement` (repost/like/block), `BlueskyNotifications`,
`BlueskyProfile`, `BlueskySearch` — and the Mastodon mirror set plus
`MastodonRelationships` (follow-state prefetch, because Mastodon's timeline
doesn't include it).

Each decodes into **private wire-format structs** (e.g. `MastodonFeed.Status`,
`BlueskyFeed.Embed`) and maps to the public normalized models before returning.
Wire structs never leak out of their file. All decoding tolerates missing/extra
fields — network input is treated as hostile, and malformed payloads must never
crash (integration-tested with garbage JSON).

### Stores (`@MainActor @Observable`, injected closures, all unit-tested)
| Store | Owns |
|---|---|
| `FeedStore` | The merged feed: non-destructive refresh (parallel task group per network — a failed refresh keeps the posts already shown), completeness-watermarked infinite scroll, per-network failure isolation |
| `BlueskyAccountStore` / `MastodonAccountStore` | Auth lifecycle: login (app password **or** ATProto OAuth), session restore from Keychain on init, coalesced token refresh, dead-OAuth-session recovery, logout |
| `ComposerStore` | Cross-post text/attachments/limits; per-network success tracking so a retry never double-posts |
| `DraftStore` | Saved composer drafts (UserDefaults, no credentials) |
| `FollowStore` / `PostActionStore` | Optimistic follow/repost/like/block with revert-on-failure |
| `NotificationStore` | Merge + unread counts (local "last seen" timestamp per network — works uniformly across both APIs) |
| `SearchStore` | Debounced dual-network search, people + posts |
| `FeedPositionStore` | Scroll position persistence (post ID per scope in UserDefaults, 7-day expiry) |

### Support
`Keychain.swift` (see Auth below), `RichText.swift` + `LinkGeometry.swift`
(see Rich text below), `ISO8601.swift` (date parsing with fractional-seconds
fallback).

## Data flow, launch to pixels

1. `ConfluenceApp.init` creates the account stores. Each restores a persisted
   session from its Keychain service (`com.dangahan.confluence.bluesky` /
   `.mastodon`) — corrupt/absent item just means logged out.
2. `ContentView` shows onboarding if neither account exists, else `FeedView`.
3. `FeedView` builds the closure sets via `FeedWiring` (`pageFetchers`,
   `followActions`, `postActions`, `notificationFetchers`, `searchFetchers`,
   `dmActions`) and hands them to the stores. **Token refresh lives inside these
   closures**, via `BlueskyAccountStore.withAuth { auth, did in … }`: it hands
   `body` the right credential — `.bearer` for an app-password session, `.dpop`
   for an OAuth session — and on `invalidCredentials` refreshes once and retries.
   Refresh is **coalesced** (`coalescedRefresh` — one in-flight refresh `Task`):
   ATProto rotates the refresh token on use, so a burst of concurrent 401s must
   trigger exactly one refresh, or the losers race the single-use token to a dead
   `invalid_grant`. AT Proto quirk: an expired access token comes back as **HTTP
   400 with `error: "ExpiredToken"`, not 401** — mapped (with 401 / InvalidToken /
   AuthenticationRequired) to `invalidCredentials` so the retry triggers. A
   *permission* 403 (chat `ScopeMissingError`) is **not** an expiry — it maps to
   `chatUnavailable` and never refreshes (else every DM poll would churn the
   token). A genuinely dead OAuth refresh token (`invalid_grant`) can't be
   renewed silently — the store clears the session and raises `sessionExpired`,
   and the feed shows a one-tap "sign in again" banner (see Auth).
4. `FeedStore.refresh()` fires all networks in a `withTaskGroup`, storing each
   network's items separately (`perNetwork`), then `mergeFeeds` flattens: de-dupe
   by ID, sort newest-first, tie-break by ID for determinism. It is
   **non-destructive**: a network's posts are replaced only when its refetch
   *succeeds*; on failure the previously loaded posts are kept and the network is
   flagged (`failedNetworks` / `rateLimitedNetworks`, a non-blocking banner). A
   failed refresh therefore never blanks a feed that was showing fine.
5. `loadMore()` — infinite scroll — is **completeness-aware** so the combined
   feed stays chronological with nothing missing. It renders only down to a
   **completeness watermark** (`combinedVisible`): the newest of the oldest-loaded
   posts across still-loading networks. Below that line the shallowest stream
   hasn't been fetched, so a later page could interleave — those posts are held
   back (kept in `items`, hidden from the combined view) until that stream pages
   down to them. Combined `loadMore` pages exactly that shallowest network to
   catch it up (equal *pages* ≠ equal *time depth*: Mastodon's pages reach
   further back, so Bluesky needs extra calls). A single-network filter shows that
   whole network (`items`, no watermark) and paginates just it (#214). Cursors are
   per-network; a transient failure flags the network but keeps it **retryable**
   (the next scroll retries) — only a nil cursor (real end) stops it.
6. Rows render in a `ScrollView` + `LazyVStack` + `scrollTargetLayout`. Image
   rows **reserve their height from the post's aspect ratio** before the image
   loads (`PostImages`), so late-loading images in older posts don't shove the
   viewport and make the feed jump (#196). Scroll position is debounce-saved
   (750 ms) per feed-filter scope and restored on launch if the post is still
   present and < 7 days old.
7. **Live mode** (`FeedView.liveMode`, toolbar toggle) turns the feed into a
   ticker: a `.task(id: liveMode && scenePhase == .active)` loops `feed.refresh()`
   + `pinToTop()` every ~12s. Keying the task on that Bool means it stops when
   the window backgrounds and restarts (with an immediate refresh) on refocus —
   no manual timer teardown. `pinToTop()` sets `topID` to the newest post so
   streamed-in posts stay at the top. Scroll-to-Top and Refresh are hidden while
   it's on. No 429 backoff yet — see GAPS.md G1.

## Auth

**Bluesky** — two sign-in paths; onboarding leads with OAuth, app password is a
fallback.

- **ATProto OAuth (preferred, #105).** PKCE + PAR + DPoP; client metadata is
  hosted at a public URL that *is* the `client_id`. Sign-in persists an
  `ATProtoOAuthSession` (DID, access + rotating refresh token, DPoP private key,
  the account's **PDS** URL, token endpoint). Authed calls sign a per-request
  DPoP proof (`.dpop`) and go to the account's own PDS — not the bsky.social
  entryway — because the DPoP token is bound to it. Scope is
  `atproto transition:generic transition:chat.bsky` (the chat scope is what makes
  DMs work; it must match the hosted metadata or sign-in fails `invalid_scope`).
  Full deep-dive: `docs/ATPROTO_OAUTH.md`.
- **App password (fallback)** → `com.atproto.server.createSession` → access +
  refresh JWTs (`.bearer`), refreshed via `refreshSession`. 2FA accounts get a
  tailored error pointing at app passwords (which bypass 2FA).

Both paths share `withAuth` / `coalescedRefresh` (above). A dead OAuth refresh
token can't be renewed silently (OAuth keeps no reusable secret, unlike an app
password), so on `invalid_grant` the store clears the session and raises
`sessionExpired`; the feed surfaces a "Your Bluesky sign-in expired — sign in
again" banner that reopens the OAuth flow. Refresh outcomes are logged at
`.notice` (subsystem `com.dangahan.confluence`, category `bluesky-auth`) —
no secrets — so the refresh cadence/cause is visible after the fact.

**Mastodon** — user types an instance domain (validated against
`/api/v1/instance` before anything opens), app self-registers via
`POST /api/v1/apps` (dynamic client registration), then OAuth 2.0
authorization-code in `ASWebAuthenticationSession` (never an embedded
webview). The `state` parameter is generated and verified — mismatch aborts
with nothing persisted. Session (host + client id/secret + token) is one
Keychain JSON blob. Logout best-effort revokes (`POST /oauth/revoke`) and
deletes.

**`Keychain.swift`** wraps Security.framework generic passwords,
`kSecAttrAccessibleWhenUnlocked`. **Hack you should know:** it prefers the
data-protection keychain (correct for a signed sandboxed app) but falls back
to the legacy keychain when the OS reports `errSecMissingEntitlement` — which
happens on unsigned/ad-hoc dev builds. Reads/deletes check both. A distributed
signed build never falls back. `EphemeralSecureStore` is the in-memory test
double; UI tests launch with `-uiTestLoggedOut` to use it and avoid Keychain
prompts entirely.

## Rich text: the hard-won part

Post bodies are `AttributedString`s with `.link` runs, built in
`RichText.swift`: Bluesky facets (byte-offset ranges into UTF-8 — mind the
conversion) and Mastodon HTML (`mastodonRichText` maps anchor hrefs; mention
anchors become internal `confluence-profile://` URLs via `ProfileLink`, so
tapping a mention opens the in-app `ProfileView` instead of a browser).
`ProfileLink.blueskyWebProfileHandle` also intercepts `https://bsky.app/profile/…`
web links so they open in-app.

Rendering those links on macOS 26 cost us a full day of debugging (#69). Three
pitfalls, all still live in the platform — **do not regress these**:

1. **SwiftUI `Text` link taps never fire** inside the feed's
   ScrollView+LazyVStack+scrollTargetLayout stack (they work in plain sheets).
   Post bodies therefore use `RichTextLabel`, an `NSViewRepresentable`
   NSTextView (explicit TextKit 1 stack — TextKit 2 breaks `sizeThatFits`
   height measurement).
2. **NSViewRepresentables inside LazyVStack get clicks misrouted** to stale
   platform-container frames: links rendered fine but never received the
   click. Fix: `LinkClickRouter` — a window-level
   `NSEvent.addLocalMonitorForEvents(.leftMouseDown)` that, before any
   hit-testing, asks each registered visible text view directly whether the
   click lands on a link glyph, opens it, and consumes the event. Geometry
   lives in `LinkGeometry` (ConfluenceKit) because it regressed repeatedly in
   the view layer — it's unit-tested there and `RichTextLabel` is a thin
   caller. Known trade-off: a drag-select can't *start* on a link glyph.
3. **`scaledToFill` images hit-test beyond their frame** even when clipped —
   `.clipped()` hides the overflow visually but the invisible spill still
   swallows clicks on neighbouring views (this was the "sporadic dead links"
   ghost). Containment pattern, mandatory for any new fill-mode image:
   `Color.clear.overlay(image).clipped().contentShape(Rectangle())` — already
   packaged in `RemoteImage`.

When clicks mysteriously die anywhere in this app, suspect invisible overlap
first; verify with a window-level event monitor logging the hit view.

`ProfileLinkHandler` installs the app-wide `OpenURLAction`: profile links →
sheet, everything else → `NSWorkspace` browser open. (We open web URLs
ourselves because returning `.systemAction` from a programmatically-invoked
`OpenURLAction` doesn't reliably open anything.)

## Images & video

- `RemoteImage` replaces `AsyncImage`, which on macOS cancels in-flight loads
  when a row scrolls off and doesn't reliably retry. It's a shared
  non-cancelling loader (`ImageLoader`) + in-memory `ImageCache`; cache hits
  render with no placeholder flash. Fixed 3 retries, linear backoff.
- Post images render in a fixed-height letterbox row, up to 4, click → 
  `ImageLightbox` sheet.
- `PostVideoView` (AVKit): poster thumbnail + play overlay; tap swaps in a
  `VideoPlayer` that autoplays. One `AVPlayer` handles both Bluesky HLS
  playlists (`app.bsky.embed.video#view`) and Mastodon mp4/gifv natively.
  Bluesky videos can also arrive nested under `recordWithMedia#view` — the
  `Embed` wire struct flattens both shapes.

## Windowing & macOS integration

- Single `WindowGroup` + standard `Settings` scene. Menu bar commands in
  `AppCommands` (⌘N compose, ⌘R refresh, ⌘↑ scroll-to-top, ⌘S search, ⌘T tab).
- **Tab hack:** SwiftUI gives no control over window tabbing, so
  `FeedWindowConfigurator` (an invisible `NSViewRepresentable` in the window
  background) sets `tabbingIdentifier = "feed"` and folds any new feed window
  into an existing window's tab group — so ⌘T always makes a *tab*, regardless
  of the user's system "prefer tabs" setting. It polls with
  `asyncAfter(0.05)` until the window exists. Ugly, works, contained.
- App Sandbox + Hardened Runtime on; the only entitlement is
  `com.apple.security.network.client`. Adding any entitlement requires written
  justification in the PR.

## iOS differences

Confluence targets macOS **and** iOS (iPhone + iPad) from one app target and one
codebase — no fork. `ConfluenceKit` is already platform-free; the port is almost
entirely the thin view layer. Full ticket breakdown in
[IOS_PLAN.md](IOS_PLAN.md). What differs, and the rule of thumb:

- **`#if os(...)` seams, no abstraction layer.** Platform code is gated inline or
  in small file-level shims (`PlatformImage` typealias, an `openExternally(_:)`
  wrapper, a per-platform auth presentation anchor). Do **not** add a
  "PlatformKit" protocol module — that's an abstraction with one implementation
  per platform, exactly what the house rules forbid.
- **The macOS hacks are macOS-only, and are liabilities to *not* port.**
  `RichTextLabel`/`LinkClickRouter` (dead `Text` links + misrouted representable
  clicks in a LazyVStack), `FeedWindowConfigurator` (window tabbing), the
  window-restore adaptor — each patches a macOS-specific SwiftUI bug. On iOS the
  naive SwiftUI path usually just works; confirm with a timeboxed spike before
  porting any workaround. `LinkGeometry` lives in the kit precisely so a UITextView
  port (if ever needed) can reuse it unchanged.
- **No Settings scene on iOS.** macOS uses the standard `Settings` scene; iOS
  reaches Settings/About from a toolbar entry (sheet / `NavigationStack`) over the
  same `SettingsView` content. Menu bar (`AppCommands`) and window tabbing are
  `#if os(macOS)`; hardware-keyboard shortcuts on iPad can reuse the command set.
- **Keychain:** the legacy-keychain fallback (G8) is a macOS unsigned-dev-build
  concern only — gated `#if os(macOS)`. iOS always uses the data-protection keychain.
- **No Reading List on iOS** (no public API); `ShareLink` covers sharing on both.
- **Touch:** right-click → long-press maps to `.contextMenu` for free, but the
  quick-reply body-tap becomes the primary affordance; targets are ≥ 44 pt;
  Dynamic Type must not truncate. Verify hit-testing under touch (the macOS
  gotchas were mouse-observed).

## Testing

Pyramid, enforced (~70% unit / ~25% integration / ~5% UI):

- **Unit** — Swift Testing (`@Test`). Merge/sort, cursors, character counting,
  position restore, model decoding from inline fixture JSON captured from the
  real APIs. Milliseconds each.
- **Integration** — API clients against `MockURLProtocol` (a `URLProtocol`
  double: hand it a closure `(URLRequest) -> (HTTPURLResponse, Data)`). Assert
  the exact request (method, path, headers, body) and handling of success,
  401/expired-token refresh, and malformed JSON.
- **UI** — XCUITest smoke only: launches, logged-out onboarding, composer
  checkboxes. `-uiTestLoggedOut` launch arg swaps Keychain for
  `EphemeralSecureStore`.

Never call the real APIs from tests. Every bug fix starts with a failing test
reproducing it. `swift test --package-path ConfluenceKit` must be green before
any commit.

## Conventions & workflow

- Deliberate shortcuts are marked `// ponytail:` with the ceiling and upgrade
  path named. They're harvested into [GAPS.md](GAPS.md) — if you add one, add
  a ledger entry.
- Work is GitHub issues on the [project board](https://github.com/users/DanGahan/projects/4)
  (New → In Progress → In QA → Done, plus Blocked). One SPEC feature (or
  sub-bullet) per PR; quote the acceptance criteria in the PR description.
- Definition of done: acceptance criteria met, tests at the right layer,
  no new warnings, Swift 6 strict-concurrency clean, security checklist holds,
  works at the 480×600 minimum window and in Dark Mode, VoiceOver labels on
  anything interactive you added.

## Quick "where do I…" index

| Task | Start here |
|---|---|
| Add a field to posts | `FeedItem.swift`, then the wire structs in `BlueskyFeed.swift` / `MastodonFeed.swift`, then fixture tests in `FeedDecodingTests.swift` |
| New API endpoint | New `<Network><Feature>.swift` extension on the client struct; wire a closure in `FeedView.make…()`; integration test with `MockURLProtocol` |
| New user-facing state | A store in ConfluenceKit (`@MainActor @Observable`, closure-injected), unit tests first, then a thin view |
| Touch links/clicks in the feed | Re-read "Rich text" above. Seriously. |
| New setting | `SettingsView` tab + `@AppStorage` key (pattern: `PostAppearance`) |
| Anything auth/Keychain | Security section of CLAUDE.md, and it gets a security pass in review |
