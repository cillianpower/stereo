import SwiftUI
import StereoModel

extension PlayableItem {
    var subtitle: String? {
        switch self {
        case .track(let t): [t.artist, t.album].compactMap { $0 }.joined(separator: " — ")
        case .station(let s): s.tags.prefix(3).joined(separator: ", ")
        }
    }
}

/// Artwork for whatever's playing: cover art, or the radio song's looked-up artwork, or the station logo.
struct NowPlayingArtwork: View {
    @Environment(AppModel.self) private var app
    var cornerRadius: CGFloat = 8

    var body: some View {
        switch app.player.nowPlaying {
        case .track(let t): ArtworkView(.coverArt(t.coverArtID), cornerRadius: cornerRadius)
        case .station(let s):
            if let art = app.radioEnrichment?.artworkURL {
                ArtworkView(.url(art, key: "itunes:\(art.absoluteString)"), cornerRadius: cornerRadius)
            } else {
                ArtworkView(.station(s), cornerRadius: cornerRadius)
            }
        case nil: ArtworkView(.coverArt(nil), cornerRadius: cornerRadius)
        }
    }
}

// MARK: Mini player

struct MiniPlayer: View {
    @Environment(AppModel.self) private var app
    @Binding var showNowPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textOffset: CGFloat = 0
    @State private var lift: CGFloat = 0
    @State private var dragAxis: Axis?

    private static let skipDistance: CGFloat = 150

    var body: some View {
        let player = app.player
        let isTrack = if case .track = player.nowPlaying { true } else { false }
        MiniPlayerPill(
            title: title,
            subtitle: subtitle,
            position: isTrack ? player.position : nil,
            duration: isTrack ? player.duration : nil,
            isPlaying: player.isPlaying,
            isLoading: player.status == .loading || player.status == .buffering,
            textOffset: textOffset,
            onToggle: { player.togglePlayPause() }
        )
        .offset(y: lift)
        .scaleEffect(1 + min(-lift, 12) / 400)
        .contentShape(.rect)
        .onTapGesture { showNowPlaying = true }
        .gesture(pillGesture)
    }

    /// The song follows a sideways swipe, and the pill's contents lift with an upward one.
    private var pillGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let move = value.translation
                let axis = dragAxis ?? (abs(move.width) > abs(move.height) ? .horizontal : .vertical)
                dragAxis = axis
                guard !reduceMotion else { return }
                if axis == .horizontal {
                    textOffset = move.width
                } else {
                    lift = max(min(move.height, 0) * 0.3, -12)
                }
            }
            .onEnded { value in
                let axis = dragAxis
                dragAxis = nil
                let move = value.translation
                if axis == .vertical, move.height < -30 {
                    showNowPlaying = true
                } else if axis == .horizontal, move.width < -50 {
                    skip(direction: -1) { app.player.next() }
                    return
                } else if axis == .horizontal, move.width > 50 {
                    skip(direction: 1) { app.player.previous() }
                    return
                }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.74)) {
                    textOffset = 0
                    lift = 0
                }
            }
    }

    /// The old song leaves in the swipe's direction and the new one arrives from the other side.
    private func skip(direction: CGFloat, action: @escaping () -> Void) {
        guard !reduceMotion else {
            textOffset = 0
            action()
            return
        }
        withAnimation(.easeIn(duration: 0.12)) {
            textOffset = direction * Self.skipDistance
        } completion: {
            action()
            textOffset = -direction * Self.skipDistance
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { textOffset = 0 }
        }
    }

    private var title: String {
        if case .station = app.player.nowPlaying, let t = app.player.streamTitle?.title { return t }
        return app.player.nowPlaying?.title ?? "Not Playing"
    }

    private var subtitle: String? {
        if case .station(let s) = app.player.nowPlaying {
            return [app.player.streamTitle?.artist, s.name].compactMap { $0 }.joined(separator: " — ")
        }
        return app.player.nowPlaying?.subtitle
    }
}

