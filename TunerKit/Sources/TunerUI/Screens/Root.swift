import SwiftUI
import TunerModel
import TunerPlayback

/// Top level: sign-in, or the app shell. One `TabView` gives a tab bar on iPhone and a
/// sidebar on iPad and Mac (`.sidebarAdaptable`).
public struct RootView: View {
    @Environment(AppModel.self) private var app

    public init() {}

    public var body: some View {
        switch app.phase {
        case .launching: ProgressView().task { await app.start() }
        case .signedOut: SignInView()
        case .ready:
            #if os(macOS)
            MacShell()
            #else
            AppShell()
            #endif
        }
    }
}

#if !os(macOS)
struct AppShell: View {
    @Environment(AppModel.self) private var app
    @State private var tab: TabID = .home
    @State private var showNowPlaying = false
    @State private var paths: [TabID: NavigationPath] = [:]

    enum TabID: Hashable { case home, library, radio, search, settings }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: .home) { stack(.home) { HomeView() } }
            Tab("Radio", systemImage: "dot.radiowaves.left.and.right", value: .radio) { stack(.radio) { RadioView() } }
            Tab("Library", systemImage: "square.stack.fill", value: .library) { stack(.library) { LibraryView() } }
            Tab(value: .search, role: .search) { stack(.search) { SearchView() } }
        }
        .tabViewStyle(.sidebarAdaptable)
        .onChange(of: app.pendingDestination, initial: true) { _, destination in
            guard let destination else { return }
            showNowPlaying = false
            switch destination {
            case .library(let route):
                var path = NavigationPath()
                path.append(route)
                paths[.library] = path
                tab = .library
            case .radio:
                tab = .radio
            }
            app.pendingDestination = nil
        }
        #if os(iOS)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            if app.remote.isControllingRemote { RemoteMiniPlayer(showNowPlaying: $showNowPlaying) }
            else { MiniPlayer(showNowPlaying: $showNowPlaying) }
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            if app.remote.isControllingRemote { RemoteNowPlayingView() } else { NowPlayingView() }
        }
        #endif
    }

    private func stack<Content: View>(_ id: TabID, @ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack(path: Binding(get: { paths[id] ?? NavigationPath() }, set: { paths[id] = $0 })) {
            content()
                .tunerDestinations()
                #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink { SettingsView() } label: { Image(systemName: "person.crop.circle") }
                    }
                }
                #endif
        }
    }
}
#endif

// MARK: Sign in

