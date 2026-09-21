import SwiftUI

struct WelcomeHeroView: View {
    let onLogin: () -> Void
    let onSkip: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            StintPalette.trackBlack.opacity(0.72)
                .ignoresSafeArea()
            VStack(spacing: 24) {
                HStack(spacing: 10) {
                    Capsule().fill(StintPalette.red).frame(width: 22, height: 5)
                    Text("STINT")
                        .font(.system(size: 13, weight: .bold, design: .rounded)).tracking(2.4)
                }
                VStack(spacing: 10) {
                    Text("Every lap. Live or replayed.")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                    Text("Log in with your F1 account to stream live sessions, or skip and explore historical race replays from OpenF1.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                HStack(spacing: 12) {
                    Button(action: onSkip) {
                        Text("Watch historical data")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .background(Color.primary.opacity(0.1), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .accessibilityIdentifier("welcome-skip")
                    Button {
                        openURL(F1Account.loginURL)
                        onLogin()
                    } label: {
                        Label("Log in with F1 account", systemImage: "play.tv")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(StintPalette.white)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .background(StintPalette.red, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .accessibilityIdentifier("welcome-login")
                }
            }
            .padding(36)
            .glassPanel()
            .padding(24)
            .accessibilityIdentifier("welcome-hero")
        }
        .preferredColorScheme(.dark)
        .buttonStyle(.plain)
    }
}
