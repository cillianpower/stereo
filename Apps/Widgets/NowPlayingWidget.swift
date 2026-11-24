import AppIntents
import SwiftUI
import StereoWidgetData
import WidgetKit

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.nowPlaying, provider: SnapshotProvider()) { entry in
            NowPlayingView(entry: entry)
                .containerBackground(for: .widget) {
                    ArtworkBackdrop(name: entry.snapshot.nowPlaying?.artwork, store: entry.store)
                }
                .environment(\.colorScheme, .dark)
        }
        .configurationDisplayName("Now Playing")
        .description("The current song or station, with playback controls.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NowPlayingView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let item = entry.snapshot.nowPlaying {
            switch family {
            case .systemMedium: medium(item)
            default: small(item)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                WidgetHeader(title: "Stereo", symbol: "dot.radiowaves.left.and.right")
                Spacer()
                Text("Not Playing")
                    .font(.headline)
                Text("Open Stereo to play something.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func small(_ item: WidgetSnapshot.NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                artwork(item)
                    .frame(width: 64, height: 64)
                Spacer(minLength: 4)
                PlayPauseButton(isPlaying: item.isPlaying, size: 34)
            }
            Spacer(minLength: 6)
            titles(item, titleFont: .subheadline.weight(.semibold))
            progress(item)
                .padding(.top, 6)
        }
    }

    private func medium(_ item: WidgetSnapshot.NowPlaying) -> some View {
        // The art is square and as tall as the content area; the text column takes the rest.
        HStack(spacing: 14) {
            artwork(item)
            VStack(alignment: .leading, spacing: 0) {
                titles(item, titleFont: .headline)
                Spacer(minLength: 6)
                progress(item)
                    .padding(.bottom, 8)
                HStack(spacing: 0) {
                    if item.canSkip {
                        controlButton("backward.fill", intent: WidgetSkipIntent(forward: false))
                    }
                    Spacer(minLength: 0)
                    PlayPauseButton(isPlaying: item.isPlaying, size: 36)
                    Spacer(minLength: 0)
                    if item.canSkip {
                        controlButton("forward.fill", intent: WidgetSkipIntent(forward: true))
                    }
                }
            }
        }
    }

    private func artwork(_ item: WidgetSnapshot.NowPlaying) -> some View {
        ArtworkImage(name: item.artwork, store: entry.store,
                     symbol: item.kind == .station ? "dot.radiowaves.left.and.right" : "music.note")
            .clipShape(.rect(cornerRadius: 8))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }

    private func titles(_ item: WidgetSnapshot.NowPlaying, titleFont: Font) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.title)
                .font(titleFont)
                .lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func progress(_ item: WidgetSnapshot.NowPlaying) -> some View {
        if let interval = item.progressInterval {
            // Advances on its own, with no timeline reloads.
            ProgressView(timerInterval: interval, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .progressViewStyle(.linear)
                .tint(.primary)
                .labelsHidden()
        } else if let duration = item.duration, duration > 0 {
            ProgressView(value: min(item.elapsed, duration), total: duration)
                .progressViewStyle(.linear)
                .tint(.primary)
        } else if item.kind == .station {
            Label("Live", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func controlButton(_ symbol: String, intent: some AppIntent) -> some View {
        Button(intent: intent) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 36, height: 36)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

struct PlayPauseButton: View {
    let isPlaying: Bool
    let size: CGFloat

    var body: some View {
        Button(intent: WidgetTogglePlaybackIntent()) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.45, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .background(.fill.secondary, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}