struct SignInView: View {
    @Environment(AppModel.self) private var app
    @State private var name = "Home"
    @State private var primaryURL = Self.defaultServerURL
    @State private var fallbackURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    /// Debug builds can prefill this from the gitignored Config/Local.xcconfig.
    private static var defaultServerURL: String {
        #if DEBUG
        Bundle.main.object(forInfoDictionaryKey: "TunerDevServerURL") as? String ?? ""
        #else
        ""
        #endif
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(.tint)
                        Text("Tuner").font(.largeTitle.bold())
                        Text("Connect to your Navidrome or OpenSubsonic server.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                }
                .listRowBackground(Color.clear)

                Section {
                    TextField("Server URL", text: $primaryURL, prompt: Text("http://192.168.1.10:4533"))
                        .urlField()
                    TextField("Remote URL (optional)", text: $fallbackURL, prompt: Text("https://music.example.com"))
                        .urlField()
                } header: { Text("Server") } footer: {
                    Text("Tuner tries these in order and switches automatically, e.g. your LAN address at home and a Tailscale or public address away.")
                }
                Section("Account") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Password", text: $password).textContentType(.password)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button { signIn() } label: {
                        HStack { Spacer(); if working { ProgressView() } else { Text("Sign In").bold() }; Spacer() }
                    }
                    .disabled(working || urls.isEmpty || username.isEmpty || password.isEmpty)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 560)
        }
    }

    private var urls: [URL] {
        [primaryURL, fallbackURL].compactMap { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            let withScheme = t.contains("://") ? t : "http://\(t)"
            guard let url = URL(string: withScheme), url.host() != nil else { return nil }
            return url
        }
    }

    private func signIn() {
        working = true
        error = nil
        Task {
            do {
                try await app.signIn(name: name, urls: urls, username: username, password: password)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

private extension View {
    func urlField() -> some View {
        self
            .textContentType(.URL)
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            #endif
    }
}

// MARK: Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var counts: (albums: Int, tracks: Int, artists: Int) = (0, 0, 0)

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("Server") {
                LabeledContent("Server", value: app.server?.name ?? "")
                ForEach(app.server?.urls ?? [], id: \.self) { url in
                    LabeledContent("Address", value: url.absoluteString)
                }
                LabeledContent("User", value: app.server?.username ?? "")
                LabeledContent("Library", value: "\(counts.albums) albums · \(counts.tracks) songs")
                Button("Sync Now") { Task { await app.sync(); refreshCounts() } }
                Button("Rebuild Library Index") { Task { await app.sync(full: true); refreshCounts() } }
                if let error = app.syncError { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section {
                Picker("Wi-Fi", selection: $settings.wifiQuality) {
                    ForEach(AppSettings.QualityOption.allCases) { Text($0.label).tag($0) }
                }
                Picker("Cellular", selection: $settings.cellularQuality) {
                    ForEach(AppSettings.QualityOption.allCases) { Text($0.label).tag($0) }
                }
            } header: { Text("Streaming Quality") } footer: {
                Text("\(app.isOnExpensiveNetwork ? "Currently using the cellular setting." : "Currently using the Wi-Fi setting.") Gapless playback is guaranteed for originals; some transcodes add tiny gaps.")
            }
            #if os(macOS)
            Section("Appearance") {
                LabeledContent("Accent Color") {
                    HStack(spacing: 7) {
                        ForEach(AppSettings.AccentOption.allCases) { option in
                            Button { settings.accent = option } label: {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 16, height: 16)
                                    .overlay { if settings.accent == option { Circle().fill(.white).frame(width: 6, height: 6) } }
                                    .overlay { if option == .system { Circle().strokeBorder(.primary.opacity(0.4), lineWidth: 1) } }
                            }
                            .buttonStyle(.plain)
                            .help(option.label)
                            .accessibilityLabel(option.label)
                            .accessibilityAddTraits(settings.accent == option ? .isSelected : [])
                        }
                    }
                }
            }
            #endif
            Section("Sound") {
                Picker("Sound Check (ReplayGain)", selection: $settings.replayGainMode) {
                    Text("Off").tag(ReplayGainMode.off)
                    Text("Automatic").tag(ReplayGainMode.auto)
                    Text("Track").tag(ReplayGainMode.track)
                    Text("Album").tag(ReplayGainMode.album)
                }
                LabeledContent("Preamp") {
                    Stepper("\(settings.replayGainPreamp, specifier: "%+.0f") dB", value: $settings.replayGainPreamp, in: -6...12)
                }
            }
            DiscoverySettingsSection()
            CloudSyncSection()
            Section("Storage") {
                Stepper("Cache limit: \(settings.cacheLimitGB) GB", value: $settings.cacheLimitGB, in: 1...100)
            }
            DownloadsSettingsSection()
            Section {
                Button("Sign Out", role: .destructive) { app.signOut() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onChange(of: settings.wifiQuality) { app.applyPlaybackSettings() }
        .onChange(of: settings.cellularQuality) { app.applyPlaybackSettings() }
        .onChange(of: settings.replayGainMode) { app.applyPlaybackSettings() }
        .onChange(of: settings.replayGainPreamp) { app.applyPlaybackSettings() }
        .onAppear { refreshCounts() }
    }

    private func refreshCounts() {
        if let c = try? app.store.counts() { counts = c }
    }
}

// MARK: Mac menu bar

/// Compact player for the Mac menu bar extra.
public struct MenuBarPlayer: View {
    @Environment(AppModel.self) private var app
    public init() {}

    public var body: some View {
        let player = app.player
        VStack(spacing: 12) {
            NowPlayingArtwork(cornerRadius: 8).frame(width: 220, height: 220)
            VStack(spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 28) {
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title)
                }
                Button { player.next() } label: { Image(systemName: "forward.fill") }
            }
            .buttonStyle(.plain)
            .font(.title3)
            .disabled(player.nowPlaying == nil)
        }
        .padding(16)
        .frame(width: 252)
    }

    private var title: String {
        if case .station = app.player.nowPlaying { return app.player.streamTitle?.title ?? app.player.nowPlaying?.title ?? "" }
        return app.player.nowPlaying?.title ?? "Not Playing"
    }

    private var subtitle: String {
        if case .station(let s) = app.player.nowPlaying { return [app.player.streamTitle?.artist, s.name].compactMap { $0 }.joined(separator: " — ") }
        return app.player.nowPlaying?.subtitle ?? ""
    }
}

// MARK: Keyboard shortcuts

#if os(macOS)
/// Mac menu commands. Space is handled in `MacShell` so it still types in text fields.
public struct PlaybackCommands: Commands {
    let app: AppModel
    public init(app: AppModel) { self.app = app }

    public var body: some Commands {
        SidebarCommands()
        CommandGroup(before: .sidebar) {
            Button("Search") { app.shell.focusSearch() }.keyboardShortcut("f", modifiers: .command)
            Button("Now Playing") { app.shell.toggleNowPlaying() }.keyboardShortcut("p", modifiers: [.command, .option])
            Button("Lyrics") { app.shell.toggle(.lyrics) }.keyboardShortcut("l", modifiers: .command)
            Button("Queue") { app.shell.toggle(.queue) }.keyboardShortcut("u", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Controls") {
            Button(app.player.isPlaying ? "Pause" : "Play") { app.toggleTransport() }
            Button("Next") { app.player.next() }.keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous") { app.player.previous() }.keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button("Increase Volume") { app.adjustVolume(by: 0.1) }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("Decrease Volume") { app.adjustVolume(by: -0.1) }.keyboardShortcut(.downArrow, modifiers: .command)
            Divider()
            Button("Shuffle") { app.player.setShuffle(!app.player.queue.isShuffled) }
            Button("Repeat") { app.player.cycleRepeat() }.keyboardShortcut("r", modifiers: .command)
        }
    }
}
#endif
