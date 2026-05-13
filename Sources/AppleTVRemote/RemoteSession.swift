import Foundation
import Combine
import AppleTVProtocol

/// Bridge between our menu-bar SwiftUI views and the existing
/// `CompanionConnection` backend. Views call methods here; this class fans
/// out to the right `connection.*` API.
///
/// Kept deliberately thin — the connection itself is the source of truth
/// for connection state. Views that need state should observe
/// `CompanionConnection` directly as an `@EnvironmentObject`.
@MainActor
final class RemoteSession: ObservableObject {
    /// The remote commands UI surfaces — strict superset of
    /// `AppleTVProtocol.RemoteCommand` (we add `.siri` and `.power` as
    /// semantic actions that map to long-press / sleep below).
    enum Action {
        case button(RemoteCommand)
        case siri
        case power
        case swipe(SwipeDirection)
    }

    private unowned let connection: CompanionConnection

    init(connection: CompanionConnection) {
        self.connection = connection
    }

    func dispatch(_ command: RemoteCommand) {
        connection.send(command)
    }

    /// Siri-style trigger: long-press the home button. The Companion
    /// protocol has no streaming hold; firing once is enough for tvOS to
    /// recognise the gesture and start a Siri session.
    func dispatchSiri() {
        connection.sendLongPress(.home, ms: 1000)
    }

    /// "Power" button: in the Companion protocol this is `.sleep`. Waking
    /// happens automatically via `wakeAndConnect` on the next user action
    /// (or via Wake-on-LAN at reconnect time).
    func dispatchPower() {
        connection.send(.sleep)
    }

    func dispatchSwipe(_ direction: SwipeDirection) {
        connection.sendSwipe(direction)
    }

    /// Press-and-drag gesture — what a Siri Remote does when you click the
    /// centre of the click-wheel and swipe. tvOS apps distinguish this from
    /// a plain `sendSwipe` (e.g. Hulu opens the full Guide on a click-swipe
    /// down, but only a small overlay on a tap-swipe).
    func dispatchClickAndSwipe(_ direction: SwipeDirection) {
        connection.sendClickAndSwipe(direction)
    }
}