/// The contents of the iPhone's glass pill: song, artist, times, play/pause and a hairline.
struct MiniPlayerPill: View {
    let title: String
    let subtitle: String?
    let position: Double?
    let duration: Double?
    let isPlaying: Bool
    var isLoading = false
    /// How far a swipe has carried the song and artist.
    var textOffset: CGFloat = 0
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(x: textOffset)
            .opacity(1 - min(abs(textOffset) / 150, 1) * 0.85)
            .clipped()

            if let position, let duration, duration > 0 {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Format.duration(position))
                    Text("-" + Format.duration(max(0, duration - position)))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Format.duration(position)) of \(Format.duration(duration))")
            }

            Button(action: onToggle) {
                Group {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
        }
        .padding(.leading, 18)
        .padding(.trailing, 4)
        .overlay(alignment: .bottom) {
            if let position, let duration, duration > 0 {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.2))
                        Capsule().fill(.tint).frame(width: geometry.size.width * min(max(position / duration, 0), 1))
                    }
                }
                .frame(height: 2)
                .padding(.horizontal, 18)
                .padding(.bottom, 3)
                .accessibilityHidden(true)
            }
        }
    }
}

// MARK: Now Playing

struct NowPlayingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var panel: Panel = .artwork
    @State private var scrubbing: Double?
    @State private var artworkOffset: CGFloat = 0
    @State private var lyrics: Lyrics?
    /// Lyrics and the queue scroll, so a drag that starts inside them doesn't close the player.
    @State private var panelFrame = CGRect.zero
    /// The direction an artwork drag committed to, so one drag can't both skip and close.
    @State private var artworkAxis: Axis?

    enum Panel { case artwork, lyrics, queue }

    var body: some View {
        let player = app.player
        ZStack {
            background
            VStack(spacing: 20) {
                GrabBar { dismiss() }

                Group {
                    switch panel {
                    case .artwork: artwork
                    case .lyrics: LyricsView(lyrics: lyrics, position: player.position) { player.seek(to: $0) }
                    case .queue: QueueView()
                    }
                }
                .frame(maxHeight: .infinity)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { panelFrame = $0 }

                titles
                IdentificationBanner()
                    .animation(.snappy, value: app.identification)
                if case .track = player.nowPlaying { scrubber }
                transport
                bottomBar
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
            .frame(maxWidth: 560)
        }
        .foregroundStyle(.white)
        .tint(.white)
        .swipeDownToDismiss { start in
            scrubbing != nil || artworkAxis == .horizontal || (panel != .artwork && panelFrame.contains(start))
        }
        .task(id: trackID) { await loadLyrics() }
    }

    private var trackID: ItemID? {
        if case .track(let t) = app.player.nowPlaying { return t.id }
        return nil
    }

    private func loadLyrics() async {
        lyrics = nil
        guard case .track(let t) = app.player.nowPlaying, let lib = app.library else { return }
        lyrics = try? await lib.lyrics(for: t)
    }

    /// Blurred, saturated artwork filling the screen — the Apple Music look.
    private var background: some View {
        GeometryReader { geo in
            NowPlayingArtwork(cornerRadius: 0)
                .frame(width: geo.size.width * 1.6, height: geo.size.width * 1.6)
                .position(x: geo.size.width / 2, y: geo.size.height / 3)
                .blur(radius: 80)
                .saturation(1.6)
                .overlay(Color.black.opacity(0.35))
        }
        .ignoresSafeArea()
        .background(Color.black)
        .animation(.easeInOut(duration: 0.8), value: trackID)
    }

    /// Swipe the artwork left or right to skip, and it shrinks when paused, as in Apple Music.
    private var artwork: some View {
        NowPlayingArtwork(cornerRadius: 12)
            .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
            .scaleEffect(app.player.isPlaying ? 1 : 0.85)
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: app.player.isPlaying)
            .offset(x: artworkOffset)
            .gesture(DragGesture(minimumDistance: 10)
                .onChanged { value in
                    let move = value.translation
                    let axis = artworkAxis ?? (abs(move.width) > abs(move.height) ? .horizontal : .vertical)
                    artworkAxis = axis
                    // A drag that started downward belongs to closing the player.
                    if axis == .horizontal { artworkOffset = move.width * 0.6 }
                }
                .onEnded { value in
                    if artworkAxis == .horizontal {
                        if value.translation.width < -80 { app.player.next() }
                        else if value.translation.width > 80 { app.player.previous() }
                    }
                    artworkAxis = nil
                    withAnimation(.spring) { artworkOffset = 0 }
                })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var titles: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(primaryTitle).font(.title3.bold()).lineLimit(1)
                Text(secondaryTitle).font(.title3).opacity(0.7).lineLimit(1)
            }
            Spacer()
            if case .track(let t) = app.player.nowPlaying {
                Button { app.toggleStar(t) } label: {
                    Image(systemName: t.starred == nil ? "star" : "star.fill").font(.title3)
                }
                .buttonStyle(.plain)
                Menu { TrackMenu(track: t) } label: {
                    Image(systemName: "ellipsis.circle.fill").font(.title2).symbolRenderingMode(.hierarchical)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
            } else if case .station(let s) = app.player.nowPlaying, let match = app.radioLibraryMatch {
                Button { app.player.play([match], from: .search) } label: {
                    Label("In Library", systemImage: "music.note.house")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Plays this song from your library instead of \(s.name)")
            }
        }
    }

    private var primaryTitle: String {
        if case .station = app.player.nowPlaying {
            return app.radioEnrichment?.title ?? app.player.streamTitle?.title ?? app.player.nowPlaying?.title ?? ""
        }
        return app.player.nowPlaying?.title ?? "Not Playing"
    }

    private var secondaryTitle: String {
        switch app.player.nowPlaying {
        case .track(let t): return t.artist ?? ""
        case .station(let s): return [app.radioEnrichment?.artist ?? app.player.streamTitle?.artist, s.name].compactMap { $0 }.joined(separator: " — ")
        case nil: return ""
        }
    }

    private var scrubber: some View {
        let duration = max(app.player.duration ?? 1, 1)
        let position = scrubbing ?? app.player.position
        return VStack(spacing: 4) {
            #if os(iOS)
            TouchScrubber(position: app.player.position, duration: duration, scrubbing: $scrubbing) { app.player.seek(to: $0) }
            #else
            SeekSlider(position: app.player.position, duration: duration, scrubbing: $scrubbing) { app.player.seek(to: $0) }
            #endif
            HStack {
                Text(Format.duration(position))
                Spacer()
                if case .track(let t) = app.player.nowPlaying, let badge = Format.qualityBadge(t.format) {
                    Text(badge).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.15), in: .capsule)
                        .help(Format.formatDetail(t.format))
                }
                Spacer()
                Text("-" + Format.duration(max(0, duration - position)))
            }
            .font(.caption.monospacedDigit())
            .opacity(0.7)
        }
    }

    private var transport: some View {
        let player = app.player
        let isTrack: Bool = { if case .track = player.nowPlaying { return true } else { return false } }()
        return HStack(spacing: 48) {
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
                .disabled(!isTrack).opacity(isTrack ? 1 : 0.3)
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? (isTrack ? "pause.fill" : "stop.fill") : "play.fill")
                    .font(.system(size: 44))
                    .contentTransition(.symbolEffect(.replace))
            }
            Button { player.next() } label: { Image(systemName: "forward.fill") }
                .disabled(!isTrack).opacity(isTrack ? 1 : 0.3)
        }
        .font(.system(size: 30))
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }

    private var bottomBar: some View {
        HStack {
            if case .track = app.player.nowPlaying {
                toggle(.lyrics, symbol: "quote.bubble")
            }
            Spacer()
            // Library tracks already say what they are.
            if case .station = app.player.nowPlaying {
                IdentifyButton()
                Spacer()
            }
            #if os(iOS)
            RoutePickerButton().frame(width: 32, height: 32)
            #endif
            DevicesButton().padding(.horizontal, 12)
            Spacer()
            if case .track = app.player.nowPlaying {
                toggle(.queue, symbol: "list.bullet")
            }
        }
        .font(.title3)
    }

    private func toggle(_ target: Panel, symbol: String) -> some View {
        Button { withAnimation(.snappy) { panel = panel == target ? .artwork : target } } label: {
            Image(systemName: symbol)
                .padding(8)
                .background(panel == target ? AnyShapeStyle(.white.opacity(0.25)) : AnyShapeStyle(.clear), in: .circle)
        }
        .buttonStyle(.plain)
    }
}

