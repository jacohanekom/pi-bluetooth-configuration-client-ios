import AuthenticationServices
import Foundation

/// Gates the whole app behind Sign in with Apple -- AipicamApp shows
/// SignInView until this reports signed in, then switches to the normal
/// ContentView flow (device discovery, setup wizard, relay/solar
/// telemetry). Distinct from ContentView's own "Owner" section (POST
/// /user): that labels a specific *Pi* with whoever's responsible for
/// it, stored on the device itself; this is purely a local app-access
/// gate and never talks to a Pi at all.
///
/// Persisted locally (UserDefaults) so a signed-in user isn't asked
/// again on every launch. ASAuthorizationAppleIDProvider.credentialState
/// on that stored ID is Apple's own documented way to notice a
/// revocation (Settings -> [Apple ID] -> Sign-In & Security -> Apps
/// Using Apple ID -> removed) instead of trusting a stale local flag
/// forever.
@MainActor
final class AuthManager: ObservableObject {
    private static let userIdentifierKey = "pi-bluetooth-configuration.appleUserIdentifier"

    @Published private(set) var isSignedIn = false
    // True only until the startup credential check (below) completes --
    // AipicamApp shows a blank spinner for this brief window rather than
    // flashing the sign-in screen at someone who's actually still signed
    // in from a previous launch.
    @Published private(set) var isCheckingExistingSignIn = true
    @Published var lastError: String?

    init() {
        Task { await self.checkExistingSignIn() }
    }

    private func checkExistingSignIn() async {
        guard let userIdentifier = UserDefaults.standard.string(forKey: Self.userIdentifierKey) else {
            isCheckingExistingSignIn = false
            return
        }
        // getCredentialState(forUserID:completion:) bridges to this
        // async throws form automatically (Swift's importer rule for a
        // trailing (T, Error?) -> Void completion handler) -- no
        // completion-handler boilerplate needed.
        let state = try? await ASAuthorizationAppleIDProvider().credentialState(forUserID: userIdentifier)
        isSignedIn = (state == .authorized)
        isCheckingExistingSignIn = false
    }

    func handleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                lastError = "Sign in with Apple didn't return a usable credential."
                return
            }
            UserDefaults.standard.set(credential.user, forKey: Self.userIdentifierKey)
            lastError = nil
            isSignedIn = true
        case .failure(let error):
            let nsError = error as NSError
            // .canceled fires on a plain user-initiated cancel (tapping
            // outside the sheet, the system back gesture) -- not a real
            // failure worth surfacing as an error banner.
            if nsError.domain == ASAuthorizationError.errorDomain,
               nsError.code == ASAuthorizationError.canceled.rawValue {
                return
            }
            lastError = "Sign in with Apple failed: \(error.localizedDescription)"
        }
    }
}
