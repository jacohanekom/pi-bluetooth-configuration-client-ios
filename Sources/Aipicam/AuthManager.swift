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
    private static let nameKey = "pi-bluetooth-configuration.appleUserName"
    private static let emailKey = "pi-bluetooth-configuration.appleUserEmail"

    @Published private(set) var isSignedIn = false
    // True only until the startup credential check (below) completes --
    // AipicamApp shows a blank spinner for this brief window rather than
    // flashing the sign-in screen at someone who's actually still signed
    // in from a previous launch.
    @Published private(set) var isCheckingExistingSignIn = true
    @Published var lastError: String?

    // Captured from the ONE real Sign in with Apple authorization this
    // gate ever gets (see handleCompletion) and persisted locally so
    // ContentView's "Owner" section (POST /user, labeling a specific
    // connected Pi) can reuse it later -- Apple only ever shares a real
    // name/email on that Apple ID's very first authorization for this
    // app's bundle ID, and this gate's own sign-in screen consumes that
    // first authorization, so a second Sign in with Apple prompt
    // anywhere else in the app (e.g. that Owner section, enrolling a
    // newly-connected Pi) is guaranteed to come back empty. Either may
    // still end up empty here too (Apple shares nothing on any
    // subsequent authorization, including a reinstall on a new device
    // under the same Apple ID that already authorized this app once
    // before) -- ContentView falls back to plain editable text fields
    // in that case rather than depending on ever getting a second
    // chance at this data.
    @Published private(set) var name = ""
    @Published private(set) var email = ""

    init() {
        name = UserDefaults.standard.string(forKey: Self.nameKey) ?? ""
        email = UserDefaults.standard.string(forKey: Self.emailKey) ?? ""
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

            let fullName = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
            if !fullName.isEmpty {
                name = fullName
                UserDefaults.standard.set(fullName, forKey: Self.nameKey)
            }
            if let credEmail = credential.email, !credEmail.isEmpty {
                email = credEmail
                UserDefaults.standard.set(credEmail, forKey: Self.emailKey)
            }

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