#if os(iOS)
/// The player's position bar. A drag commits to a direction as it starts: sideways scrubs, and
/// anything else is left alone so the player can be swiped away from here too.
struct TouchScrubber: View {
    let position: Double
    let duration: Double
    @Binding var scrubbing: Double?
    let onSeek: (Double) -> Void
    @State private var axis: Axis?
    @GestureState private var isTouching = false

    var body: some View {
        let shown = min(max((scrubbing ?? position) / duration, 0), 1)
        GeometryReader { geometry in
            let isActive = scrubbing != nil
            let thickness: CGFloat = isActive ? 6 : 4
            let restWidth: CGFloat = 28
            let headSize = isActive ? CGSize(width: 46, height: 30) : CGSize(width: restWidth, height: 18)
            // Measured from a fixed width, so the head grows around the same point when touched.
            let center = restWidth / 2 + max(geometry.size.width - restWidth, 0) * shown
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: thickness)
                Capsule().fill(.tint).frame(width: center, height: thickness)
                // Solid at rest; under the finger it becomes a glass lens over the track.
                Capsule()
                    .fill(.white.opacity(isActive ? 0.14 : 1))
                    .frame(width: headSize.width, height: headSize.height)
                    .glassEffect(isActive ? .regular : .identity, in: .capsule)
                    .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
                    .offset(x: center - headSize.width / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.hover, value: scrubbing == nil)
            .contentShape(.rect)
            .onTapGesture { location in
                guard geometry.size.width > 0 else { return }
                onSeek(min(max(location.x / geometry.size.width, 0), 1) * duration)
            }
            .gesture(drag(width: geometry.size.width))
        }
        .frame(height: 30)
        // If the system cancels the touch, onEnded never runs, so control still has to come back.
        .onChange(of: isTouching) { _, touching in
            guard !touching else { return }
            axis = nil
            scrubbing = nil
        }
        .accessibilityElement()
        .accessibilityLabel("Playback Position")
        .accessibilityValue(Format.duration(scrubbing ?? position))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(position + 5, duration))
            case .decrement: onSeek(max(position - 5, 0))
            @unknown default: break
            }
        }
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($isTouching) { _, state, _ in state = true }
            .onChanged { value in
                let move = value.translation
                let direction = axis ?? (abs(move.width) > abs(move.height) ? .horizontal : .vertical)
                axis = direction
                guard direction == .horizontal, width > 0 else { return }
                scrubbing = min(max(value.location.x / width, 0), 1) * duration
            }
            .onEnded { _ in
                if axis == .horizontal, let target = scrubbing { onSeek(target) }
                axis = nil
                scrubbing = nil
            }
    }
}

