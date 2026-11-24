import Foundation

/// What the widgets show. The app writes it to the App Group container, and the widget extension
/// only ever reads it.
///
/// Widgets deliberately don't open the library database: an iOS app that is suspended while
/// holding a SQLite lock in a shared container is killed (0xdead10cc). A small JSON file plus
/// pre-rendered thumbnails also keeps the extension free of GRDB, networking and credentials.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public var nowPlaying: NowPlaying?
    public var recentAlbums: [Tile]
    public var stations: [Tile]

    public init(nowPlaying: NowPlaying? = nil, recentAlbums: [Tile] = [], stations: [Tile] = []) {
        self.nowPlaying = nowPlaying
        self.recentAlbums = recentAlbums
        self.stations = stations
    }

    public static let empty = WidgetSnapshot()

    public struct NowPlaying: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case track, station }

        public var kind: Kind
        public var title: String
        public var subtitle: String?
        /// File name of the artwork in the snapshot's artwork folder.
        public var artwork: String?
        public var isPlaying: Bool
        /// Playback position at `capturedAt`; with `duration`, lets the widget draw a live progress bar.
        public var elapsed: TimeInterval
        public var duration: TimeInterval?
        public var capturedAt: Date

        public init(kind: Kind, title: String, subtitle: String?, artwork: String?, isPlaying: Bool,
                    elapsed: TimeInterval, duration: TimeInterval?, capturedAt: Date) {
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
            self.artwork = artwork
            self.isPlaying = isPlaying
            self.elapsed = elapsed
            self.duration = duration
            self.capturedAt = capturedAt
        }

        /// Skipping only makes sense inside a queue; stations are live.
        public var canSkip: Bool { kind == .track }

        /// The span the track covers in wall-clock time, when it's playing and the length is known.
        public var progressInterval: ClosedRange<Date>? {
            guard isPlaying, let duration, duration > 0 else { return nil }
            let start = capturedAt.addingTimeInterval(-elapsed)
            return start...start.addingTimeInterval(duration)
        }

        /// Equal ignoring the capture time and small position drift, so periodic position updates
        /// don't cost a widget reload.
        public func isSameDisplay(as other: NowPlaying) -> Bool {
            var a = self, b = other
            a.capturedAt = .distantPast; b.capturedAt = .distantPast
            a.elapsed = 0; b.elapsed = 0
            guard a == b else { return false }
            // While playing, compare the implied start time; a seek moves it.
            let startA = capturedAt.timeIntervalSince1970 - (isPlaying ? elapsed : 0)
            let startB = other.capturedAt.timeIntervalSince1970 - (other.isPlaying ? other.elapsed : 0)
            return isPlaying ? abs(startA - startB) < 2 : abs(elapsed - other.elapsed) < 2
        }
    }

    /// An album or station the widget can start with one tap.
    public struct Tile: Codable, Equatable, Hashable, Sendable, Identifiable {
        /// Album ID or station ID, passed back to the app's play intent.
        public var id: String
        public var title: String
        public var subtitle: String?
        public var artwork: String?

        public init(id: String, title: String, subtitle: String?, artwork: String?) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.artwork = artwork
        }
    }

    /// Every artwork file the snapshot refers to.
    public var artworkFiles: Set<String> {
        var files = Set((recentAlbums + stations).compactMap(\.artwork))
        if let art = nowPlaying?.artwork { files.insert(art) }
        return files
    }
}

/// Widget kinds, shared so the app can reload exactly the widgets whose content changed.
public enum WidgetKind {
    public static let nowPlaying = "NowPlaying"
    public static let recentAlbums = "RecentAlbums"
    public static let stations = "Stations"
}
