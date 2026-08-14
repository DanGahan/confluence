# iOS validation script

Manual checks for the iOS-port tickets whose behaviour depends on a real login,
the system Photos picker, or the OAuth browser flow — things XCUITest can't
drive. Automated reachability for each is already covered in `ConfluenceUITests`
(the tests named below); this script is the **behavioural** validation.

Tick each box on a real run. If something fails, note it on the ticket.

## Prerequisites

1. Xcode with the **iOS 26 platform** installed (Settings → Components).
2. An **iPhone 17 (iOS 26)** simulator, or a real device.
3. Build + install the app on the simulator:
   ```sh
   xcodegen generate
   xcodebuild -scheme Confluence -configuration Debug \
     -destination 'platform=iOS Simulator,name=iPhone 17' build
   xcrun simctl boot "iPhone 17"
   xcrun simctl install "iPhone 17" \
     "$(find ~/Library/Developer/Xcode/DerivedData/Confluence-*/Build/Products/Debug-iphonesimulator -maxdepth 1 -name Confluence.app | head -1)"
   xcrun simctl launch "iPhone 17" com.dangahan.confluence
   ```
   (Launch with **no** `-uiTest*` args so it uses the real Keychain + network.)
4. Have to hand: a **Bluesky handle + app password** (bsky.app → Settings → App
   Passwords) and a **Mastodon account** on some instance.

---

## #162 — Auth round-trip (WebAuthSession anchor, Keychain)

Automated: `testBlueskyLoginSheetPresentsOnIOS` (login sheet reachable).

- [ ] **Bluesky login.** Onboarding → **Add Bluesky Account** → enter handle +
      app password → **Sign In**. Feed loads with your Bluesky posts. No crash,
      no Keychain password prompt loop.
- [ ] **Mastodon login.** Add Mastodon Account → type your instance domain →
      the **`ASWebAuthenticationSession`** system sheet opens (a real browser
      sheet, *not* an embedded web view) → approve → returns to the app, feed
      now includes Mastodon posts.
- [ ] **Session persists.** Force-quit (swipe up) and relaunch → still logged in
      to both, feed loads without re-auth (Keychain restore works on iOS).
- [ ] **Logout.** Settings (gear) → Accounts → Sign Out (each network) → returns
      to onboarding; relaunch confirms the session is gone.

## #159 — Image attach (composer) + media rendering

Automated: `testComposerHasPhotoAttachOnIOS` (attach control present),
`testTappingImageOpensLightbox` (lightbox opens).

- [ ] **Attach from Photos.** Compose (✎) → **Attach photo** → Photo Library →
      pick an image → it appears as a thumbnail chip in the composer.
- [ ] **Alt text.** Add alt text to the attached image (tap the chip) — persists.
- [ ] **Post it.** Post to Bluesky and/or Mastodon → the post appears in the feed
      **with the image** (downscaled, not the multi-MB original — check it isn't
      rejected for size).
- [ ] **Feed image + lightbox.** An image in the feed renders letterboxed with no
      overflow; tap it → full-screen lightbox opens; pinch/zoom works; close
      returns to the feed.

## #160 — Appearance (font / size / link colour)

Automated: `testAppearanceSettingsReachableOnIOS` (pane + controls reachable).

- [ ] **Font.** Settings → Fonts & Colors → change **Font** (e.g. Serif) → the
      Preview text and the feed post bodies re-render in that font **live**.
- [ ] **Size.** Move the **Size** slider → post text grows/shrinks live.
- [ ] **Link colour.** Open **Link Colour** → pick a colour → links in posts (and
      the preview link) take that colour live.
- [ ] **Reset.** **Reset to Default** restores System font / default size / accent
      link colour.
- [ ] **Full-size media** (Settings → Media Preview) toggles between letterbox and
      natural-aspect image display in the feed.

---

## General iOS smoke (covered by automation, worth an eyeball)

- [ ] Feed scrolls smoothly; pull-to-refresh works.
- [ ] Tap a post body → inline reply box; type + **Reply** posts to the right
      network. Tap username/avatar → profile. Tap an @-mention → in-app profile.
      Tap **N replies** → thread.
- [ ] Toolbar: search, notifications, and the **•••** overflow (filter / live mode
      / refresh) all work; compose FAB works.
- [ ] **Dark Mode** and **Dynamic Type** (Settings app → Accessibility → larger
      text): nothing truncates or overlaps at the largest sizes.
- [ ] Works down to the narrowest iPhone (SE) width.
