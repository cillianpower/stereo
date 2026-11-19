import Foundation
import TunerModel
import TunerRadio
import TunerStore

public enum IdentificationState: Equatable {
    case idle
    case listening
    case found(SongIdentifier.Match, inLibrary: Track?)
    case notFound
    case failed(String)
}

extension AppModel {
    /// Identifies what's playing (usually radio) and looks for it in your library.
    public func identifyCurrentSong() async {
        guard identification != .listening else { return }
        identification = .listening
        do {
            guard let match = try await songIdentifier.identify(from: player.audioTap) else {
                identification = .notFound
                return
            }
            let local = try? store.findTrack(artist: match.artist, title: match.title)
            var stationName: String?
            if case .station(let s) = player.nowPlaying { stationName = s.name }
            try? store.addIdentified(IdentifiedSong(title: match.title, artist: match.artist, artworkURL: match.artworkURL,
                                                    stationName: stationName, libraryTrackID: local?.id))
            identification = .found(match, inLibrary: local)
        } catch {
            identification = .failed(error.localizedDescription)
        }
    }

    public func clearIdentification() { identification = .idle }
}
