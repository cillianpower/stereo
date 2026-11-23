import SwiftUI
import TunerUI

@main
struct TunerApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var app: AppModel

    init() {
        let model = AppModel()
        _app = State(initialValue: model)
        AppIntentsSetup.configure(model)
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            RootView().environment(app)
        }
        .defaultSize(width: 1120, height: 720)
        .windowStyle(.hiddenTitleBar)
        .commands { PlaybackCommands(app: app) }

        // Albums, artists and playlists opened in their own windows.
        WindowGroup("Library", id: "detail", for: Route.self) { $route in
            if let route { MacDetailWindow(route: route).environment(app) }
        }
        .defaultSize(width: 720, height: 560)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))

        Settings {
            MacSettingsView().environment(app)
        }

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
