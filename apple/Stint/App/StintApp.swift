import SwiftUI

@main
struct StintApp: App {
    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            RaceView()
                .frame(minWidth: 760, minHeight: 540)
            #else
            RaceView()
            #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        #endif
    }
}
