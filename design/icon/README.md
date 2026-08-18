# App icon — source art

`app.icon` is an [Icon Composer](https://developer.apple.com/) bundle and is the
**app icon itself** — Xcode 26 compiles it straight into the build (no PNG
export, no `.xcassets`). It's wired in `project.yml` via the target's `sources`
plus `ASSETCATALOG_COMPILER_APPICON_NAME: app`.

The loose `*.svg` files are the individual layers the bundle is composed from
(kept for editing); `app.icon/Assets/` holds the copies Icon Composer actually
uses. Edit the icon by opening `app.icon` in Icon Composer.

Tracking: #148.
