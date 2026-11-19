import SwiftUI
import TunerUI

@main
struct TunerApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            RootView().environment(app)
        }
        .defaultSize(width: 1100, height: 760)
        .commands { PlaybackCommands(app: app) }

        MenuBarExtra("Tuner", systemImage: "dot.radiowaves.left.and.right") {
            MenuBarPlayer().environment(app)
        }
        .menuBarExtraStyle(.window)
        #else
        WindowGroup {
            RootView().environment(app)
        }
        #endif
    }
}
