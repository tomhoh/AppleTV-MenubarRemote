import SwiftUI

/// The Siri-Remote-style face that fills the menu-bar popover.
struct RemoteView: View {
    @EnvironmentObject private var session: RemoteSession
    @Environment(\.colorScheme) private var colorScheme

    var onToggleAppLauncher: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ClickpadView()
                .padding(.top, RemoteTheme.clickpadTopInset)
            RemoteButtonsView(onToggleAppLauncher: onToggleAppLauncher)
            Spacer(minLength: 0)
        }
        .frame(width: RemoteTheme.popoverWidth, height: RemoteTheme.popoverHeight)
        .background(remoteSurface)
        .overlay(alignment: .topTrailing) {
            PowerButton()
                .padding(.top, RemoteTheme.powerTopPadding)
                .padding(.trailing, RemoteTheme.powerTrailingPadding)
        }
    }

    /// The popover *is* the remote — aluminum gradient + soft top highlight.
    /// Light/dark variants picked by the system theme.
    private var remoteSurface: some View {
        ZStack {
            RemoteTheme.bodyGradient(for: colorScheme)
            RemoteTheme.bodyHighlightGradient(for: colorScheme)
        }
    }
}

// MARK: - Power button (top-right)

private struct PowerButton: View {
    @EnvironmentObject private var session: RemoteSession

    var body: some View {
        Button { session.dispatchPower() } label: {
            Image(systemName: "power")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(RemoteTheme.buttonGlyphTint)
                .frame(width: RemoteTheme.powerButtonSize,
                       height: RemoteTheme.powerButtonSize)
                .background(RemoteTheme.buttonMaterial, in: Circle())
                .overlay(Circle().strokeBorder(RemoteTheme.buttonStroke,
                                                lineWidth: 0.5))
        }
        .buttonStyle(PressableButtonStyle())
        .help("Toggle Apple TV power (sleep / wake)")
    }
}