/// Drag a full-screen player down to close it. It follows the finger with the page visible behind,
/// and springs back if the swipe is too short.
private struct SwipeDownToDismiss: ViewModifier {
    /// Given where a drag started, whether something else owns it.
    let isBlocked: (CGPoint) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var offset: CGFloat = 0
    @State private var height: CGFloat = 900
    /// Decided once per drag: nil before the first movement.
    @State private var isTracking: Bool?
    @State private var bend: CGFloat = 0
    @State private var settle: Task<Void, Never>?
    @State private var restInsets: EdgeInsets?
    /// False from the start of a drag until the player is back at rest.
    @State private var isSettled = true

    private static let dragThreshold: CGFloat = 12

    func body(content: Content) -> some View {
        // Laid out full screen before clipping, so the area under the status bar moves with the
        // player instead of being cut off by the rounded corners.
        GeometryReader { proxy in
            content
                .environment(\.grabBarBend, bend)
                .safeAreaPadding(restInsets ?? proxy.safeAreaInsets)
                .clipShape(.rect(cornerRadius: min(offset / 3, 44), style: .continuous))
                .ignoresSafeArea()
        }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            // Moving away from the status bar shrinks the safe area, which would hold the content
            // still while its top edge slid down. The insets stay as they were at rest instead.
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets in
                if isSettled { restInsets = insets }
            }
            .offset(y: offset)
            .simultaneousGesture(drag)
            .presentationBackground(.clear)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: Self.dragThreshold, coordinateSpace: .global)
            .onChanged { value in
                let move = value.translation
                let tracking = isTracking ?? (move.height > 0 && move.height > abs(move.width) * 1.2 && !isBlocked(value.startLocation))
                isTracking = tracking
                if tracking {
                    isSettled = false
                    // Measured from where the drag was recognized, so the player doesn't jump.
                    offset = max(move.height - Self.dragThreshold, 0)
                    followDirection(velocity: value.velocity.height)
                }
            }
            .onEnded { value in
                let wasTracking = isTracking == true
                isTracking = nil
                guard wasTracking else { return }
                // Short enough to work from the controls, which sit near the bottom of the screen.
                settle?.cancel()
                if value.translation.height > 100 || value.predictedEndTranslation.height > 320 {
                    bend = 1
                    close()
                } else {
                    // Heading back up, so the chevron says so until the player has settled.
                    bend = offset > 4 ? -1 : 0
                    settle = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        if !Task.isCancelled { bend = 0 }
                    }
                    withAnimation(.spring(response: 0.46, dampingFraction: 0.9)) {
                        offset = 0
                    } completion: {
                        if isTracking == nil { isSettled = true }
                    }
                }
            }
    }

    /// Points the chevron the way the finger is moving, and flattens it when the finger stops.
    private func followDirection(velocity: CGFloat) {
        bend = abs(velocity) < 60 ? 0 : max(min(velocity / 450, 1), -1)
        settle?.cancel()
        settle = Task {
            try? await Task.sleep(for: .milliseconds(110))
            if !Task.isCancelled { bend = 0 }
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.3)) {
            offset = height + 120
        } completion: {
            // Already off screen, so the system's own slide would only replay it.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
        }
    }
}
#endif

