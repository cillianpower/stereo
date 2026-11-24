import CoreGraphics
import SwiftUI

/// Shared motion, so everything in the app moves with the same feel.
enum Motion {
    /// Pointer feedback: quick, with a little bounce.
    static let hover = Animation.spring(response: 0.28, dampingFraction: 0.72)
    /// Moving between pages.
    static let page = Animation.spring(response: 0.42, dampingFraction: 0.88)
    /// Large surfaces changing shape, such as the player expanding.
    static let morph = Animation.spring(response: 0.56, dampingFraction: 0.84)
    /// Background color following the artwork.
    static let color = Animation.easeInOut(duration: 1.1)
}

/// Layout density. The Mac is compact, in the spirit of Obsidian and Doppler; iOS stays touch-sized.
enum Metrics {
    /// Height of the player bar across the top of the Mac window.
    static let macTopBar: CGFloat = 32
    /// Width of the collapsed sidebar.
    static let macRail: CGFloat = 44
    #if os(macOS)
    static let cardRadius: CGFloat = 6
    static let cardMinimum: CGFloat = 128
    static let shelfCard: CGFloat = 136
    static let gridSpacing: CGFloat = 14
    static let gridRowSpacing: CGFloat = 16
    static let pagePadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 18
    static let shelfTitle = Font.system(size: 15, weight: .semibold)
    static let shelfRow: CGFloat = 38
    static let shelfRowArtwork: CGFloat = 32
    static let shelfRowWidth: CGFloat = 230
    static let listArtwork: CGFloat = 28
    static let queueArtwork: CGFloat = 28
    static let stationArtwork: CGFloat = 30
    static let cardPlayButton: CGFloat = 26
    static let promoRadius: CGFloat = 8
    static let promoPadding: CGFloat = 10
    static let actionIcon: CGFloat = 15
    #else
    static let cardRadius: CGFloat = 10
    static let cardMinimum: CGFloat = 150
    static let shelfCard: CGFloat = 160
    static let gridSpacing: CGFloat = 16
    static let gridRowSpacing: CGFloat = 20
    static let pagePadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 28
    static let shelfTitle = Font.title2.bold()
    static let shelfRow: CGFloat = 56
    static let shelfRowArtwork: CGFloat = 48
    static let shelfRowWidth: CGFloat = 280
    static let listArtwork: CGFloat = 44
    static let queueArtwork: CGFloat = 40
    static let stationArtwork: CGFloat = 48
    static let cardPlayButton: CGFloat = 36
    static let promoRadius: CGFloat = 20
    static let promoPadding: CGFloat = 16
    static let actionIcon: CGFloat = 24
    #endif
}

extension AppSettings.AccentOption {
    var color: Color {
        switch self {
        case .system:
            #if os(macOS)
            Color(nsColor: .controlAccentColor)
            #else
            .accentColor
            #endif
        case .red: Color(red: 0.98, green: 0.176, blue: 0.282)
        case .pink: .pink
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .purple: .purple
        case .graphite: .gray
        }
    }
}

// MARK: Artwork color

/// Nine colors sampled from artwork, one for each point of a 3×3 mesh gradient.
struct ArtworkPalette: Equatable {
    var colors: [Color]

    static let neutral = ArtworkPalette(colors: Array(repeating: Color(white: 0.16), count: 9))

    /// Saturated a little and darkened, so white text stays readable on top.
    static func extract(from image: CGImage) -> ArtworkPalette? {
        let side = 3
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var colors: [Color] = []
        for i in 0..<(side * side) {
            let r = Double(bytes[i * 4]) / 255, g = Double(bytes[i * 4 + 1]) / 255, b = Double(bytes[i * 4 + 2]) / 255
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            func tone(_ c: Double) -> Double { min(max((luma + (c - luma) * 1.35) * 0.72, 0), 1) }
            colors.append(Color(.sRGB, red: tone(r), green: tone(g), blue: tone(b)))
        }
        return ArtworkPalette(colors: colors)
    }
}

