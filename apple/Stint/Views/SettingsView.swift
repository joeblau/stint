import SwiftUI

struct SettingsView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section("F1 Account") {
                Text("Log in with your F1 account to stream live sessions. Opens account.formula1.com in your browser.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button {
                    openURL(F1Account.loginURL)
                } label: {
                    Label("Log in with F1 account", systemImage: "play.tv")
                }
                .accessibilityIdentifier("settings-login")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .tint(StintPalette.red)
    }
}
