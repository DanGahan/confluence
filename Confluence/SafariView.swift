import SwiftUI

/// Where external web links open. iOS default is the in-app browser (#190); macOS always uses
/// the system browser.
enum BrowsingPreference {
    static let openLinksInAppKey = "openLinksInApp"
    static let openLinksInAppDefault = true
}

#if os(iOS)
import SafariServices

/// In-app browser (`SFSafariViewController`) presented as a sheet for external http(s) links,
/// matching the thread/profile sheet presentation. In-app profile/thread links don't use this.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#endif
