# Releasing Confluence

Two tracks: **dev** (automatic on every push to `dev`) and **prod** (manually
dispatched from `main`). Both produce a downloadable, ad-hoc-signed `.zip` of
`Confluence.app` on the [Releases page](https://github.com/DanGahan/confluence/releases).

## CI checks (both PR and release paths)

`.github/workflows/ci.yml` runs on every PR (to `dev` or `main`) and on every
push to `dev`/`main`. Both release workflows call it via `workflow_call`
before their build step, so a red CI blocks a release. Jobs:

- **Tests (unit + integration)** — `swift test --package-path ConfluenceKit`.
- **Build (app target, unsigned)** — `xcodebuild build` at Debug with signing
  disabled. Catches app-target compile regressions that `swift test` on the
  kit doesn't see.
- **SAST (Semgrep)** — `semgrep --config=p/default` on a Linux runner
  (source-only, no macOS toolchain needed). Findings surface on the Security
  tab as SARIF. We tried CodeQL first; its Swift extractor hung >30 min
  against Swift 6.2 / macOS 26 SDK under both `manual` and `autobuild` modes.
  Revisit if GitHub ships a working Swift 6.2 extractor.

Not in CI by design:

- **UI tests** — the XCUITest smoke suite (`xcodebuild test -scheme Confluence`)
  stays a local pre-merge concern per the pyramid in `CLAUDE.md`. Re-visit if
  CI-runner flake becomes acceptable.
- **Notarisation** — needs an Apple Developer ID; we're ad-hoc signed.

Passive checks (no CI change needed):

- **Secret scanning** — GitHub-native, on for public repos.
- **Dependabot** — `.github/dependabot.yml` opens weekly PRs against `dev`
  for GitHub Actions updates.

## Branching model

```
feature/*  ─┐
fix/*       ├─► PR into ─► dev  ─(merge)──► main
docs/*      │              │                │
            │              │ push           │ workflow_dispatch
            │              ▼                ▼
            │       Dev release        Prod release
            │       (auto)             (manual)
```

- **`dev`** — long-lived. All feature PRs target `dev`. Every merge triggers
  `.github/workflows/dev-release.yml`, which builds a dev artefact and
  publishes it as a **prerelease** tagged `dev-DEV_YYMMDDHHMM`.
- **`main`** — long-lived. Represents shipped prod. Only advances by merging
  `dev` in (fast-forward or PR) when we're ready to ship.
- **Prod release** — dispatch `.github/workflows/prod-release.yml` from
  `main`. Type `release` in the confirm input. It refuses to run against any
  other branch. Produces a **latest** release tagged `YYYYMMDD` (with `-N`
  suffix if we ship more than one on the same day).

## Version scheme

Both formats sort lexicographically, so `gh release list` orders them
naturally and directory listings of downloaded artefacts stay chronological.

| Track | Format                | Example              |
|-------|-----------------------|----------------------|
| Dev   | `DEV_YYMMDDHHMM` (UTC)| `DEV_2607291457`     |
| Prod  | `YYYYMMDD` (UTC)      | `20260729`           |

The version becomes `CFBundleShortVersionString`; it's shown in the About
window (Confluence menu → About Confluence), alongside a tappable link to
the commit the artefact was built from.

## What's actually signed

Ad-hoc (`codesign --sign -`). We don't have an Apple Developer ID, so:

- macOS marks the download as "from the internet" (quarantine attribute).
- On first launch, Gatekeeper blocks with "Apple could not verify Confluence.app
  is free of malware that may harm your Mac or compromise your privacy."
- Since macOS 15, the classic right-click → **Open** bypass is gone for
  non-notarised apps. Users approve via **System Settings → Privacy & Security
  → Open Anyway**, or strip the quarantine attribute in Terminal.

The signature is still valid (hardened runtime on, sandbox on) — it's just
not anchored to Apple's root, so Gatekeeper wants a one-time approval that
proves a human made the choice.

## Install instructions (paste into a release description if useful)

1. Download `Confluence-<version>.zip` from the release.
2. Unzip; drag `Confluence.app` to `/Applications`.
3. Double-click. Gatekeeper blocks with the "could not verify" dialog — this
   is expected for any app that isn't notarised.
4. **Approve once**, either:
   - **System Settings → Privacy & Security**, scroll to the bottom →
     "Confluence was blocked to protect your Mac" → **Open Anyway** → confirm
     with Touch ID / password. Then double-click Confluence and pick **Open**
     on the follow-up dialog.
   - Or in Terminal:
     ```
     xattr -d com.apple.quarantine /Applications/Confluence.app
     ```
     Then double-click as normal.

Subsequent launches (and later versions replacing the same bundle) don't
re-prompt.

## Cutting a prod release

1. Confirm `main` is behind `dev` and everything you want to ship is on `dev`.
2. Merge (or fast-forward) `dev` into `main`:
   ```
   git checkout main
   git merge --ff-only origin/dev
   git push origin main
   ```
3. Go to the [Actions tab](https://github.com/DanGahan/confluence/actions/workflows/prod-release.yml),
   click **Run workflow**, pick `main`, type `release` in the confirm input.

The prod tag reuses today's date; if a second cut is needed on the same day
the workflow appends `-2`, `-3` etc. automatically.

## Local sanity check before pushing

Nothing in either workflow can't be run locally. To dry-run the exact build
step a workflow will do:

```
brew install xcodegen
xcodegen generate
xcodebuild \
  -scheme Confluence \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  MARKETING_VERSION=DEV_local \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  build
```

The artefact is at `build/Build/Products/Release/Confluence.app`.
