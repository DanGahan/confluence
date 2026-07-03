# CLAUDE.md — Way of working

Native macOS app: combined Bluesky + Mastodon feed. The product spec is `docs/SPEC.md` — read it before building anything; it is the source of truth. Fixed stack decisions live there and are not up for debate mid-task.

## Structure

```
Confluence/            # App target: SwiftUI views, app lifecycle only
ConfluenceKit/         # Local SPM package: API clients, models, merge logic, auth
ConfluenceKitTests/    # Unit + integration tests (bulk of all tests)
ConfluenceUITests/     # A handful of XCUITest smoke tests
docs/SPEC.md           # Feature spec with acceptance criteria
```

Views hold no business logic. Anything with a branch, a parser, or a network call belongs in `ConfluenceKit` where it can be tested without launching the app.

## Test pyramid (enforced)

Work test-first: for any behavior in `ConfluenceKit`, write the failing test, then the code. A PR that adds logic without tests at the right layer is not done.

1. **Unit tests (most — target ~70% of tests).** Swift Testing (`@Test`). Pure logic: feed merging/sorting, cursor pagination, character counting, position-restore rules, model decoding from fixture JSON captured from the real APIs. No network, no disk, milliseconds each.
2. **Integration tests (some — ~25%).** API clients tested against a mock `URLProtocol` — assert the exact request built (method, path, headers, body) and correct handling of success, 401 (token refresh), 429 (backoff), and malformed JSON. Keychain access tested against a test-scoped service name.
3. **UI tests (few — ~5%).** XCUITest smoke only: app launches, logged-out state shows onboarding, composer opens with both checkboxes ticked. Nothing that unit tests already cover.

Rules:
- Never call the real Bluesky/Mastodon APIs from tests. Fixtures live in `ConfluenceKitTests/Fixtures/`.
- Every bug fix starts with a test reproducing the bug.
- `swift test` in ConfluenceKit must pass before any commit. UI tests run before merge, not on every commit.

## Security (baked in, non-negotiable)

- **Credentials only in Keychain.** Tokens, app passwords, session JWTs — never in UserDefaults, files, or logs. Keychain items use `kSecAttrAccessibleWhenUnlocked`.
- **Never log secrets.** `os_log` with privacy annotations (`%{private}`) for anything user-derived. Grep for token/password strings in log calls during review.
- **Treat all network input as hostile.** Decode with `Codable` into typed models; tolerate missing/extra fields; never crash on malformed payloads (integration-tested). Post text is rendered as text, never evaluated — no WebViews for feed content.
- **HTTPS only.** No ATS exceptions. Mastodon instance domains are user input: validate before use, URL-encode, never string-interpolate into paths.
- **OAuth hygiene:** `ASWebAuthenticationSession` only (no embedded webviews), `state` parameter verified, tokens revoked on logout where the API allows.
- **App Sandbox + Hardened Runtime on**, entitlements limited to `com.apple.security.network.client`. Adding any entitlement requires a written justification in the PR.
- Any change touching auth, Keychain, or entitlements gets a security pass in review (run `/security-review` if available).

## Definition of done (per feature/PR)

1. Acceptance criteria in `docs/SPEC.md` for that feature are met — quote them in the PR description.
2. Tests exist at the correct pyramid layer and pass (`swift test` clean).
3. No new warnings; Swift 6 strict concurrency clean.
4. Security checklist above holds for the diff.
5. Feature works at the 480×600 minimum window size and in Dark Mode.
6. VoiceOver labels present on anything interactive that was added.

## Working style

- Work is tracked as GitHub issues on the [Confluence project board](https://github.com/users/DanGahan/projects/4) (states: New → In Progress → In QA → Done, plus Blocked). Pick an issue, move it to In Progress when you start, In QA when the PR is up, and note the blocker on the issue if you move it to Blocked. Use `gh` to update status.
- Small vertical slices: one SPEC feature (or sub-bullet) per PR. Don't scaffold ahead of need.
- Simplest implementation that satisfies the acceptance criteria; mark deliberate ceilings with a `// ponytail:` comment naming the upgrade path.
- If a spec ambiguity blocks you, note the interpretation you chose in the PR rather than stalling.
- Don't add dependencies, databases, caching layers, or abstractions the spec doesn't require. `docs/SPEC.md` lists what's out of scope — believe it.

## Commands

The Xcode project is generated from `project.yml` and is **not** committed. After cloning (and after editing `project.yml`), run `xcodegen generate` before any `xcodebuild` command. Install the tool with `brew install xcodegen`.

**First-time setup:** run `scripts/create-dev-cert.sh` once to create the local "Confluence Dev" code-signing identity. The build signs with it (`project.yml`), giving a stable signature so macOS Keychain "Always Allow" persists across rebuilds instead of re-prompting every launch. Replace with a real Apple Development team before distribution.

```bash
scripts/create-dev-cert.sh                      # one-time: local signing identity (stops Keychain prompts)
xcodegen generate                               # (re)create Confluence.xcodeproj from project.yml
swift test --package-path ConfluenceKit        # unit + integration (fast, run constantly)
xcodebuild -scheme Confluence build            # full app build
xcodebuild -scheme Confluence test             # includes UI smoke tests (slow, pre-merge)
```
