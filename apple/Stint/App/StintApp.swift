import SwiftUI

@main
struct StintApp: App {
    @State private var launches = AppLaunchTracker()
    @State private var showWelcome = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some Scene {
        WindowGroup {
            ZStack {
                #if os(macOS)
                RaceView()
                    .frame(minWidth: 760, minHeight: 540)
                #else
                RaceView()
                #endif
                if showWelcome {
                    WelcomeHeroView(onLogin: dismissWelcome, onSkip: dismissWelcome)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: reduceMotion ? 0 : 0.3), value: showWelcome)
            .onAppear {
                launches.recordLaunch()
                showWelcome = launches.shouldShowOnboarding
            }
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        #endif
        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }

    private func dismissWelcome() {
        launches.completeOnboarding()
        showWelcome = false
    }
}
