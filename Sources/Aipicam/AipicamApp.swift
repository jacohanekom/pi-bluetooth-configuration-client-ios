import SwiftUI

@main
struct AipicamApp: App {
    @StateObject private var http = HTTPManager()
    @StateObject private var auth = AuthManager()

    var body: some Scene {
        WindowGroup {
            // Sign in with Apple gates the whole app -- see AuthManager.
            // The brief isCheckingExistingSignIn window (validating a
            // previous launch's stored credential) shows neither screen,
            // to avoid flashing the sign-in screen at an already-signed-
            // in user.
            Group {
                if auth.isCheckingExistingSignIn {
                    ProgressView()
                } else if auth.isSignedIn {
                    ContentView()
                        .environmentObject(http)
                        .environmentObject(auth)
                } else {
                    SignInView()
                        .environmentObject(auth)
                }
            }
        }
    }
}
