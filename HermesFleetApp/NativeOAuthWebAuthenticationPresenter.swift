import Foundation
import AuthenticationServices
import UIKit
import FleetCore

/// App-target presenter for the native OAuth authorize URL.
///
/// `ASWebAuthenticationSession` lives here (not in FleetCore) so package
/// tests stay host-runnable. The session uses `callbackURLScheme:
/// "hermes-fleet"` — already registered in `Info.plist` — and an ephemeral
/// browser session so cookies from other apps never leak in.
@MainActor
public final class NativeOAuthWebAuthenticationPresenter: NSObject, NativeOAuthBrowserPresenting {
    public static let callbackScheme = "hermes-fleet"

    public override init() {
        super.init()
    }

    nonisolated public func presentAuthorizeURL(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task { @MainActor in
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: Self.callbackScheme
                ) { _, error in
                    if let error = error as? ASWebAuthenticationSessionError,
                       error.code == .canceledLogin {
                        continuation.resume(throwing: NativeOAuthError.cancelled)
                    } else if error != nil {
                        continuation.resume(throwing: NativeOAuthError.networkError("browser session failed"))
                    } else {
                        // The loopback listener already captured code+state; the
                        // session completing is enough for the client to await it.
                        continuation.resume()
                    }
                }
                session.presentationContextProvider = OAuthPresentationAnchor.shared
                session.prefersEphemeralWebBrowserSession = true
                if !session.start() {
                    continuation.resume(throwing: NativeOAuthError.internalError("Failed to start browser session"))
                }
            }
        }
    }
}

private final class OAuthPresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthPresentationAnchor()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
            return window
        }
        return UIWindow(frame: UIScreen.main.bounds)
    }
}
