import AuthenticationServices
import ConfluenceKit
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Production WebAuthenticator: runs the OAuth consent in a system browser sheet.
/// No embedded webview — ASWebAuthenticationSession only, per the security checklist.
///
/// Not @MainActor: ASWebAuthenticationSession calls its completion handler on a background
/// XPC queue, so a main-actor-isolated closure would trip Swift's executor check and crash.
/// AppKit calls are hopped to the main thread explicitly; the completion handler stays
/// isolation-free and only resumes the (thread-safe) continuation.
final class WebAuthSession: NSObject, WebAuthenticator, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    private var session: ASWebAuthenticationSession?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            // Explicit @Sendable type forces this closure to be nonisolated. The app target
            // defaults to main-actor isolation (Xcode 26), but ASWebAuthenticationSession
            // invokes the handler on a background queue — an isolated closure would trap.
            let completion: @Sendable (URL?, (any Error)?) -> Void = { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: MastodonError.authorizationDenied)
                } else {
                    continuation.resume(throwing: error ?? MastodonError.authorizationDenied)
                }
            }
            DispatchQueue.main.async {
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme, completionHandler: completion)
                session.presentationContextProvider = self
                self.session = session // retain until the callback fires
                if !session.start() {
                    continuation.resume(throwing: MastodonError.authorizationDenied)
                }
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(AppKit)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
        #endif
    }
}
