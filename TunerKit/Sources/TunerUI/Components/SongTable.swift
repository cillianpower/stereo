#if os(macOS)
import SwiftUI
import TunerModel

extension Track {
    var sortTrackNumber: Int { (discNumber ?? 1) * 1000 + (trackNumber ?? 0) }
    var sortArtist: String { artist ?? "" }
    var sortAlbum: String { album ?? "" }
    var sortDuration: Int { Int(duration?.components.seconds ?? 0) }
    var sortFormat: String { Format.formatDetail(format) }
}

/// Music.app-style song list for the Mac: sortable columns, multi-select, double-click to play,
/// the usual context menu, and drag to queue.
struct SongTable: View {
    @Environment(AppModel.self) private var app
    let tracks: [Track]
    var showNumber = false
    var showAlbum = true
    /// Plays `tracks` (in the table's current order) starting at `index`.
    let play: (_ tracks: [Track], _ index: Int) -> Void

    @State private var sortOrder: [KeyPathComparator<Track>] = []
    @State private var selection: Set<Track.ID> = []

    private var sorted: [Track] { sortOrder.isEmpty ? tracks : tracks.sorted(using: sortOrder) }

    private var currentID: ItemID? {
        if case .track(let t) = app.player.nowPlaying { return t.id }
        return nil
    }

    var body: some View {
        let rows = sorted
        Table(of: Track.self, selection: $selection, sortOrder: $sortOrder) {
            if showNumber {
                TableColumn("#", value: \.sortTrackNumber) { track in
                    if track.id == currentID {
                        PlayingBars(isPlaying: app.player.isPlaying)
                    } else {
                        Text(track.trackNumber.map(String.init) ?? "").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .width(32)
            }
            TableColumn("Title", value: \.title) { track in
                HStack(spacing: 6) {
                    Text(track.title)
                        .foregroundStyle(track.id == currentID ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    if track.starred != nil { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            TableColumn("Artist", value: \.sortArtist) { Text($0.artist ?? "").foregroundStyle(.secondary) }
            if showAlbum {
                TableColumn("Album", value: \.sortAlbum) { Text($0.album ?? "").foregroundStyle(.secondary) }
            }
            TableColumn("Format", value: \.sortFormat) { track in
                Text(Format.qualityBadge(track.format) ?? track.format.codec?.uppercased() ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(Format.formatDetail(track.format))
            }
            .width(min: 60, ideal: 90)
            TableColumn("Time", value: \.sortDuration) { Text(Format.duration($0.duration)).monospacedDigit().foregroundStyle(.secondary) }
                .width(56)
        } rows: {
            ForEach(rows) { track in
                TableRow(track).draggable(dragPayload(for: track, in: rows))
            }
        }
        .alternatingRowBackgrounds(.disabled)
        .controlSize(.small)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            let picked = rows.filter { ids.contains($0.id) }
            if picked.count == 1, let track = picked.first {
                TrackMenu(track: track)
            } else if !picked.isEmpty {
                Button("Play Next") { app.player.playNext(picked) }
                Button("Play Last") { app.player.addToQueue(picked) }
            }
        } primaryAction: { ids in
            guard let index = rows.firstIndex(where: { ids.contains($0.id) }) else { return }
            play(rows, index)
        }
        .onKeyPress(.return) {
            guard let index = rows.firstIndex(where: { selection.contains($0.id) }) else { return .ignored }
            play(rows, index)
            return .handled
        }
    }

    /// Dragging a selected row carries the whole selection, in table order.
    private func dragPayload(for track: Track, in rows: [Track]) -> String {
        let dragged = selection.contains(track.id) ? rows.filter { selection.contains($0.id) } : [track]
        return TrackDrag.payload(dragged)
    }
}

/// Tracks travel through drag and drop as newline-separated item IDs.
enum TrackDrag {
    static func payload(_ tracks: [Track]) -> String {
        tracks.map(\.id.description).joined(separator: "\n")
    }

    static func ids(in payloads: [String]) -> [ItemID] {
        payloads.flatMap { $0.split(separator: "\n") }.compactMap { ItemID(string: String($0)) }
    }
}
#endif