/// A slowly moving mesh gradient made from the artwork's colors, like Apple Music's Now Playing.
struct AmbientBackground: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let source: ArtworkView.Source
    var isAnimating = true

    @State private var palette = ArtworkPalette.neutral

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isAnimating || reduceMotion)) { context in
            MeshGradient(width: 3, height: 3, points: points(at: context.date.timeIntervalSinceReferenceDate),
                         colors: palette.colors, smoothsColors: true)
        }
        .task(id: source) {
            guard let image = await app.artworkImage(for: source, pixels: 120),
                  let next = ArtworkPalette.extract(from: image) else { return }
            withAnimation(Motion.color) { palette = next }
        }
    }

    /// The outer points stay on the edges so the gradient always covers the view.
    private func points(at time: TimeInterval) -> [SIMD2<Float>] {
        let t = (!isAnimating || reduceMotion) ? 0 : Float(time.truncatingRemainder(dividingBy: 3600))
        func drift(_ speed: Float, _ phase: Float, _ amount: Float = 0.11) -> Float { sin(t * speed + phase) * amount }
        return [
            [0, 0], [0.5 + drift(0.23, 0), 0], [1, 0],
            [0, 0.5 + drift(0.19, 1)], [0.5 + drift(0.31, 2, 0.17), 0.5 + drift(0.27, 3, 0.17)], [1, 0.5 + drift(0.21, 4)],
            [0, 1], [0.5 + drift(0.17, 5), 1], [1, 1],
        ]
    }
}

// MARK: Small animated pieces

/// The little equalizer on the row that's playing. It rests when paused.
struct PlayingBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isPlaying: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !isPlaying || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().frame(width: 2, height: height(i, t))
                }
            }
            .frame(height: 11, alignment: .bottom)
        }
        .foregroundStyle(.tint)
        .accessibilityLabel(isPlaying ? "Playing" : "Paused")
    }

    private func height(_ bar: Int, _ time: TimeInterval) -> CGFloat {
        guard isPlaying, !reduceMotion else { return 3 + CGFloat(bar % 2) * 2 }
        return 3 + 8 * abs(sin(time * (2.1 + Double(bar) * 0.7) + Double(bar) * 1.3))
    }
}

private struct HoverLift: ViewModifier {
    var scale: CGFloat
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            // The shadow exists only while hovered: hundreds of resting shadows make scrolling heavy.
            .background {
                if isHovering {
                    RoundedRectangle(cornerRadius: Metrics.cardRadius)
                        .fill(.black)
                        .shadow(color: .black.opacity(0.32), radius: 9, y: 5)
                        .transition(.opacity)
                }
            }
            .scaleEffect(isHovering ? scale : 1)
            .onHover { hovering in withAnimation(Motion.hover) { isHovering = hovering } }
    }
}

#if os(macOS)
/// A see-through blur that fades out under a page title, so the player bar above keeps a sharp edge.
struct MacHeaderFade: ViewModifier {
    func body(content: Content) -> some View {
        content.background(alignment: .top) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.82), location: 0),
                        .init(color: .black.opacity(0.5), location: 0.6),
                        .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
                .padding(.bottom, -18)
                .allowsHitTesting(false)
        }
    }
}
#endif

#if os(iOS)
/// Pages scroll under a see-through fade, so the header never turns into a separate bar.
private struct PageTopFade: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectHidden(true, for: .top)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                GeometryReader { geometry in
                    let height = geometry.safeAreaInsets.top + 20
                    Rectangle()
                        .fill(.thinMaterial)
                        .mask {
                            // Solid behind the title so scrolling text can't compete with it.
                            LinearGradient(stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.72),
                                .init(color: .clear, location: 1),
                            ], startPoint: .top, endPoint: .bottom)
                        }
                        .frame(height: height)
                        .offset(y: -geometry.safeAreaInsets.top)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}
#endif

extension View {
    /// The iPhone's header treatment. The Mac has its own, in `pageHeader`.
    @ViewBuilder
    func pageTopFade() -> some View {
        #if os(iOS)
        modifier(PageTopFade())
        #else
        self
        #endif
    }

    /// The Mac's page title row, with the page's own controls on the right. The top bar belongs to
    /// the player there. iOS keeps its navigation bar, so this does nothing on iPhone and iPad.
    @ViewBuilder
    func pageHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        #if os(macOS)
        scrollEdgeEffectHidden(true, for: .top).safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 22, weight: .bold)).lineLimit(1)
                Spacer(minLength: 12)
                trailing()
            }
            .controlSize(.small)
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .modifier(MacHeaderFade())
        }
        #else
        self
        #endif
    }

    func pageHeader(_ title: String) -> some View { pageHeader(title) { EmptyView() } }

    /// Lifts the view toward the pointer.
    func hoverLift(scale: CGFloat = 1.025) -> some View { modifier(HoverLift(scale: scale)) }
}
