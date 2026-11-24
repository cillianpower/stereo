import SwiftUI
import StereoSync

/// Settings section showing iCloud sync of favourites, custom stations and settings.
struct CloudSyncSection: View {
    @Environment(AppModel.self) private var app
    @State private var syncing = false

    var body: some View {
        let status = app.cloudSyncStatus
        Section {
            HStack(spacing: 12) {
                Image(systemName: symbol(for: status))
                    .foregroundStyle(color(for: status))
                    .symbolEffect(.pulse, isActive: status == .syncing)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud")
                    Text(status.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if status.isUsable {
                    Button {
                        syncing = true
                        Task { await app.syncAppStateNow(); syncing = false }
                    } label: {
                        if syncing { ProgressView().controlSize(.small) } else { Text("Sync Now") }
                    }
                    .disabled(syncing)
                }
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Radio favourites, your own stations, recently played stations, identified songs and playback settings sync through your private iCloud. Music state (favourites, playlists, play counts) lives on your server.")
        }
    }

    private func symbol(for status: SyncStatus) -> String {
        switch status {
        case .upToDate: "checkmark.icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .failed: "exclamationmark.icloud"
        case .noAccount, .unavailable, .notStarted: "icloud.slash"
        }
    }

    private func color(for status: SyncStatus) -> Color {
        switch status {
        case .upToDate, .syncing: .accentColor
        case .failed: .orange
        default: .secondary
        }
    }
}
