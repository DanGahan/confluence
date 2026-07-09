# Confluence

**One timeline. Two networks. Properly Mac.**

Confluence brings your Bluesky and Mastodon feeds together in a single,
beautiful, chronological timeline — a real native macOS app, not a website in
a window.

Your social world split in two. Your attention doesn't have to.

## Why Confluence

**🌊 One combined feed.** Posts from Bluesky and Mastodon, merged and sorted by
time — no algorithm deciding what you see, no switching between apps or tabs.
Each post carries a subtle badge so you always know where it came from. One
network having a bad day? The other keeps flowing.

**🖥 Genuinely native.** Built with Swift and SwiftUI for macOS Tahoe. Liquid
Glass materials, Dark Mode, your accent colour, the menu bar and keyboard
shortcuts you expect (⌘N to post, ⌘R to refresh, ⌘T for a new tab, ⌘F to
search). Resize it, tab it, put it beside your work — it behaves like a Mac
app because it is one.

**✍️ Post once, reach everyone.** The cross-posting composer sends to Bluesky
and Mastodon in one go — with a character counter that tracks the tightest
limit, image attachments, drafts you can save and pick up later, and honest
per-network error handling: if one side fails, retry just that one. Never a
double post.

**📸 Rich media, inline.** Photos open in a lightbox. Videos and GIFs play
right in the feed — Bluesky clips and Mastodon videos alike — with a tap on
the poster frame. Link previews render as tidy cards.

**💬 Follow the conversation.** Click any post to open its thread. Tap an
@-mention or an author to see their profile, and follow or unfollow on either
network without leaving the app.

**🔔 Notifications, unified.** Mentions, new followers, and boosts from both
networks in one chronological list, with an unread badge in the toolbar.

**🔎 Search everywhere at once.** One query, both networks, results split into
People and Posts — with follow buttons right in the results.

**📍 Picks up where you left off.** Confluence remembers your place in the
feed across launches, restores your window and tabs, and offers one-click
scroll-to-top when you want *now* instead of *then*.

**🔒 Private by design.** Your credentials live in the macOS Keychain and
nowhere else. Sign in to Mastodon with standard OAuth in your browser — the
app never sees your password. Sandboxed, hardened, HTTPS-only, and zero
third-party code: nothing phones home, because there's nothing else in there.

## Getting started

1. **Bluesky:** sign in with your handle and an [app password](https://bsky.app/settings/app-passwords).
2. **Mastodon:** type your instance (like `mastodon.social`) and approve the
   app in your browser.
3. That's it. Your combined feed loads — either account works alone, too.

## Requirements

- macOS 26 (Tahoe) or later
- A Bluesky account, a Mastodon account, or both

## For developers

Confluence is Swift 6 + SwiftUI with zero dependencies, and the business logic
lives in a fully unit-tested Swift package. Start with
[docs/PROJECT.md](docs/PROJECT.md) for the architecture tour,
[docs/SPEC.md](docs/SPEC.md) for the feature spec, and
[CLAUDE.md](CLAUDE.md) for the working agreements.

```bash
brew install xcodegen
scripts/create-dev-cert.sh
xcodegen generate
xcodebuild -scheme Confluence build
```
