import SwiftUI
import UIKit

/// Shown exactly once, right after the very first successful POST
/// /finish (see AdminCredentials' own comment in HTTPManager.swift) --
/// this is the only time pi-bluetooth-configuration-alpine ever hands
/// back this device's admin username/password; only a password hash is
/// kept on the Pi from then on, so there's no "forgot it, show me
/// again" path. Presented as a non-swipe-dismissible sheet (see
/// ContentView's .interactiveDismissDisabled() below) specifically so
/// it can't be lost to a reflexive swipe before it's actually been
/// saved somewhere.
struct AdminCredentialsView: View {
    let credentials: AdminCredentials
    let onDone: () -> Void

    @State private var isPasswordVisible = false
    @State private var copiedField: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Save These Now").font(.title2.bold())
                Text("Root login is disabled on this Pi -- this account is the only way in from now on. The Pi only keeps a password hash, not the password itself, so if you lose it there's no way to recover it; you'd need to wipe the account on the device and let the next \"Finish\" generate a new one. Once logged in, use \u{201c}doas\u{201d} for anything that needs root.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            credentialRow(label: "Username", value: credentials.username, isSecret: false)
            credentialRow(label: "Password", value: credentials.password, isSecret: true)

            Spacer(minLength: 0)

            Button {
                onDone()
            } label: {
                Text("I've Saved This").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(20)
        .interactiveDismissDisabled()
    }

    private func credentialRow(label: String, value: String, isSecret: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack {
                Group {
                    if isSecret && !isPasswordVisible {
                        // Same-length dots, not a fixed placeholder --
                        // avoids implying a different password length
                        // than the real one.
                        Text(String(repeating: "•", count: value.count))
                    } else {
                        Text(value)
                    }
                }
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

                Spacer()

                if isSecret {
                    Button {
                        isPasswordVisible.toggle()
                    } label: {
                        Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Button {
                    UIPasteboard.general.string = value
                    copiedField = label
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if copiedField == label { copiedField = nil }
                    }
                } label: {
                    Image(systemName: copiedField == label ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
