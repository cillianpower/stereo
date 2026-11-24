import SwiftUI
import StereoModel
import StereoStore

// MARK: Button

/// Download toggle for an album or playlist header/toolbar: arrow → progress ring → checkmark.
/// Tapping a pinned item offers to remove the download (and retry failures).
struct DownloadButton: View {
    @Environment(AppModel.self) private var app
    let owner: PinOwner
    @State private var progress: PinProgress?
    @State private var confirming = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Button {
            if progress == nil { pin() } else { confirming = true }
        } label: {
            icon
                .frame(width: Metrics.actionIcon, height: Metrics.actionIcon)
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(accessibilityLabel)
        .disabled(working)
        .confirmationDialog("Downloaded", isPresented: $confirming, titleVisibility: .hidden) {
            if let progress, progress.failed > 0 {
                Button("Retry \(progress.failed) Failed") { Task { await app.retryFailedDownloads() } }
            }
            Button("Remove Download", role: .destructive) { Task { await app.removeDownload(owner) } }
        }
        .alert("Couldn't Download", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .task(id: owner) {
            for await value in app.store.observePinProgress(owner) {
                withAnimation(.snappy) { progress = value }
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if working {
            ProgressView().controlSize(.small)
        } else if let progress {
            if progress.isComplete {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            } else if progress.failed > 0, progress.downloading == 0, progress.done + progress.failed == progress.total {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            } else {
                ProgressRing(fraction: progress.fraction)
            }
        } else {
            Image(systemName: "arrow.down.circle")
        }
    }

    private var accessibilityLabel: String {
        guard let progress else { return "Download" }
        if progress.isComplete { return "Downloaded" }
        return "Downloading, \(progress.done) of \(progress.total)"
    }

    private func pin() {
        working = true
        Task {
            do { try await app.download(owner) } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

/// Small determinate ring with a stop square, like the App Store's download indicator.
struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.03, fraction))
                .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            RoundedRectangle(cornerRadius: 1.5).fill(.tint).frame(width: 7, height: 7)
        }
        .padding(2)
    }
}

// MARK: Downloaded list

/// Library → Downloaded: everything pinned, playable without a network.
struct DownloadedView: View {
    @Environment(AppModel.self) private var app
    @State private var pins: [Pin] = []
    @State private var stats: LibraryStore.DownloadStats?

    var body: some View {
        List {
            if let stats, stats.files > 0 || stats.pending > 0 {
                Section {
                    LabeledContent("Storage Used", value: ByteCountFormatter.string(fromByteCount: stats.bytes, countStyle: .file))
                    if stats.pending > 0 { LabeledContent("Downloading", value: "\(stats.pending) songs") }
                    if stats.failed > 0 {
                        Button("Retry \(stats.failed) Failed") { Task { await app.retryFailedDownloads() } }
                    }
                }
            }
            Section {
                ForEach(pins) { pin in
                    PinRow(pin: pin)
                        .swipeActions {
                            Button(role: .destructive) { Task { await app.removeDownload(pin.owner) } } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button { app.playDownloaded(pin) } label: { Label("Play", systemImage: "play") }
                            Button { app.playDownloaded(pin, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                            Divider()
                            Button(role: .destructive) { Task { await app.removeDownload(pin.owner) } } label: {
                                Label("Remove Download", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .overlay {
            if pins.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                       description: Text("Tap the download button on an album or playlist to keep it on this device."))
            }
        }
        .navigationTitle("Downloaded")
        #if os(macOS)
        .pageHeader("Downloaded") {
            if !pins.isEmpty {
                Button { playAll() } label: { Label("Shuffle All", systemImage: "shuffle") }.buttonStyle(.glass)
            }
        }
        #else
        .toolbar {
            if !pins.isEmpty {
                Button { playAll() } label: { Label("Shuffle All", systemImage: "shuffle") }
            }
        }
        #endif
        .task { for await value in app.store.observePins() { pins = value } }
        .task { for await value in app.store.observeDownloadStats() { stats = value } }
    }

    private func playAll() {
        let ids = pins.flatMap { (try? app.store.pinnedTrackIDs($0.owner)) ?? [] }
        let unique = Array(NSOrderedSet(array: ids)) as? [ItemID] ?? ids
        let tracks = (try? app.store.tracks(ids: unique)) ?? []
        app.player.play(tracks, from: .songs, shuffled: true)
    }
}

private struct PinRow: View {
    @Environment(AppModel.self) private var app
    let pin: Pin
    @State private var progress: PinProgress?

    var body: some View {
        Group {
            switch pin.owner {
            case .album(let id): NavigationLink(value: Route.album(id)) { content }
            case .playlist(let id): NavigationLink(value: Route.playlist(id)) { content }
            case .track: Button { app.playDownloaded(pin) } label: { content }.buttonStyle(.plain)
            }
        }
        .task(id: pin.id) {
            for await value in app.store.observePinProgress(pin.owner) { progress = value }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            ArtworkView(.coverArt(pin.coverArtID), cornerRadius: 6, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(pin.name).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let progress, !progress.isComplete {
                if progress.failed > 0, progress.downloading == 0 {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                } else {
                    ProgressRing(fraction: progress.fraction).frame(width: 22, height: 22)
                }
            }
        }
        .contentShape(.rect)
    }

    private var status: String {
        var parts: [String] = []
        if let subtitle = pin.subtitle { parts.append(subtitle) }
        if let progress {
            if progress.isComplete {
                parts.append(ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file))
            } else {
                parts.append("\(progress.done) of \(progress.total)")
            }
        }
        if pin.quality != "original" { parts.append(pin.quality.replacingOccurrences(of: "@", with: " ").uppercased() + "k") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Settings

/// Settings → Downloads: quality for new downloads, space used, retry and remove-all.
struct DownloadsSettingsSection: View {
    @Environment(AppModel.self) private var app
    @AppStorage(AppModel.downloadQualityKey) private var quality: AppSettings.QualityOption = .original
    @State private var stats: LibraryStore.DownloadStats?
    @State private var confirmingRemoveAll = false

    var body: some View {
        Section {
            Picker("Download Quality", selection: $quality) {
                ForEach(AppSettings.QualityOption.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent("Downloaded",
                           value: "\(stats?.files ?? 0) songs · \(ByteCountFormatter.string(fromByteCount: stats?.bytes ?? 0, countStyle: .file))")
            if let stats, stats.pending > 0 {
                LabeledContent("In Progress", value: "\(stats.pending) songs")
            }
            if let stats, stats.failed > 0 {
                Button("Retry \(stats.failed) Failed Downloads") { Task { await app.retryFailedDownloads() } }
            }
            Button("Remove All Downloads", role: .destructive) { confirmingRemoveAll = true }
                .disabled((stats?.files ?? 0) == 0 && (stats?.pending ?? 0) == 0)
                .confirmationDialog("Remove all downloaded music from this device?", isPresented: $confirmingRemoveAll,
                                    titleVisibility: .visible) {
                    Button("Remove All Downloads", role: .destructive) { Task { await app.removeAllDownloads() } }
                }
        } header: {
            Text("Downloads")
        } footer: {
            Text("Applies to new downloads. Downloaded music plays without a network and is never removed by the cache limit.")
        }
        .task { for await value in app.store.observeDownloadStats() { stats = value } }
    }
}
