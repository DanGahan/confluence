# iOS Plan — Confluence on iOS 26/27 from the shared codebase

Goal: ship Confluence for iOS (iPhone + iPad), **one codebase, one repo, no fork**.
One multiplatform app target with `#if os(...)` seams where the platforms genuinely
differ; everything else stays shared. This document is the implementation map —
each numbered work item is intended to become one ticket.

Why this is tractable: the architecture already does the hard part. `ConfluenceKit`
(models, API clients, stores, merge logic, auth state) is pure Foundation +
Observation — **zero AppKit except one file** — and views hold no business logic.
The port is almost entirely about the thin view layer and the macOS platform hacks,
most of which exist to work around macOS-specific SwiftUI bugs and may simply not
be needed on iOS.

---

## 0. Ground rules & decisions (settle before ticketing)

- **D1 — Spec change first.** `CLAUDE.md` non-negotiable #1 says "Mac native"; `docs/SPEC.md`
  F12 is "macOS first". Adding iOS is a product decision: amend SPEC (new platform section,
  iOS acceptance criteria) and CLAUDE.md before any code. Without this, every iOS PR
  violates the house rules.
- **D2 — Deployment floor: iOS 26.** Matches the macOS 26 floor and the Swift 6.2 /
  macOS-26-SDK toolchain we already require. iOS 27 (SDK ships with Xcode 27) is a
  *compatibility pass*, not a second target — build against the newest SDK, keep the
  26 floor, fix deprecations as they appear.
- **D3 — One target, `#if os()` seams, no protocol abstraction layers.** Do not build a
  "PlatformAbstraction" module. Small file-level shims (`#if canImport(AppKit)`) and a couple
  of typealiases are enough. Re-evaluate only if the seams multiply.
- **D4 — iPhone and iPad from day one.** The app is one adaptive window; the existing
  480×600-min responsive layout (SPEC F13) is close to iPhone-width already. iPad gets
  multitasking/Split View for free via SwiftUI.
