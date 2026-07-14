# GAPS.md — Tech debt ledger

Deliberate shortcuts and known gaps, with the trigger for repaying each.
Sources: `// ponytail:` comments in code (grep for them — they are the
authoritative in-place markers), the SPEC, and open bug issues. When you add a
`ponytail:` comment, add a row here; when you repay one, delete both.

## Missing vs. SPEC (functional debt)

| # | Gap | Where | Repay when |
|---|---|---|---|
| G1 | **No 429 rate-limit backoff.** SPEC's non-functional requirements demand exponential backoff + user messaging on 429; nothing in either client handles it today. A 429 currently surfaces as a generic server error. | All API client files | **Now the top functional gap** — live/ticker mode (#91) shipped and polls every ~12s, so this is overdue (#104) |
| G2 | **Bluesky auth is app-password only.** ATProto OAuth is the sanctioned path; app passwords bypass 2FA and will eventually be deprecated. | `BlueskyClient.swift`, `BlueskyAccountStore.swift` | When Bluesky announces deprecation, or before public distribution |
| ~~G3~~ | ~~Engagement is one-way~~ — **repaid.** Repost/like are now toggles: Bluesky un-repost/un-like via `deleteRecord` (record URI kept per session), Mastodon `unreblog`/`unfavourite`. Optimistic, reverts on failure. | — | Done (#106) |
| ~~G4~~ | ~~Token refresh wired per-closure~~ — **repaid.** Centralised as `BlueskyAccountStore.withFreshSession` (refresh-once-and-retry), unit-tested. | — | Done (#107) |

## Implementation ceilings (`ponytail:` markers)

| # | Shortcut | Where | Repay when |
|---|---|---|---|
| G5 | Mastodon HTML → text is a regex strip + common entities | `MastodonFeed.swift` (`htmlToPlainText`) | If posts render wrong entities/tags in the wild; swap for a real parser |
| ~~G6~~ | ~~Image retry: linear backoff, no jitter/cap~~ — **repaid.** Now exponential backoff with jitter, capped at 2000ms. | `RemoteImage.swift` | Done |
| G7 | Composer images: fixed 1600 px / 0.8 JPEG, no HEIC | `ComposerView.swift` | Alt-text repaid (#122). HEIC still pending — swap when users complain about quality loss. |
| G8 | Keychain falls back to legacy keychain on `errSecMissingEntitlement` (unsigned dev builds only) | `Keychain.swift` | Delete the fallback once builds are signed with a real team |
| G9 | `LinkClickRouter` consumes mouse-down on link glyphs, so a drag-select can't *start* on a link | `RichTextLabel.swift` | Only if users report it; accepted trade for working links |
| G10 | No offline cache — feed is refetched every launch; SwiftData cache is the named path | SPEC decision | Only if offline reading is requested |

## Structural debt

| # | Gap | Where | Repay when |
|---|---|---|---|
| ~~G11~~ | ~~`FeedView.swift` is 674 lines / holds the closure-wiring~~ — **repaid.** Wiring extracted to `FeedWiring`; FeedView down to ~515 lines. | `FeedWiring.swift` | Done (#108) |
| G12 | `FeedWindowConfigurator` polls `asyncAfter(0.05)` until the window exists to force tab grouping | `ConfluenceApp.swift` | If Apple ships SwiftUI tabbing control; until then it's contained |
| ~~G13~~ | ~~`EphemeralSecureStore` is `@unchecked Sendable`~~ — **repaid.** Now `Synchronization.Mutex`, checked-Sendable (macOS 26 floor). | `Keychain.swift` | Done (#110) |

## Open bugs that are debt until fixed

| Issue | Summary |
|---|---|
| [#102](https://github.com/DanGahan/confluence/issues/102) | Beachball viewing a Bluesky thread — suspected main-thread blocking; unreproduced. Diagnostics landed (breadcrumbs on the thread-open path); blocked on a repro to pin the cause. |

(#93, #94, #100 fixed and merged.)
