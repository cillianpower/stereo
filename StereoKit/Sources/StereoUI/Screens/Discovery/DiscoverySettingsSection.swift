import SwiftUI

/// Settings: ListenBrainz account and autoplay.
struct DiscoverySettingsSection: View {
    @Environment(AppModel.self) private var app
    @State private var token = ""
    @State private var working = false

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            Toggle("Autoplay When Queue Ends", isOn: $settings.autoplayEnabled)
        } footer: {
            Text("Keeps playing similar music from your library: Navidrome's similar songs first, then ListenBrainz similar artists.")
        }

        Section {
            switch app.discovery?.listenBrainzStatus ?? .notConnected {
            case .connected(let user):
                LabeledContent("Account", value: user)
                Button("Disconnect ListenBrainz", role: .destructive) { app.discovery?.disconnectListenBrainz() }
            case .notConnected, .failed:
                SecureField("User token", text: $token)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button {
                    working = true
                    Task {
                        await app.discovery?.connectListenBrainz(token: token)
                        if case .connected = app.discovery?.listenBrainzStatus { token = "" }
                        working = false
                    }
                } label: {
                    if working { ProgressView() } else { Text("Connect") }
                }
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || working || app.discovery == nil)
                if case .failed(let message) = app.discovery?.listenBrainzStatus {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            Text("ListenBrainz")
        } footer: {
            Text("Used for recommendations only; plays are scrobbled by your server. Find your token at [listenbrainz.org/settings](https://listenbrainz.org/settings/).")
        }
    }
}