- **D5 — Distribution needs the Apple Developer account.** TestFlight/App Store require the
  paid account already wanted for notarisation (#151). Do that ticket first or in parallel;
  simulator-only development needs nothing.

---

## 1. Current platform inventory (what actually binds us to macOS)

From a full grep of AppKit symbols. This is the entire porting surface:

| File | AppKit usage | iOS strategy |
|---|---|---|
| `ConfluenceKit/LinkGeometry.swift` | `import AppKit`; NSLayoutManager/NSTextContainer/NSTextStorage | **Trivial**: TextKit 1 classes exist on iOS via UIKit. `#if canImport(AppKit) import AppKit #else import UIKit #endif`. Only kit change needed. |
| `RichTextLabel.swift` | NSTextView, NSViewRepresentable, NSCursor, NSEvent, TextKit 1 stack | **Biggest decision — see §3.** Try plain SwiftUI `Text` on iOS first; the NSTextView exists to dodge macOS-only bugs. |
| `ConfluenceApp.swift` | NSApplicationDelegateAdaptor, window-restore hack, `FeedWindowConfigurator` (tab grouping) | Gate all of it `#if os(macOS)`. iOS needs none of it (no window tabs, no AppKit delegate). |
| `AppCommands.swift` | NSApp, NSWindow (menu bar commands) | Keep under `#if os(macOS)` initially; iPadOS 26 menu bar + hardware-keyboard shortcuts can reuse `.commands` later (nice-to-have ticket). |
| `AboutView.swift` | NSPanel, NSHostingView, NSApp | Gate `#if os(macOS)`. iOS: About becomes a row in Settings → simple sheet. |
| `ComposerView.swift` | NSOpenPanel, NSImage, NSBitmapImageRep (image pick + JPEG downscale) | NSOpenPanel → `PhotosPicker` (consider adopting on macOS too — it exists there; one code path). Downscale/JPEG re-encode → `#if` shim or CoreGraphics (`CGImageSource`/`CGImageDestination`, shared on both). |
| `RemoteImage.swift` | NSImage, NSCache | `typealias PlatformImage = NSImage/UIImage` + `Image(nsImage:)`/`Image(uiImage:)` shim. NSCache exists on iOS unchanged. |
| `PostAppearance.swift` | NSFont, NSColor, NSFontDescriptor | UIFont/UIColor mirror via `#if`, or move to SwiftUI `Font`/`Color` where possible. |
| `ProfileLinkHandler.swift` | NSWorkspace.open, NSTextView reference in comment | `NSWorkspace.shared.open` → `UIApplication.shared.open` shim (one function: `openExternally(_ url:)`). |
| `FeedView.swift` | NSSharingService (Safari Reading List) | No public Reading List API on iOS. Keep Reading List `#if os(macOS)`; `ShareLink` (already used) covers iOS sharing. |
| `WebAuthSession.swift` | NSApplication (ASWebAuthenticationSession presentation anchor) | ASWebAuthenticationSession is cross-platform; only the `presentationAnchor` differs (NSWindow vs UIWindow). Small `#if`. |
| `Keychain.swift` (kit, no AppKit but macOS-specific behavior) | Legacy-keychain fallback on `errSecMissingEntitlement` (G8) | iOS always uses the data-protection keychain; gate the fallback `#if os(macOS)`. |

Everything else — stores, clients, models, merge logic, `MockURLProtocol` tests,
`QuickReply`, `ThreadView`, `ProfileView`, `SearchView`, `NotificationsView`,
`ImageLightbox` (SwiftUI), `PostVideoView` (AVKit, cross-platform), `LinkCardView`,
`Avatar`, `NetworkBadge` — is already portable SwiftUI/Foundation.

---

## 2. Phase plan (each numbered item ≈ one ticket)

### Phase A — Foundations (compiles for iOS, nothing works yet)

1. **Spec + docs amendment (D1).** SPEC gains an iOS platform section + per-feature iOS
   acceptance criteria (navigation, touch, min sizes). CLAUDE.md non-negotiable #1 reworded
   to "Apple-native (macOS + iOS)". PROJECT.md gains an "iOS differences" section.
2. **project.yml: multiplatform target.** xcodegen `supportedDestinations: [macOS, iOS]`
   on the Confluence target (or a second `Confluence-iOS` target sharing `sources:` if
   destinations fight the per-platform settings — xcodegen supports both; prefer
   supportedDestinations). iOS deployment target 26.0. New iOS Info.plist keys
   (`UILaunchScreen`, orientation, `LSApplicationCategoryType` already set).
   App icon: the Icon Composer bundle already declares `squares: shared` — verify it
   compiles for iOS (`ASSETCATALOG_COMPILER_APPICON_NAME: app` unchanged).
3. **Compile-gate sweep.** Mechanical pass adding `#if os(macOS)` around the inventory in §1
   (window hacks, menus, About panel, Reading List, app delegate) and the
   `canImport` header in `LinkGeometry.swift`. Definition of done: **iOS target builds**
   (`xcodebuild -destination 'generic/platform=iOS Simulator' build`) with features stubbed,
   macOS build byte-identical in behavior. No new warnings on either platform.

### Phase B — Platform shims (small, shared, boring)

4. **Image shim.** `PlatformImage` typealias + `Image(platformImage:)` init;
   port `RemoteImage`/`ImageCache`. Move the composer's downscale/JPEG re-encode to
   CoreGraphics so it is *one shared implementation*, deleting the NSBitmapImageRep path
   (repays part of G7 while in there).
5. **Appearance shim.** `PostAppearance` → UIFont/UIColor mirrors or SwiftUI-native
   `Font`/`Color`. Settings font/color pickers must work on both (macOS font panel is
   AppKit-only; use a font list picker on iOS).
6. **Open-URL + share shim.** `openExternally(_:)` wrapping NSWorkspace/UIApplication;
   Reading List button `#if os(macOS)`.
7. **Auth presentation.** `WebAuthSession` anchor per-platform; verify the full Mastodon
   OAuth round-trip on iOS simulator. Gate the Keychain legacy fallback to macOS
   (G8 note: fallback never valid on iOS).

### Phase C — Rich text & interaction (the real engineering)

8. **iOS rich-text spike (timeboxed).** The entire `RichTextLabel`/`LinkClickRouter`/TextKit-1
   apparatus exists because of three *macOS* bugs (PROJECT.md "Rich text" — dead `Text` links
   in LazyVStack, misrouted representable clicks, scaledToFill hit-testing). **On iOS, first
   try the naive thing**: SwiftUI `Text(attributedText)` with `.link` runs + `openURL`
   environment, inside the same feed stack, on device. Outcomes:
   - *Links tap fine (likely):* iOS uses `Text`; `RichTextLabel` becomes
     `#if os(macOS)`-only. One `PostBody` view chooses per platform. LinkClickRouter is
     **not ported** — it's a macOS workaround, not a feature.
   - *Links dead on iOS too:* port `RichTextLabel` to UITextView (TextKit 1 explicit stack,
     reusing `LinkGeometry` unchanged — that's why it lives in the kit). No event-monitor
     equivalent exists on iOS; use UITextView's native link interaction, which
     historically works.
   Ticket output = decision + working post body on iOS. Do not skip the spike and
   pre-port the workarounds "to be safe" — that bakes in complexity iOS may not need.
9. **Hit-testing audit on iOS.** Re-verify the §1/PROJECT.md gotchas under touch:
   scaledToFill overflow (`RemoteImage` containment already handles it — confirm),
   quick-reply expand tap vs. link taps vs. avatar/username, context menus
   (SwiftUI `.contextMenu` maps to long-press on iOS — free, but *verify the reply/repost
   menu items all fire*), lightbox tap targets ≥ 44pt.
10. **Quick reply on touch.** Focus/keyboard behavior: field must scroll into view above the
    on-screen keyboard (ScrollViewReader + keyboard avoidance is automatic in SwiftUI —
    verify inside LazyVStack), ⌘↩ shortcut is hardware-keyboard-only, add explicit
    Reply button affordance check at iPhone width. Re-run the beachball stress case
    (all boxes open) on iOS — the LazyVStack sizeThatFits blowup was macOS-observed;
    confirm the single-line field holds on iOS too.

### Phase D — App structure & navigation

11. **Scenes.** iOS: single `WindowGroup`; Settings scene doesn't exist on iOS → Settings
    becomes a sheet/NavigationStack screen reachable from the toolbar (reuse `SettingsView`
    content; it's SwiftUI). About row moves there (item 3's stub becomes real).
12. **Toolbar & layout at iPhone width.** Current toolbar (search, bell, live mode, refresh,
    scroll-to-top, compose FAB) must collapse sensibly on iPhone: keep compose as the
    floating button, move overflow into a toolbar menu. Feed column cap (~600pt) already
    handles iPad. Acceptance: everything reachable at iPhone SE width, Dynamic Type
    up to accessibility sizes, Dark Mode, VoiceOver labels intact (they're all in code
    already — verify, don't rewrite).
13. **Sheets → navigation audit.** Thread/Profile/Search/Notifications/Composer are all
    `.sheet`s today, which works on iOS, but nested sheet-from-sheet (profile → thread →
    profile) needs testing on iOS presentation; convert to `NavigationStack` pushes where
    sheets stack badly. Keep macOS behavior unchanged.
14. **Scene phase & live mode.** Live-mode loop already keys off `scenePhase` — verify
    backgrounding suspends polling on iOS (it should, same API). Add `.backgroundTask` /
    BGAppRefresh only if notifications polling is wanted in background — **default: don't**
    (YAGNI; notifications are foreground-only per SPEC F9).

### Phase E — CI, tests, distribution

15. **CI: iOS build + test jobs.** In `ci.yml`: `xcodebuild -scheme Confluence
    -destination 'platform=iOS Simulator,name=iPhone 17' build` and a `swift test` run is
    already platform-neutral (kit tests run on macOS; they're Foundation-only — no iOS sim
    needed for the kit). Add an iOS UI smoke lane mirroring the macOS one (launch,
    logged-out onboarding) in a new `ConfluenceUITests-iOS` target or a shared UITest target
    with two destinations. Runner: `macos-26` already has the iOS 26 SDK.
16. **iOS 27 compatibility pass.** When Xcode 27/iOS 27 SDK lands on runners: build both
    platforms against it, triage deprecations, keep floors at 26. One ticket, recurring
    per major SDK.
17. **Distribution.** Blocked on the Apple Developer account (#151). Then: bundle IDs
    (`com.dangahan.confluence` shared or `.ios` suffix — prefer shared for universal
    purchase), signing via App Store Connect API key in CI, TestFlight lane in a new
    `ios-release.yml` (build → archive → `xcrun altool`/`xcrun notarytool` equivalent:
    `xcodebuild -exportArchive` + App Store Connect upload). Keep it manual-dispatch like
    prod-release.yml. App Store listing/screenshots are product work, separate ticket.

---

## 3. Key considerations & risks (read before estimating)

- **The macOS hacks are liabilities to *not* port.** LinkClickRouter, FeedWindowConfigurator,
  the window-restore hack, TextKit-1 forcing — each exists to patch a macOS-specific
  platform bug. The iOS port's biggest failure mode is reflexively porting them. Each gets
  an explicit "needed on iOS?" spike before any port (items 8–9). Expected outcome: iOS
  needs none of them and the shared code *shrinks* relative to lines-touched.
- **Interaction model deltas that need explicit design passes:** right-click → long-press
  (free via `.contextMenu`, but discoverability differs — the quick-reply body-tap becomes
  *more* important on iOS); hover states (link pointing-hand, tooltips) don't exist on
  iPhone — nothing relies on hover for function today, verify that stays true; drag-select
  in posts (G9 trade-off) is irrelevant on iOS (text selection via long-press works in
  UITextView, differently in `Text` — note in the spike).
- **Keyboard shortcuts** (⌘N/⌘R/⌘↑/⌘S/⌘T) only fire with hardware keyboards on iPad. Tab
  hack (⌘T) is meaningless on iOS — gate it out, don't emulate.
- **Performance envelope.** The feed's LazyVStack + RemoteImage were tuned on Mac hardware.
  iPhone thermals/memory need one profiling pass (Instruments, scroll a 500-post feed on
  the oldest iOS-26-capable iPhone). The image cache is unbounded in-memory (NSCache
  self-evicts, but verify pressure behavior on iOS).
- **App Review exposure (new for this project).** macOS distribution is unsigned zips; the
  App Store brings review: account deletion requirement doesn't apply (we don't create
  accounts — we OAuth to third parties), but log-out must be obvious; content policy for a
  social client is settled precedent (Ivory, Bluesky itself) — low risk, non-zero.
- **Universal purchase / bundle ID choice** (item 17) is one-way: decide before first
  TestFlight upload.
- **What does *not* change:** ConfluenceKit API surface, all store logic, the test pyramid
  (kit tests stay platform-free — that's the payoff of the closure-injection design),
  release model for macOS, Homebrew tap.

---

## 4. Suggested ticket sizing & order

Small (≤ ½ day): 1, 3, 4, 5, 6, 7, 14, 16
Medium (1–2 days): 2, 9, 10, 11, 12, 15
Large / has unknowns (timebox): 8 (spike, 2 days cap), 13, 17

Critical path: 1 → 2 → 3 → 8 → 12 → 15 → 17.
Everything in Phase B parallelizes after 3. Items 9/10/13 need 8 decided first.
17 is blocked on the Apple Developer account (#151) but nothing else is.
