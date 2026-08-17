# Spec — Confluence (working title)

A native Apple app showing a combined Bluesky + Mastodon feed, on **macOS and iOS from one codebase**. Inspired by Indigo.

## Platform & stack (fixed decisions — do not relitigate)

- **macOS 26 (Tahoe) minimum; iOS 26 minimum (iPhone + iPad).** Liquid Glass and modern SwiftUI materials come free from the OS; do not reimplement them. iOS 27 is a compatibility pass against the newest SDK, not a separate floor.
- **One codebase, one app target, no fork.** Platform differences live behind `#if os(...)` seams and small file-level shims — **no cross-platform abstraction layer** (no "PlatformKit" protocol module for one implementation). See `docs/IOS_PLAN.md`.
- **Swift 6, SwiftUI only.** No AppKit/UIKit unless SwiftUI genuinely cannot do it (document why in the PR). Business logic in `ConfluenceKit` stays platform-free (Foundation + Observation only) — never import AppKit or UIKit there.
- **Zero third-party dependencies.** Both APIs are plain JSON over HTTPS; `URLSession` + `Codable` cover them. Adding a dependency requires updating this file with the justification.
- **Xcode project via Swift Package + app target.** Business logic lives in a local SPM package (`ConfluenceKit`) so it is testable without booting the app.
- **Persistence:** UserDefaults for lightweight state (feed position, post-target checkboxes), Keychain for all credentials, no database. Feed content is not persisted; it is refetched. (`ponytail:` add SwiftData cache only if offline reading is ever requested.)

## Accounts & protocols

- **Bluesky:** AT Protocol XRPC. MVP auth = app password via `com.atproto.server.createSession`; store the refresh + access JWTs in Keychain, refresh via `com.atproto.server.refreshSession`. (`ponytail:` upgrade to ATProto OAuth when Bluesky deprecates app passwords.) **DMs (F15) need an app password with the "Allow access to your direct messages" scope** — a normal app password can't call the chat service, so onboarding/Settings must let the user know and re-issue one.
- **Mastodon:** Mastodon REST API. Auth = OAuth 2.0 authorization-code flow via `ASWebAuthenticationSession`, with dynamic client registration (`POST /api/v1/apps`) against the user's chosen instance. Store the access token in Keychain.
- One account per network for MVP. Multi-account is out of scope.

## Features

### F1 — Bluesky login
- Settings/onboarding sheet: handle + app password fields, link to Bluesky's app-password page.
- On success: session stored in Keychain, feed loads. On failure: inline error, no credentials persisted.
- Logout deletes all Bluesky items from Keychain.

### F2 — Mastodon login
- User enters instance domain (e.g. `mastodon.social`), app registers itself, opens `ASWebAuthenticationSession` for consent.
- Validate the domain (must resolve, must answer `/api/v1/instance`) before opening the browser.
- On success: token in Keychain, feed loads. Logout deletes token and revokes it (`POST /oauth/revoke`, best-effort).

### F3 — Combined chronological feed
- Fetch home timelines from both networks, merge, sort by post creation time descending. No algorithmic ranking.
- Each row shows: avatar, display name, handle, network badge (Bluesky/Mastodon glyph), relative timestamp, text, images (async loaded), repost/boost attribution.
- Infinite scroll: fetch the next page of whichever network's cursor is older when nearing the bottom.
- Pull/⌘R to refresh. One network failing must not blank the other's posts — show a non-blocking banner instead.
- Works with only one network logged in.

### F4 / F5 — Follow & unfollow (both networks)
- From any post's author (context menu and profile popover): Follow / Unfollow, labelled with the network it applies to.
- Optimistic UI update; revert with a toast on API failure.

### F6 — Feed position restoration
- On scroll, debounce-save the topmost visible post's ID + network + timestamp to UserDefaults.
- On launch: fetch the feed, scroll to that post if present in the first N pages (N=3); otherwise start at top. Position older than 7 days is discarded.

### F7 — Scroll to top
- Toolbar button, visible only when scrolled away from top. Also bound to ⌘↑. Animated scroll; then a fresh-content check.

### F8 — Cross-posting composer
- ⌘N opens composer: text field, two checkboxes ("Post to Bluesky", "Post to Mastodon"), **both checked by default**; checkbox state persists across sessions.
- Character counter shows the tightest limit among checked networks (Bluesky 300 graphemes, Mastodon per-instance limit from `/api/v2/instance`, default 500). Post button disabled when over limit or no network checked.
- Posting to two networks is two independent calls: if one fails, report which one failed and offer retry for the failed one only — never silently double-post.

### F9 — Notifications indicator
- Poll each network's notifications endpoint (60 s interval, only while app is frontmost + immediately on activation).
- Toolbar bell with unread count badge; per-network counts in its tooltip.
- Clicking opens a notifications screen: a single chronological list of follows, mentions, and reposts/boosts, each row badged with its network. Opening the screen marks items seen.
- Types beyond follows/mentions/reposts (likes, quotes, polls) are out of scope for MVP.

### F10 — Search
- ⌘F or toolbar field. One query, fired at both networks in parallel (Bluesky `app.bsky.feed.searchPosts` + actor search; Mastodon `/api/v2/search`).
- Results in two sections: **People** (with follow buttons) and **Posts**, each row network-badged. Per-network failure shows in that section only.
- Debounce 300 ms; no search history stored.

