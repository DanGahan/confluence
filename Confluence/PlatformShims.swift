import SwiftUI

// Tiny cross-platform seams for the macOS/iOS shared codebase. Free functions + a typealias —
// deliberately NOT an abstraction layer (see CLAUDE.md / docs/IOS_PLAN.md).
#if canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension Image {
    /// `Image(nsImage:)` on macOS, `Image(uiImage:)` on iOS.
    init(platformImage: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// Open a URL in the system browser (macOS `NSWorkspace`, iOS `UIApplication`).
@MainActor func openExternally(_ url: URL) {
    #if canImport(AppKit)
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
}
