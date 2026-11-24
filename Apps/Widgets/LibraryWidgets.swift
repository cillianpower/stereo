import AppIntents
import SwiftUI
import StereoWidgetData
import WidgetKit

struct RecentAlbumsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.recentAlbums, provider: SnapshotProvider()) { entry in
            TileGrid(title: "Recently Played", symbol: "clock.arrow.circlepath",
                     tiles: entry.snapshot.recentAlbums, store: entry.store,
                     emptyMessage: "Albums you play will appear here.", tileSymbol: "music.note") { tile in
                WidgetPlayAlbumIntent(albumID: tile.id)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Recently Played")
        .description("Play an album you listened to recently.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct StationsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.stations, provider: SnapshotProvider()) { entry in
            TileGrid(title: "Your Stations", symbol: "dot.radiowaves.left.and.right",
                     tiles: entry.snapshot.stations, store: entry.store,
                     emptyMessage: "Favourite a station to see it here.", tileSymbol: "dot.radiowaves.left.and.right") { tile in
                WidgetPlayStationIntent(stationID: tile.id)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Your Stations")
        .description("Start a favourite radio station without opening Stereo.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// A grid of artwork tiles; tapping one plays it in the background.
struct TileGrid<Intent: AppIntent>: View {
    let title: String
    let symbol: String
    let tiles: [WidgetSnapshot.Tile]
    let store: WidgetSnapshotStore?
    let emptyMessage: String
    let tileSymbol: String
    let intent: (WidgetSnapshot.Tile) -> Intent

    @Environment(\.widgetFamily) private var family

    /// Columns and rows per size. Small has no room for captions, and large only for titles.
    private var layout: (columns: Int, rows: Int, captions: Bool, subtitles: Bool) {
        switch family {
        case .systemSmall: (2, 2, false, false)
        case .systemLarge: (4, 3, true, false)
        default: (4, 1, true, true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if family != .systemSmall {
                WidgetHeader(title: title, symbol: symbol)
            }
            if tiles.isEmpty {
                Spacer()
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                grid
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var grid: some View {
        let shown = Array(tiles.prefix(layout.columns * layout.rows))
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: layout.columns)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(shown) { tile in
                Button(intent: intent(tile)) {
                    VStack(alignment: .leading, spacing: 3) {
                        ArtworkImage(name: tile.artwork, store: store, maxPixel: 240, symbol: tileSymbol)
                            .clipShape(.rect(cornerRadius: 6))
                        if layout.captions {
                            Text(tile.title)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                            if layout.subtitles, let subtitle = tile.subtitle {
                                Text(subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tile.subtitle.map { "\(tile.title), \($0)" } ?? tile.title)
            }
        }
    }
}
