import AuthenticationServices
import ConfluenceKit

/// Production WebAuthenticator: runs the OAuth consent in a system browser sheet.
/// No embedded webview — ASWebAuthenticationSession only, per the security checklist.
@MainActor
final class WebAuthSession: NSObject, WebAuthenticator, ASWebAuthenticationPresentationContextProviding {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: MastodonError.authorizationDenied)
                } else {
                    continuation.resume(throwing: error ?? MastodonError.authorizationDenied)
                }
            }
            session.presentationContextProvider = self
            if !session.start() {
                continuation.resume(throwing: MastodonError.authorizationDenied)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}