extension View {
    /// Lets a full-screen player be dragged away. Does nothing on the Mac.
    @ViewBuilder
    func swipeDownToDismiss(isBlocked: @escaping (CGPoint) -> Bool) -> some View {
        #if os(iOS)
        modifier(SwipeDownToDismiss(isBlocked: isBlocked))
        #else
        self
        #endif
    }
}

extension EnvironmentValues {
    /// The grab bar's chevron: 1 points down, -1 points up, and 0 is a flat bar.
    @Entry var grabBarBend: CGFloat = 0
}

/// The grab bar at the top of the player. It's flat at rest and becomes a chevron pointing the way
/// the player is moving: up as it arrives, then down or up with the finger.
struct GrabBar: View {
    @Environment(\.grabBarBend) private var dragBend
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isArriving = true
    let onTap: () -> Void

    var body: some View {
        let bend = isArriving && !reduceMotion ? -1 : dragBend
        Button(action: onTap) {
            GrabBarShape(bend: bend)
                .stroke(.secondary, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                .frame(width: 38, height: 9)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // No bounce: the bar should read as bending, not wobbling.
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: bend)
        .task {
            try? await Task.sleep(for: .milliseconds(420))
            isArriving = false
        }
        .accessibilityLabel("Close Now Playing")
    }
}

private struct GrabBarShape: Shape {
    var bend: CGFloat

