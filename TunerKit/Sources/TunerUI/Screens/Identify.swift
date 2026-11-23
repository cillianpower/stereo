import SwiftUI
import TunerModel
import TunerRadio
import TunerStore

/// "What's this song?" — a button for Now Playing that shows the match inline.
struct IdentifyButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            Task { await app.identifyCurrentSong() }
        } label: {
            Group {
                if app.identification == .listening {
                    Image(systemName: "shazam.logo.fill").symbolEffect(.pulse, isActive: true)
                } else {
                    Image(systemName: "shazam.logo")
                }
            }
            .font(.title3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Identify Song")
        .disabled(app.player.nowPlaying == nil)
    }
}

/// Result card shown under the Now Playing titles after an identification.
struct IdentificationBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.identification {
        case .found(let match, let local):
            HStack(spacing: 12) {
                ArtworkView(.url(match.artworkURL, key: "shazam:\(match.artworkURL?.absoluteString ?? match.title)"), cornerRadius: 6, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.title).font(.subheadline.bold()).lineLimit(1)
                    Text(match.artist ?? "").font(.caption).opacity(0.7).lineLimit(1)
                }
                Spacer()
                if let local {
                    Button("Play from Library") { app.player.play([local], from: .search); app.clearIdentification() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                } else if let url = match.appleMusicURL {
                    Link(destination: url) { Image(systemName: "arrow.up.forward.app") }
                }
                Button { app.clearIdentification() } label: { Image(systemName: "xmark.circle.fill").opacity(0.6) }
                    .buttonStyle(.plain)
            }
            .padding(10)
            .background(.white.opacity(0.12), in: .rect(cornerRadius: 12))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        case .notFound:
            Text("Couldn't identify this song.").font(.caption).opacity(0.7)
                .task { try? await Task.sleep(for: .seconds(3)); app.clearIdentification() }
        case .failed(let message):
            Text(message).font(.caption).opacity(0.7)
                .task { try? await Task.sleep(for: .seconds(4)); app.clearIdentification() }
        case .idle, .listening:
            EmptyView()
        }
    }
}

/// Songs identified while listening to radio. Kept in Tuner only: nothing is added to the Shazam app.
struct IdentifiedSongsView: View {
    @Environment(AppModel.self) private var app
    @State private var songs: [IdentifiedSong] = []

    var body: some View {
        List(songs) { song in
            HStack(spacing: 12) {
                ArtworkView(.url(song.artworkURL, key: "shazam:\(song.artworkURL?.absoluteString ?? song.title)"), cornerRadius: 6, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).lineLimit(1)
                    Text([song.artist, song.stationName].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(song.identifiedAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                if let raw = song.libraryTrackID, let id = ItemID(string: raw), let track = try? app.store.tracks(ids: [id]).first {
                    Button { app.player.play([track], from: .search) } label: { Image(systemName: "play.circle.fill").font(.title2) }
                        .buttonStyle(.plain)
                }
            }
        }
        .overlay { if songs.isEmpty { ContentUnavailableView("Nothing Heard Yet", systemImage: "waveform", description: Text("Songs you identify while listening to radio are saved here, in Tuner.")) } }
        .navigationTitle("Heard on Radio")
        .pageTopFade()
        .task(id: app.identification) { songs = (try? app.store.identifiedSongs()) ?? [] }
    }
}