### F11 — HIG & Liquid Glass
- Standard SwiftUI components, system materials, SF Symbols, system typography and spacing. No custom chrome.
- Full Dark Mode and accent-color support. Every interactive element has an accessibility label; feed is fully usable via VoiceOver and keyboard.

### F12 — Native platform behavior (macOS + iOS)
- **macOS:** single-window app with standard menu bar (File → New Post, Edit, View → Refresh/Scroll to Top, Window, Help); keyboard shortcuts as listed per feature; Settings in the standard ⌘, Settings window (accounts live here). App Sandbox on, network-client entitlement only, Hardened Runtime on.
- **iOS (iPhone + iPad):** single `WindowGroup`; there is no Settings scene, so Settings/About are reached from a toolbar entry (sheet or `NavigationStack`) reusing the same SwiftUI content. Hardware-keyboard shortcuts on iPad reuse the macOS command set; software-keyboard users get on-screen affordances for every action. Menu-bar–only and window-tab behaviors are `#if os(macOS)` and are **not** emulated on iOS.
- Both: every interactive element has an accessibility label; the app is fully usable via VoiceOver, and (iOS) supports Dynamic Type up to accessibility sizes without truncation or overlap.

### F13 — Resizable & responsive
- **macOS:** window freely resizable, min 480×600; window frame restored on relaunch (system-provided).
- **iOS:** usable at the narrowest supported iPhone width (iPhone SE) through iPad, in portrait and landscape; iPad supports Split View / Slide Over multitasking.
- Feed column caps at a comfortable reading width (~600 pt), centered when wider (covers wide Mac windows and iPad).
- Layout uses adaptive SwiftUI containers — nothing may truncate or overlap at any supported size. Touch targets are ≥ 44×44 pt on iOS.

### F14 — Inline quick reply
- Clicking a post's body expands the row to reveal an inline reply text field + Reply button; clicking again (or Cancel) collapses it. Works everywhere posts render: feed, thread, profile, search.
- Excluded from the expand-click (they keep their own action): avatar and username/handle (open profile), images (lightbox), video (play), links (open), and the "N replies" button (opens the thread — the only thread affordance).
- Reply posts to the network the original came from, using that account, attached as a reply (Bluesky reply record; Mastodon `in_reply_to_id`). On success the box collapses and clears; on failure it stays open with an inline error.
- Reply field + Reply button carry VoiceOver labels; empty text disables Reply.

### F15 — Direct Messages (both networks)
A unified DM inbox: a conversations list and a per-conversation message thread, read **and** send, across both networks. Reached from a dedicated entry (envelope) — the `•••` menu on iOS, a toolbar/menu item on macOS. Each conversation is network-badged.

**Privacy honesty (non-negotiable).** Neither network's DMs are end-to-end encrypted, and Mastodon "DMs" are not a private inbox at all — they are `direct`-visibility posts stored on the server, and **anyone @-mentioned in the thread is added to it**. Every Mastodon conversation carries a plain "Not private — visible to the server and everyone mentioned" note. No UI element may imply encryption or privacy the protocol doesn't provide.

- **Bluesky:** the chat service (`chat.bsky.convo.*` — `listConvos`, `getMessages`, `sendMessage`, `updateRead`), reached by proxying to the chat DID (`atproto-proxy: did:web:api.bsky.chat#bsky_chat`). Requires the DM-scoped app password (see Accounts & protocols); if the stored credential lacks chat access, surface a clear re-issue prompt instead of a raw error. Not E2E encrypted.
- **Mastodon:** `GET /api/v1/conversations` (list), `POST /api/v1/conversations/:id/read` (mark read). A message is a `direct`-visibility status; sending = `POST /api/v1/statuses` with `visibility: direct`, the other participants @-mentioned, and `in_reply_to_id` for threading. Character limit reuses the composer's per-network logic (F8).
- **Read:** conversations sorted by most-recent activity — participant avatar/name/handle, last-message snippet, relative time, unread dot, network badge. Opening a conversation shows its messages chronologically and marks it read (Bluesky `updateRead`; Mastodon conversations read endpoint).
- **Send:** a compose/reply box at the foot of the thread posts to that conversation's network only — **never cross-posted**. Optimistic append; on failure the message stays with an inline error and a retry, matching F8's per-network honesty. Empty text disables Send.
- **Unread + polling:** piggyback the F9 notifications poll (60 s, frontmost-only) for an unread indicator on the DM entry; fetch a conversation's messages on open. (`ponytail:` no push notifications — add only if a server component ever exists.)
- **Security:** message bodies are hostile input — typed `Codable`, tolerate missing/extra fields, render as text (never evaluated); **never log message content** (`%{private}`); tokens stay in Keychain. Any auth/entitlement touch gets a security pass.
- **Accessibility:** VoiceOver labels on conversation rows, messages, and the send box; usable at the 480×600 min and via VoiceOver/keyboard; Dynamic Type on iOS.

## Non-functional requirements

- Feed merge of 200 posts must complete in < 50 ms (unit-tested).
- No main-thread network or decode work; UI stays responsive during refresh.
- All network errors surface as human-readable messages; raw errors go to `os_log` only.
- Rate-limit responses (429) back off exponentially and tell the user; never hammer either API.

## Out of scope (MVP)

Multi-account, lists, offline cache, quote posts, polls, video upload, algorithmic feeds, muting/blocking, translations.

(DMs moved **into** scope as F15.)
