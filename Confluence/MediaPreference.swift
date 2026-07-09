import CoreGraphics

/// User-configurable media rendering (Settings → Media Preview), persisted in UserDefaults
/// and read via @AppStorage at each render site so changes apply live.
enum MediaPreference {
    /// When true, post images render at their full aspect ratio (portrait/landscape/square)
    /// scaled to the window, so the whole image is visible. When false: fixed letterbox.
    static let fullSizeKey = "displayFullSizeMedia"

    /// On by default — full-image previews are the expected behaviour; the toggle exists to
    /// opt back into the compact letterbox. Both read sites use this so they can't disagree
    /// when the key is unset.
    static let fullSizeDefault = true

    /// Cap for full-size images so a very tall portrait doesn't dominate the column; the image
    /// stays fully visible (scaled down, centred), and scales with the window below this.
    // ponytail: fixed cap; make it a slider in Settings if people want control.
    static let fullSizeMaxHeight: CGFloat = 520
}
