import SwiftUI

/// Shared press-down scale animation for tap-and-release buttons on the remote.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? RemoteTheme.pressedScale : 1.0)
            .animation(RemoteTheme.pressAnimation, value: configuration.isPressed)
    }
}
