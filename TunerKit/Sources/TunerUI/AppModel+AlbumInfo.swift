import Foundation
import TunerModel
import TunerStore

extension AppModel {
    private struct CachedAlbumInfo: Codable {
        var info: AlbumInfo
        var fetchedAt: Date
    }

    private static func albumInfoKey(_ id: ItemID) -> String { "albumInfo.v1.\(id)" }

    /// Album details: cached locally so pages open instantly and work offline. Albums without
    /// notes are rechecked sooner, in case the server gains a metadata agent.
    public func albumInfo(_ id: ItemID) async -> AlbumInfo? {
        let key = Self.albumInfoKey(id)
        let cached = (try? store.syncValue(key))
            .flatMap { $0 }
            .flatMap { try? JSONDecoder().decode(CachedAlbumInfo.self, from: Data($0.utf8)) }
        if let cached {
            let lifetime: TimeInterval = cached.info.notes == nil ? 86_400 : 30 * 86_400
            if Date().timeIntervalSince(cached.fetchedAt) < lifetime { return cached.info }
        }
        guard let library, let fresh = try? await library.albumInfo(id) else { return cached?.info }
        cacheAlbumInfo(fresh, for: id)
        return fresh
    }

    private struct CachedArtistInfo: Codable {
        var info: ArtistInfo
        var fetchedAt: Date
    }

    /// The artist's biography, cached the same way as album details.
    public func artistInfo(_ id: ItemID) async -> ArtistInfo? {
        let key = "artistInfo.v1.\(id)"
        let cached = (try? store.syncValue(key))
            .flatMap { $0 }
            .flatMap { try? JSONDecoder().decode(CachedArtistInfo.self, from: Data($0.utf8)) }
        if let cached {
            let lifetime: TimeInterval = cached.info.biography == nil ? 86_400 : 30 * 86_400
            if Date().timeIntervalSince(cached.fetchedAt) < lifetime { return cached.info }
        }
        guard let library, let fresh = try? await library.artistInfo(id) else { return cached?.info }
        if let data = try? JSONEncoder().encode(CachedArtistInfo(info: fresh, fetchedAt: Date())) {
            try? store.setSyncValue(String(decoding: data, as: UTF8.self), for: key)
        }
        return fresh
    }

    func cacheAlbumInfo(_ info: AlbumInfo, for id: ItemID) {
        guard let data = try? JSONEncoder().encode(CachedAlbumInfo(info: info, fetchedAt: Date())) else { return }
        try? store.setSyncValue(String(decoding: data, as: UTF8.self), for: Self.albumInfoKey(id))
    }
}