    var animatableData: CGFloat {
        get { bend }
        set { bend = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let depth = rect.height / 2 * bend
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY - depth))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.midY + depth))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY - depth))
        return path
    }
}

/// A position slider that shows the drag while editing and always hands control back afterwards.
/// `Slider` can deliver a value after its editing-ended callback, or without any callback at all,
/// so `scrubbing` is only ever set during an edit.
struct SeekSlider: View {
    let position: Double
    let duration: Double
    @Binding var scrubbing: Double?
    let onSeek: (Double) -> Void
    @State private var isEditing = false
    @State private var lastSeek: Double?

    var body: some View {
        Slider(value: Binding(get: { scrubbing ?? position }, set: valueChanged), in: 0...duration) { editing in
            isEditing = editing
            if editing {
                scrubbing = scrubbing ?? position
            } else {
                if let target = scrubbing { commit(target) }
                scrubbing = nil
            }
        }
    }

    private func valueChanged(_ value: Double) {
        if isEditing {
            scrubbing = value
        } else if abs(value - (lastSeek ?? position)) > 0.5 {
            commit(value)   // a tap or accessibility adjustment, or a late final value
        }
    }

    private func commit(_ value: Double) {
        lastSeek = value
        onSeek(value)
    }
}

/// Lyrics that follow the song: the current line is bright, and lines soften with distance from it.
/// Scrolling by hand pauses the follow for a few seconds.
struct LyricsView: View {
    let lyrics: Lyrics?
    let position: TimeInterval
    var fontSize: CGFloat = 28
    let seek: (TimeInterval) -> Void
    @State private var isFollowing = true
    @State private var resumeFollow: Task<Void, Never>?

    private static let introID = -1

    var body: some View {
        if let lyrics, !lyrics.lines.isEmpty {
            content(lyrics)
        } else {
            ContentUnavailableView("No Lyrics", systemImage: "quote.bubble")
                .opacity(0.6)
        }
    }

    private func content(_ lyrics: Lyrics) -> some View {
        let active = lyrics.activeLineIndex(at: .seconds(position))
        let intro = introProgress(lyrics)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: fontSize * 0.72) {
                    if let intro {
                        LyricsGapDots(progress: intro, size: fontSize * 0.34).id(Self.introID)
                    }
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        row(line, index: index, active: active, lyrics: lyrics).id(index)
                    }
                }
                .padding(.vertical, 160)
                .padding(.trailing, 8)
            }
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .tracking {
                    resumeFollow?.cancel()
                    isFollowing = false
                } else if phase == .idle, !isFollowing {
                    resumeFollow?.cancel()
                    resumeFollow = Task {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        isFollowing = true
                        if let line = lyrics.activeLineIndex(at: .seconds(position)) {
                            withAnimation(Motion.page) { proxy.scrollTo(line, anchor: .center) }
                        }
                    }
                }
            }
            .onChange(of: active) { _, new in
                guard let new, isFollowing else { return }
                withAnimation(.spring(response: 0.62, dampingFraction: 0.86)) { proxy.scrollTo(new, anchor: .center) }
            }
            .onAppear {
                if let active { proxy.scrollTo(active, anchor: .center) }
            }
            .onDisappear { resumeFollow?.cancel() }
        }
    }

    @ViewBuilder
    private func row(_ line: Lyrics.Line, index: Int, active: Int?, lyrics: Lyrics) -> some View {
        if line.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if lyrics.isSynced, index == active {
                LyricsGapDots(progress: gapProgress(index, lyrics), size: fontSize * 0.34)
            } else {
                Color.clear.frame(height: 2)
            }
        } else {
            let distance = lyrics.isSynced ? abs(index - (active ?? -1)) : 0
            let text = Text(line.text)
                .font(.system(size: fontSize, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(distance == 0 ? 1 : max(0.42 - Double(distance - 1) * 0.06, 0.2))
                .blur(radius: isFollowing ? min(CGFloat(distance) * 0.55, 2.4) : 0)
                .scaleEffect(distance == 0 ? 1 : 0.965, anchor: .leading)
                .animation(.spring(response: 0.5, dampingFraction: 0.84), value: distance)
                .animation(Motion.page, value: isFollowing)
                .contentShape(.rect)
            if let start = line.start {
                Button { seek(Self.seconds(start)) } label: { text }
                    .buttonStyle(.plain)
            } else {
                text
            }
        }
    }

    /// How far through the silence before the first line, if there is one worth showing.
    private func introProgress(_ lyrics: Lyrics) -> Double? {
        guard lyrics.isSynced, let first = lyrics.lines.first?.start.map(Self.seconds), first >= 3, position < first else { return nil }
        return position / first
    }

    private func gapProgress(_ index: Int, _ lyrics: Lyrics) -> Double {
        guard let start = lyrics.lines[index].start.map(Self.seconds) else { return 0 }
        let next = lyrics.lines[(index + 1)...].lazy.compactMap(\.start).first.map(Self.seconds)
        guard let next, next > start else { return 0 }
        return (position - start) / (next - start)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        TimeInterval(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// Three dots that fill in during an instrumental gap.
private struct LyricsGapDots: View {
    let progress: Double
    let size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.7) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: size, height: size)
                    .opacity(0.25 + 0.75 * min(max(progress * 3 - Double(index), 0), 1))
            }
        }
        .frame(height: size * 2)
        .accessibilityHidden(true)
    }
}

