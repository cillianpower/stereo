import SwiftUI
import StereoWidgetData
import WidgetKit

@main
struct StereoWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        RecentAlbumsWidget()
        StationsWidget()
    }
}

// MARK: Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let store: WidgetSnapshotStore?
}

/// Every widget reads the same snapshot. The app reloads timelines when it changes, so each
/// timeline is one entry that never expires on its own.
struct SnapshotProvider: TimelineProvider {
    private let store = WidgetSnapshotStore.appGroup()

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .placeholder, store: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snapshot = store?.read() ?? .empty
        // The gallery shows sample content until there's something real to show.
        let shown = context.isPreview && snapshot == .empty ? .placeholder : snapshot
        completion(SnapshotEntry(date: .now, snapshot: shown, store: store))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: .now, snapshot: store?.read() ?? .empty, store: store)
        // If the app is gone by the time the song ends, refresh once so the widget isn't stuck mid-song.
        let policy: TimelineReloadPolicy = entry.snapshot.nowPlaying?.progressInterval
            .map { .after($0.upperBound.addingTimeInterval(5)) } ?? .never
        completion(Timeline(entries: [entry], policy: policy))
    }
}

extension WidgetSnapshot {
    static let placeholder = WidgetSnapshot(
        nowPlaying: .init(kind: .track, title: "Song Title", subtitle: "Artist", artwork: nil, isPlaying: true,
                          elapsed: 60, duration: 200, capturedAt: .now),
        recentAlbums: (1...12).map { .init(id: "\($0)", title: "Album", subtitle: "Artist", artwork: nil) },
        stations: (1...12).map { .init(id: "\($0)", title: "Station", subtitle: nil, artwork: nil) })
}

// MARK: Shared views

/// A saved thumbnail, or a neutral tile with a symbol while it's missing.
struct ArtworkImage: View {
    let name: String?
    let store: WidgetSnapshotStore?
    var maxPixel = 400
    var symbol = "music.note"

    /// Always square: a clear square sized by the layout, with the art filled and clipped inside,
    /// so artwork never stretches its container.
    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let name, let image = store?.loadArtwork(name, maxPixel: maxPixel) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .widgetAccentedRenderingMode(.accentedDesaturated)
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.fill.tertiary)
                        .overlay {
                            Image(systemName: symbol)
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .clipped()
    }
}

/// Apple Music–style backdrop: the artwork blurred and darkened behind the content.
struct ArtworkBackdrop: View {
    let name: String?
    let store: WidgetSnapshotStore?

    var body: some View {
        if let name, let image = store?.loadArtwork(name, maxPixel: 120) {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: 30, opaque: true)
                .overlay(Color.black.opacity(0.35))
        } else {
            Color(white: 0.16)
        }
    }
}

struct WidgetHeader: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}
