import SwiftUI
import AppleTVProtocol

/// Bottom button area of the remote: back, home, mic (Siri hold), play/pause,
/// volume rocker. Mic also shows an "Apps" launcher toggle below it via a
/// callback passed from the parent.
struct RemoteButtonsView: View {
    @EnvironmentObject private var session: RemoteSession
    var onToggleAppLauncher: () -> Void

    var body: some View {
        VStack(spacing: RemoteTheme.buttonRowSpacing) {
            HStack {
                glyphButton(.menu, symbol: RemoteTheme.Glyph.back)
                Spacer()
                glyphButton(.home, symbol: RemoteTheme.Glyph.home)
                Spacer()
                SiriHoldButton()
            }
            .padding(.horizontal, RemoteTheme.buttonRowHorizontalPadding)

            HStack(alignment: .center) {
                glyphButton(.playPause, symbol: RemoteTheme.Glyph.playPause)
                Spacer()
                appsToggleButton
                Spacer()
                VolumeRockerView()
            }
            .padding(.horizontal, RemoteTheme.buttonRowHorizontalPadding)
        }
    }

    private func glyphButton(_ command: RemoteCommand, symbol: String) -> some View {
        Button { session.dispatch(command) } label: {
            Image(systemName: symbol)
                .font(RemoteTheme.buttonGlyphFont)
                .foregroundStyle(RemoteTheme.buttonGlyphTint)
                .frame(width: RemoteTheme.buttonSize,
                       height: RemoteTheme.buttonSize)
                .background(
                    RoundedRectangle(cornerRadius: RemoteTheme.buttonCornerRadius)
                        .fill(RemoteTheme.buttonMaterial)
                )
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var appsToggleButton: some View {
        Button(action: onToggleAppLauncher) {
            Image(systemName: RemoteTheme.Glyph.apps)
                .font(RemoteTheme.buttonGlyphFont)
                .foregroundStyle(RemoteTheme.buttonGlyphTint)
                .frame(width: RemoteTheme.buttonSize,
                       height: RemoteTheme.buttonSize)
                .background(
                    RoundedRectangle(cornerRadius: RemoteTheme.buttonCornerRadius)
                        .fill(RemoteTheme.buttonMaterial)
                )
        }
        .buttonStyle(PressableButtonStyle())
        .help("Show app launcher")
    }
}

// MARK: - Siri (hold to talk)

private struct SiriHoldButton: View {
    @EnvironmentObject private var session: RemoteSession
    @State private var isHeld = false

    var body: some View {
        Image(systemName: RemoteTheme.Glyph.mic)
            .font(RemoteTheme.buttonGlyphFont)
            .foregroundStyle(isHeld ? .white : RemoteTheme.buttonGlyphTint)
            .frame(width: RemoteTheme.buttonSize,
                   height: RemoteTheme.buttonSize)
            .background(background)
            .scaleEffect(isHeld ? RemoteTheme.pressedScale : 1.0)
            .animation(RemoteTheme.pressAnimation, value: isHeld)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHeld else { return }
                        isHeld = true
                        session.dispatchSiri()
                    }
                    .onEnded { _ in
                        guard isHeld else { return }
                        isHeld = false
                    }
            )
    }

    @ViewBuilder
    private var background: some View {
        if isHeld {
            RoundedRectangle(cornerRadius: RemoteTheme.buttonCornerRadius)
                .fill(RemoteTheme.siriPulseGradient)
        } else {
            RoundedRectangle(cornerRadius: RemoteTheme.buttonCornerRadius)
                .fill(RemoteTheme.buttonMaterial)
        }
    }
}

// MARK: - Volume rocker

private struct VolumeRockerView: View {
    @EnvironmentObject private var session: RemoteSession
    @State private var pressedHalf: Half?

    private enum Half { case top, bottom }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: RemoteTheme.volumeRockerCornerRadius)
                .fill(RemoteTheme.buttonMaterial)

            VStack(spacing: 0) {
                halfLabel(.volumeUp,
                          symbol: RemoteTheme.Glyph.volumeUp,
                          highlighted: pressedHalf == .top)
                Divider()
                    .background(Color.black.opacity(0.10))
                halfLabel(.volumeDown,
                          symbol: RemoteTheme.Glyph.volumeDown,
                          highlighted: pressedHalf == .bottom)
            }
        }
        .frame(width: RemoteTheme.volumeRockerWidth,
               height: RemoteTheme.volumeRockerHeight)
        .clipShape(RoundedRectangle(cornerRadius: RemoteTheme.volumeRockerCornerRadius))
        .scaleEffect(pressedHalf != nil ? RemoteTheme.pressedScale : 1.0)
        .animation(RemoteTheme.pressAnimation, value: pressedHalf)
        .onTapGesture(coordinateSpace: .local) { location in
            let isTop = location.y < RemoteTheme.volumeRockerHeight / 2
            let command: RemoteCommand = isTop ? .volumeUp : .volumeDown
            let half: Half = isTop ? .top : .bottom
            session.dispatch(command)
            flash(half)
        }
    }

    private func halfLabel(_ command: RemoteCommand,
                           symbol: String,
                           highlighted: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(RemoteTheme.buttonGlyphTint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                highlighted
                ? Color.white.opacity(0.25)
                : Color.clear
            )
    }

    private func flash(_ half: Half) {
        pressedHalf = half
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            pressedHalf = nil
        }
    }
}
