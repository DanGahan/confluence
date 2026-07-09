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
| `FeedStore` | The merged feed: refresh (parallel task group per network), infinite scroll, per-network failure isolation |
| `BlueskyAccountStore` / `MastodonAccountStore` | Auth lifecycle: login, session restore from Keychain on init, token refresh, logout |
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
3. `FeedView` builds the closure sets (`makeFetchers`, `makeFollowActions`,
   `makePostActions`, `makeNotificationFetchers`, `makeSearchFetchers`) and
   hands them to the stores. **Token refresh lives inside these closures**: a
   Bluesky fetcher catches `invalidCredentials`, calls
   `BlueskyAccountStore.refresh()` (swap refresh JWT for new tokens, persist),
   and retries once. AT Proto quirk: an expired access token comes back as
   **HTTP 400 with `error: "ExpiredToken"`, not 401** — `BlueskyFeed` maps
   400/ExpiredToken/InvalidToken/AuthenticationRequired all to
   `invalidCredentials` so the retry triggers.
4. `FeedStore.refresh()` fires all networks in a `withTaskGroup`, stores each
   network's items separately (`perNetwork`), then `mergeFeeds` flattens:
   de-dupe by ID, sort newest-first, tie-break by ID for determinism. One
   network failing populates `failedNetworks` (a non-blocking banner) and
   never blanks the other's posts.
5. `loadMore()` paginates **whichever network's loaded stream currently ends
   newest** — that's where the merge gap is. Cursors are per-network; a failed
   network stops paginating until the next refresh.
6. Rows render in a `ScrollView` + `LazyVStack` + `scrollTargetLayout`.
   Scroll position is debounce-saved (750 ms) per feed-filter scope and
   restored on launch if the post is still present and < 7 days old.

## Auth

**Bluesky** — app password → `com.atproto.server.createSession` → access +
refresh JWTs, persisted as one JSON blob in Keychain. Refresh via
`refreshSession`. 2FA accounts get a tailored error pointing at app passwords
(which bypass 2FA). `// ponytail:` ATProto OAuth is the upgrade path when
Bluesky deprecates app passwords.

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
