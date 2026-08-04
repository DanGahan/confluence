# CLAUDE.md — Way of working

Confluence: a native macOS app showing a combined Bluesky + Mastodon feed.

**Read these before building anything:**

- `docs/SPEC.md` — the product spec and source of truth. Features, acceptance criteria, and fixed stack decisions that are not up for debate mid-task.
- `docs/PROJECT.md` — how the codebase actually works: architecture, data flow, and the platform hacks/workarounds you must not regress (especially the rich-text/hit-testing section).
- `docs/GAPS.md` — the tech-debt ledger. Check it before working around something that's already a known gap; update it when you add or repay a `// ponytail:` shortcut.

## Non-negotiables

1. **Mac native.** macOS 26+, Swift 6, SwiftUI-first (AppKit only where SwiftUI genuinely can't — document why in the PR). Zero third-party dependencies: `URLSession` + `Codable` cover both APIs. System materials, SF Symbols, HIG behavior, Dark Mode, VoiceOver. No cross-platform abstractions, no web views for content.
2. **Re-use before new code.** Extend the existing pattern (normalized models, closure-injected stores, `RemoteImage`, `RichTextLabel`, `MockURLProtocol`) rather than inventing a parallel one. If something similar exists, use it or improve it — never duplicate it. `docs/PROJECT.md` has a "where do I…" index; start there.
3. **Simplified codebase, minimal tech debt.** Simplest implementation that meets the acceptance criteria. No speculative scaffolding, no abstractions with one caller, no databases or caching layers the spec doesn't require. Deliberate ceilings get a `// ponytail:` comment naming the upgrade path **and** a row in `docs/GAPS.md` — debt is only acceptable when it's tracked.

## Structure

```
Confluence/            # App target: SwiftUI views, app lifecycle only
ConfluenceKit/         # Local SPM package: API clients, models, merge logic, auth
ConfluenceKitTests/    # Unit + integration tests (bulk of all tests)
ConfluenceUITests/     # A handful of XCUITest smoke tests
docs/                  # SPEC.md, PROJECT.md, GAPS.md
```

Views hold no business logic. Anything with a branch, a parser, or a network call belongs in `ConfluenceKit` where it can be tested without launching the app.

## Test pyramid (enforced)

Work test-first: for any behavior in `ConfluenceKit`, write the failing test, then the code. A PR that adds logic without tests at the right layer is not done.

1. **Unit tests (~70%).** Swift Testing (`@Test`). Pure logic: merging/sorting, cursors, character counting, position restore, model decoding from fixture JSON captured from the real APIs. No network, no disk.
2. **Integration tests (~25%).** API clients against `MockURLProtocol` — assert the exact request built and correct handling of success, 401/expired-token refresh, 429 (backoff), and malformed JSON. Keychain tested against a test-scoped service name.
3. **UI tests (~5%).** XCUITest smoke only. Nothing unit tests already cover.

Rules: never call the real APIs from tests; every bug fix starts with a test reproducing the bug; `swift test --package-path ConfluenceKit` must pass before any commit.

## Security (baked in, non-negotiable)

- **Credentials only in Keychain** (`kSecAttrAccessibleWhenUnlocked`) — never UserDefaults, files, or logs.
- **Never log secrets.** `os_log` with `%{private}` for anything user-derived.
- **Treat all network input as hostile.** Typed `Codable` decode, tolerate missing/extra fields, never crash on malformed payloads. Post text is rendered as text, never evaluated.
- **HTTPS only, no ATS exceptions.** Mastodon instance domains are user input: validate, URL-encode, never string-interpolate into paths.
- **OAuth hygiene:** `ASWebAuthenticationSession` only, `state` verified, tokens revoked on logout where possible.
- **App Sandbox + Hardened Runtime on**, entitlements limited to `com.apple.security.network.client`. Any new entitlement needs written justification in the PR.
- Any change touching auth, Keychain, or entitlements gets a security pass in review (`/security-review` if available).

## Definition of done (per feature/PR)

1. Acceptance criteria in `docs/SPEC.md` met — quote them in the PR description.
2. Tests at the correct pyramid layer, passing.
3. No new warnings; Swift 6 strict concurrency clean.
4. Security checklist holds for the diff.
5. Works at the 480×600 minimum window size and in Dark Mode.
6. VoiceOver labels on anything interactive that was added.
7. `docs/GAPS.md` updated if debt was added or repaid.

## Working style

- Work is GitHub issues on the [Confluence project board](https://github.com/users/DanGahan/projects/4) (New → In Progress → In QA → Done, plus Blocked). Every issue goes on the board. Move status with `gh` as you go; note blockers on the issue.
- Small vertical slices: one SPEC feature (or sub-bullet) per PR.
- **PRs target `dev`, not `main`.** `main` is the prod-release track and is protected — direct pushes and unpromoted PRs are rejected. `dev` gets an auto-release on every push; a manual `dev → main` promotion PR cuts prod. Full model + diagram in [`docs/RELEASING.md`](docs/RELEASING.md).
- If a spec ambiguity blocks you, note the interpretation you chose in the PR rather than stalling.

## Commands

The Xcode project is generated from `project.yml` and is **not** committed. After cloning (and after editing `project.yml`), run `xcodegen generate` before any `xcodebuild` command. Install with `brew install xcodegen`.

**First-time setup:** run `scripts/create-dev-cert.sh` once to create the local "Confluence Dev" signing identity — a stable signature keeps macOS Keychain "Always Allow" working across rebuilds. Replace with a real Apple Development team before distribution.

```bash
scripts/create-dev-cert.sh                      # one-time: local signing identity
xcodegen generate                               # (re)create Confluence.xcodeproj from project.yml
swift test --package-path ConfluenceKit        # unit + integration (fast, run constantly)
xcodebuild -scheme Confluence build            # full app build
xcodebuild -scheme Confluence test             # includes UI smoke tests (slow, pre-merge)
```