struct QueueView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let queue = app.player.queue
        List {
            if !queue.upNext.isEmpty {
                Section {
                    ForEach(Array(queue.upNext.enumerated()), id: \.element.id) { index, track in
                        row(track)
                            #if os(macOS)
                            .contextMenu {
                                Button("Remove from Queue") { app.player.removeFromUpNext(at: IndexSet(integer: index)) }
                            }
                            #endif
                    }
                    .onDelete { app.player.removeFromUpNext(at: $0) }
                    .onMove { app.player.moveUpNext(from: $0, to: $1) }
                } header: {
                    Text("Up Next").opacity(0.7)
                }
            }
            Section {
                ForEach(queue.remainingContext) { track in
                    Button { app.player.jump(to: track) } label: { row(track) }.buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Text(contextTitle).opacity(0.7)
                    Spacer()
                    Button { app.player.setShuffle(!queue.isShuffled) } label: {
                        Image(systemName: "shuffle").opacity(queue.isShuffled ? 1 : 0.5)
                    }
                    Button { app.player.cycleRepeat() } label: {
                        Image(systemName: queue.repeatMode == .one ? "repeat.1" : "repeat")
                            .opacity(queue.repeatMode == .off ? 0.5 : 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        #if os(macOS)
        .dropDestination(for: String.self) { payloads, _ in
            let tracks = (try? app.store.tracks(ids: TrackDrag.ids(in: payloads))) ?? []
            guard !tracks.isEmpty else { return false }
            app.player.addToQueue(tracks)
            return true
        }
        #endif
    }

    private var contextTitle: String {
        switch app.player.queue.contextSource {
        case .album(_, let name), .playlist(_, let name), .artist(_, let name): "Playing from \(name)"
        case .radio: "Station"
        default: "Continue Playing"
        }
    }

    private func row(_ track: Track) -> some View {
        HStack(spacing: Metrics.queueArtwork < 40 ? 8 : 12) {
            ArtworkView(.coverArt(track.coverArtID), cornerRadius: 4, size: Metrics.queueArtwork)
            VStack(alignment: .leading, spacing: 0) {
                Text(track.title).font(Metrics.queueArtwork < 40 ? .caption.weight(.medium) : .body).lineLimit(1)
                Text(track.artist ?? "").font(Metrics.queueArtwork < 40 ? .caption2 : .caption).opacity(0.6).lineLimit(1)
            }
        }
        .listRowBackground(Color.clear)
    }
}

#if os(iOS)
import AVKit

/// AirPlay picker. Stereo devices join this sheet when handoff lands (M4).
struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .white
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
