import SwiftUI

/// Visual constants for the menu-bar drop-down remote.
enum RemoteTheme {

    // MARK: - Popover (the remote *is* the window — no inner panel)

    static let popoverWidth: CGFloat = 165
    static let popoverHeight: CGFloat = 318
    static let popoverPadding: CGFloat = 12

    // MARK: - Body gradient (adapts to light/dark)

    static let bodyGradientLight = LinearGradient(
        colors: [
            Color(white: 0.84),
            Color(white: 0.66),
        ],
        startPoint: .top, endPoint: .bottom
    )

    static let bodyGradientDark = LinearGradient(
        colors: [
            Color(white: 0.32),
            Color(white: 0.18),
        ],
        startPoint: .top, endPoint: .bottom
    )

    static func bodyGradient(for scheme: ColorScheme) -> LinearGradient {
        scheme == .dark ? bodyGradientDark : bodyGradientLight
    }

    static let bodyHighlightGradientLight = LinearGradient(
        colors: [Color.white.opacity(0.35), Color.white.opacity(0.0)],
        startPoint: .top, endPoint: .center
    )

    static let bodyHighlightGradientDark = LinearGradient(
        colors: [Color.white.opacity(0.10), Color.white.opacity(0.0)],
        startPoint: .top, endPoint: .center
    )

    static func bodyHighlightGradient(for scheme: ColorScheme) -> LinearGradient {
        scheme == .dark ? bodyHighlightGradientDark : bodyHighlightGradientLight
    }

    // MARK: - Clickpad

    static let clickpadDiameter: CGFloat = 130
    static let clickpadInnerDiameter: CGFloat = 72
    static let clickpadRingThickness: CGFloat =
        (clickpadDiameter - clickpadInnerDiameter) / 2
    static let clickpadTopInset: CGFloat = 18
    static let clickpadBevelDepth: CGFloat = 1.5

    /// Uses `Color.primary` so the bevel reads correctly in both light & dark.
    static let clickpadInsetGradient = LinearGradient(
        colors: [
            Color.primary.opacity(0.16),
            Color.primary.opacity(0.04),
        ],
        startPoint: .top, endPoint: .bottom
    )

    static let clickpadSelectMaterial: Material = .thickMaterial
    static let clickpadRingMaterial: Material = .regularMaterial

    // MARK: - Buttons

    static let buttonSize: CGFloat = 44
    static let buttonCornerRadius: CGFloat = 22
    static let buttonRowSpacing: CGFloat = 14
    static let buttonRowHorizontalPadding: CGFloat = 8
    static let buttonGlyphFont: Font = .system(size: 16, weight: .semibold)
    static let buttonMaterial: Material = .ultraThinMaterial
    static let buttonGlyphTint = Color.primary.opacity(0.78)
    static let buttonStroke = Color.primary.opacity(0.10)

    static let volumeRockerWidth: CGFloat = 44
    static let volumeRockerHeight: CGFloat = 92
    static let volumeRockerCornerRadius: CGFloat = 22

    // Power button sits at the top edge of the remote, right-aligned —
    // matches the 2nd-gen Siri Remote's small top-edge power key.
    static let powerButtonSize: CGFloat = 22
    static let powerTopPadding: CGFloat = 10
    static let powerTrailingPadding: CGFloat = 12

    // MARK: - Animations

    static let pressedScale: CGFloat = 0.94
    static let pressAnimation: Animation =
        .spring(response: 0.2, dampingFraction: 0.6)

    static let clickpadRippleDuration: Double = 0.35
    static let clickpadRippleMaxScale: CGFloat = 1.6

    static let siriPulseDuration: Double = 1.0
    static let siriPulseGradient = LinearGradient(
        colors: [Color.cyan, Color.purple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - App launcher slide-out

    static let appLauncherWidth: CGFloat = 320
    static let appLauncherAnimation: Animation = .spring(response: 0.35, dampingFraction: 0.85)

    // MARK: - SF Symbol names

    enum Glyph {
        static let back = "chevron.backward"
        static let home = "tv"
        static let appSwitcher = "rectangle.stack.fill"
        static let playPause = "playpause.fill"
        static let volumeUp = "speaker.wave.3.fill"
        static let volumeDown = "speaker.wave.1.fill"
        static let apps = "square.grid.3x3.fill"
    }
}
