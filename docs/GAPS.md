# GAPS.md — Tech debt ledger

Deliberate shortcuts and known gaps, with the trigger for repaying each.
Sources: `// ponytail:` comments in code (grep for them — they are the
authoritative in-place markers), the SPEC, and open bug issues. When you add a
`ponytail:` comment, add a row here; when you repay one, delete both.

## Missing vs. SPEC (functional debt)

| # | Gap | Where | Repay when |
|---|---|---|---|
| ~~G1~~ | ~~No 429 rate-limit backoff~~ — **repaid.** Central `URLSession.dataWithRateLimit(for:)` honours `Retry-After` (else exponential backoff + jitter, 3 retries, 30s cap). Both clients throw `.rateLimited` on exhaustion; `FeedStore`/`NotificationStore` expose a distinct `rateLimitedNetworks` set surfaced as a "try again in a moment" banner. | — | Done (#104) |
| G2 | **Bluesky auth is app-password only.** ATProto OAuth is the sanctioned path; app passwords bypass 2FA and will eventually be deprecated. **In progress (#105):** scaffolding landed — DPoP signer (`DPoP.swift`), PDS discovery (`ATProtoDiscovery.swift`), and design doc (`docs/ATPROTO_OAUTH.md`). Slice 2 wires the OAuth flow; slice 3 wires DPoP into every XRPC call. | `BlueskyClient.swift`, `BlueskyAccountStore.swift`, `docs/ATPROTO_OAUTH.md` | When Bluesky announces deprecation, or before public distribution |
| ~~G3~~ | ~~Engagement is one-way~~ — **repaid.** Repost/like are now toggles: Bluesky un-repost/un-like via `deleteRecord` (record URI kept per session), Mastodon `unreblog`/`unfavourite`. Optimistic, reverts on failure. | — | Done (#106) |
| ~~G4~~ | ~~Token refresh wired per-closure~~ — **repaid.** Centralised as `BlueskyAccountStore.withFreshSession` (refresh-once-and-retry), unit-tested. | — | Done (#107) |

## Implementation ceilings (`ponytail:` markers)

| # | Shortcut | Where | Repay when |
|---|---|---|---|
| ~~G5~~ | ~~Mastodon HTML → text is a regex strip + common entities~~ — **repaid.** Now decodes named + decimal (`&#8217;`) + hex (`&#x1F600;`) character references and tolerates real-world tag variants (`<br class>`, `<BR/>`, `</div>`). | `RichText.swift` (`decodeHTMLEntities`), `MastodonFeed.swift` (`htmlToPlainText`) | Done (#121) |
| ~~G6~~ | ~~Image retry: linear backoff, no jitter/cap~~ — **repaid.** Now exponential backoff with jitter, capped at 2000ms. | `RemoteImage.swift` | Done |
| G7 | Composer images: fixed 1600 px / 0.8 JPEG, no HEIC | `ComposerView.swift` | Alt-text repaid (#122). HEIC still pending — swap when users complain about quality loss. |
| G8 | Keychain falls back to legacy keychain on `errSecMissingEntitlement` (unsigned dev builds only) | `Keychain.swift` | Delete the fallback once builds are signed with a real team |
| ~~G9~~ | ~~`LinkClickRouter` consumes mouse-down on link glyphs, so a drag-select can't *start* on a link~~ — **repaid.** The router now forwards the click to the correct text view; NSTextView handles it natively — plain click opens the link, drag selects text from the glyph. | `RichTextLabel.swift` | Done (#124) |
| ~~G10~~ | ~~No offline cache — feed is refetched every launch~~ — **closed as by-design (#125).** An explicit SPEC non-goal ("no caching the spec doesn't require"), not debt. Reopen only if offline reading becomes a requirement. | SPEC decision | N/A — deliberate |
| ~~G14~~ | ~~Quick reply (Bluesky) sets `root` = `parent`, mis-rooting a reply to a mid-thread post~~ — **repaid.** The timeline already carries `record.reply.root`; captured as `FeedItem.replyRoot` and used so replies root at the conversation. | `BlueskyFeed.swift`, `BlueskyPost.swift` | Done (#152) |
| G16 | DMs (F15): Bluesky chat is proxied through the default PDS (`bsky.social`); accounts on a self-hosted PDS won't reach the chat service. Mastodon threads cost two calls (status + `/context`); no pagination on messages/convos (first page only). No optimistic append on send failure beyond an inline retry. Bluesky DM-scope app-password fix is a text hint in the inbox, not a Settings re-auth flow. | `BlueskyChat.swift`, `MastodonConversations.swift`, `DirectMessagesView.swift` | Per-PDS chat host, message pagination, and a Settings-driven app-password re-issue flow if users hit these |
| G15 | Quick reply: (a) no optimistic insert — box collapses on success, next refresh shows the reply; (b) single-line field — a vertical-growth `TextField` inside the LazyVStack row explodes `sizeThatFits` and beachballs, so the field is fixed-height. (Character counter repaid: Bluesky 300 hard cap, Mastodon 500 soft guide.) | `QuickReply.swift` | (a) if users want the reply to appear instantly; (b) multiline needs a fixed-frame `TextEditor`, never `axis: .vertical`, in the lazy row |

## Structural debt

| # | Gap | Where | Repay when |
|---|---|---|---|
| ~~G11~~ | ~~`FeedView.swift` is 674 lines / holds the closure-wiring~~ — **repaid.** Wiring extracted to `FeedWiring`; FeedView down to ~515 lines. | `FeedWiring.swift` | Done (#108) |
| ~~G12~~ | ~~`FeedWindowConfigurator` polls `asyncAfter(0.05)` until the window exists to force tab grouping~~ — **closed as an accepted permanent workaround (#109).** SwiftUI exposes no API to control window tab-grouping; contained and working. Reopen if Apple ships one. | `ConfluenceApp.swift` | N/A — needs Apple API |
| ~~G13~~ | ~~`EphemeralSecureStore` is `@unchecked Sendable`~~ — **repaid.** Now `Synchronization.Mutex`, checked-Sendable (macOS 26 floor). | `Keychain.swift` | Done (#110) |

## Open bugs that are debt until fixed

| Issue | Summary |
|---|---|
| [#102](https://github.com/DanGahan/confluence/issues/102) | Beachball viewing a Bluesky thread — suspected main-thread blocking; unreproduced. Diagnostics landed (breadcrumbs on the thread-open path); blocked on a repro to pin the cause. |

(#93, #94, #100 fixed and merged.)
