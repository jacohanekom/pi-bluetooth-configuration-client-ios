import AuthenticationServices
import SwiftUI

/// The very first screen on every launch until Sign in with Apple
/// succeeds (see AuthManager) -- nothing else in the app is reachable
/// until then; AipicamApp swaps this out for ContentView once
/// auth.isSignedIn flips true.
struct SignInView: View {
    @EnvironmentObject var auth: AuthManager

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("aipicam")
                    .font(.largeTitle.bold())
                Text("Sign in to continue")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                auth.handleCompletion(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 44)
            .padding(.horizontal, 40)

            if let error = auth.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Spacer()
        }
        .padding(20)
    }
}
