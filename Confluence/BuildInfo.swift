import Foundation

/// Build-time metadata surfaced in the About window (and anywhere else). Values are
/// injected via Info.plist by the release workflows; local dev builds get "dev"/"local".
enum BuildInfo {
    /// The marketing version — `YYYYMMDD` for prod, `DEV_YYMMDDHHMM` for dev CI, `dev`
    /// when no release-time override was set (local `xcodebuild` from a workstation).
    static let version: String = {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }()

    /// The git commit the artefact was built from, or "local" for developer builds.
    static let commit: String = {
        let value = Bundle.main.infoDictionary?["ConfluenceCommit"] as? String
        guard let value, !value.isEmpty, value != "local" else { return "local" }
        return value
    }()

    /// Short (7-char) form of `commit` for compact display.
    static let commitShort: String = String(commit.prefix(7))

    /// GitHub URL for the commit the artefact was built from, if known.
    static let commitURL: URL? = {
        guard commit != "local", commit.count >= 7 else { return nil }
        return URL(string: "https://github.com/DanGahan/confluence/commit/\(commit)")
    }()
}
