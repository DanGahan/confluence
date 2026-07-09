# GAPS.md — Tech debt ledger

Deliberate shortcuts and known gaps, with the trigger for repaying each.
Sources: `// ponytail:` comments in code (grep for them — they are the
authoritative in-place markers), the SPEC, and open bug issues. When you add a
`ponytail:` comment, add a row here; when you repay one, delete both.

## Missing vs. SPEC (functional debt)

| # | Gap | Where | Repay when |
|---|---|---|---|
| G1 | **No 429 rate-limit backoff.** SPEC's non-functional requirements demand exponential backoff + user messaging on 429; nothing in either client handles it today. A 429 currently surfaces as a generic server error. | All API client files | Before any feature that raises request volume (live/ticker mode #91 polls every 10–15 s — do G1 first) |
| G2 | **Bluesky auth is app-password only.** ATProto OAuth is the sanctioned path; app passwords bypass 2FA and will eventually be deprecated. | `BlueskyClient.swift`, `BlueskyAccountStore.swift` | When Bluesky announces deprecation, or before public distribution |
| G3 | **Engagement is one-way.** Repost/like create records; there's no un-repost/un-like (needs `deleteRecord` on Bluesky, `unreblog`/`unfavourite` on Mastodon). UI shows optimistic state per session only. | `BlueskyEngagement.swift`, `MastodonEngagement.swift`, `PostActionStore` | When the UI grows an "undo" affordance |
| G4 | **Token refresh is wired per-closure, not centralized.** Each fetcher closure in `FeedView.make…()` carries its own catch-refresh-retry dance (`withSession` helpers). Correct, tested, but duplicated ~6×. | `FeedView.swift` 289–490 | Next time a new endpoint set is added — extract a shared `withFreshBlueskyToken` wrapper into ConfluenceKit then |

## Implementation ceilings (`ponytail:` markers)

| # | Shortcut | Where | Repay when |
|---|---|---|---|
| G5 | Mastodon HTML → text is a regex strip + common entities | `MastodonFeed.swift` (`htmlToPlainText`) | If posts render wrong entities/tags in the wild; swap for a real parser |
| G6 | Image retry: fixed 3 tries, linear backoff, no jitter/cap | `RemoteImage.swift` | If thundering-herd or flaky-CDN symptoms appear |
| G7 | Composer images: fixed 1600 px / 0.8 JPEG, no alt text, no HEIC | `ComposerView.swift` | Alt text is an accessibility gap — repay ahead of the others |
| G8 | Keychain falls back to legacy keychain on `errSecMissingEntitlement` (unsigned dev builds only) | `Keychain.swift` | Delete the fallback once builds are signed with a real team |
| G9 | `LinkClickRouter` consumes mouse-down on link glyphs, so a drag-select can't *start* on a link | `RichTextLabel.swift` | Only if users report it; accepted trade for working links |
| G10 | No offline cache — feed is refetched every launch; SwiftData cache is the named path | SPEC decision | Only if offline reading is requested |

## Structural debt

| # | Gap | Where | Repay when |
|---|---|---|---|
| G11 | **`FeedView.swift` is 674 lines** and holds all the closure-wiring (`makeFetchers` etc.) — borderline business logic living in a view file. | `FeedView.swift` | Next feature that touches the wiring: extract a `FeedWiring`/composition-root type (still app-side, but its own file) |
| G12 | `FeedWindowConfigurator` polls `asyncAfter(0.05)` until the window exists to force tab grouping | `ConfluenceApp.swift` | If Apple ships SwiftUI tabbing control; until then it's contained |
| G13 | `EphemeralSecureStore` is `@unchecked Sendable` (NSLock-guarded dictionary) | `Keychain.swift` | Cosmetic; swap for `Mutex` when minimum toolchain allows |

## Open bugs that are debt until fixed

| Issue | Summary |
|---|---|
| [#100](https://github.com/DanGahan/confluence/issues/100) | Mastodon post links open Safari instead of the in-app thread (routing gap — we intercept bsky.app profile links but not Mastodon status URLs) |
| [#102](https://github.com/DanGahan/confluence/issues/102) | Beachball viewing a Bluesky thread — suspected main-thread blocking; unreproduced, needs capture |
| [#94](https://github.com/DanGahan/confluence/issues/94) | Main window doesn't come to foreground on launch |
| [#93](https://github.com/DanGahan/confluence/issues/93) | Closing a tab clicks through to a link behind the tab bar (same hit-testing family as #69 — see PROJECT.md "Rich text") |
