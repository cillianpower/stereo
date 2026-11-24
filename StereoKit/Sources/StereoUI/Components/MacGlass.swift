#if os(macOS)
import AppKit
import SwiftUI

// Stereo on the Mac has one look, shared with Audiogen: a translucent window that blurs the
// desktop, with Liquid Glass controls and panels on top. Colour comes from the wallpaper, the
// artwork and the accent colour, never from painted backgrounds. With Reduce Transparency on,
// the system makes these materials opaque.

extension View {
    /// The window is translucent and blurs the desktop behind it.
    func windowGlass() -> some View {
        containerBackground(for: .window) { MacWindowBlur() }
    }

    /// A content panel in Liquid Glass.
    func glassPanel(cornerRadius: CGFloat = 14) -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// A soft blur that fades out away from an edge, so a bar sits on the glass without a hard line.
    func glassEdgeFade(_ edge: VerticalEdge, extends: CGFloat = 14) -> some View {
        modifier(GlassEdgeFade(edge: edge, extends: extends))
    }
}

private struct GlassEdgeFade: ViewModifier {
    let edge: VerticalEdge
    let extends: CGFloat

    func body(content: Content) -> some View {
        content.background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.85), location: 0),
                        .init(color: .black.opacity(0.5), location: 0.6),
                        .init(color: .clear, location: 1),
                    ], startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
                }
                .padding(edge == .top ? .bottom : .top, -extends)
                .allowsHitTesting(false)
        }
    }
}

/// A behind-window blur that stays live when the window is in the background. SwiftUI's window
/// materials follow the window's active state, so an inactive window would turn flat grey.
struct MacWindowBlur: NSViewRepresentable {
    /// Clears the window's own backing once attached, so the blur shows the desktop, not grey.
    final class BlurView: NSVisualEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = BlurView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A hairline between columns, faint enough to read as a fold in the glass rather than a rule.
struct GlassSeam: View {
    var body: some View {
        Rectangle().fill(.primary.opacity(0.08)).frame(width: 1).accessibilityHidden(true)
    }
}
#endif
