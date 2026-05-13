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

    /// Tracks whether our last power dispatch was a sleep — so the next
    /// press toggles to wake. Reset to `false` (assume TV is awake) any
    /// time the connection enters `.connected`, because you can't be
    /// connected to a sleeping TV.
    private var hasSentSleep: Bool = false
    private var stateObserver: AnyCancellable?

    init(connection: CompanionConnection) {
        self.connection = connection
        // Reset the power-toggle assumption when we successfully connect.
        stateObserver = connection.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if case .connected = state {
                    self?.hasSentSleep = false
                }
            }
    }

    func dispatch(_ command: RemoteCommand) {
        connection.send(command)
    }

    /// Long-press home → tvOS app switcher (the "press and hold the
    /// click-wheel home button" gesture on a real Siri Remote). The
    /// Companion protocol does **not** expose a Siri trigger via HID
    /// keycodes; the iOS Remote app uses a separate API channel for that.
    func dispatchAppSwitcher() {
        connection.sendLongPress(.home, ms: 1000)
    }

    /// Long-press menu → screensaver.
    func dispatchScreensaver() {
        connection.sendLongPress(.menu, ms: 1000)
    }

    /// Long-press select → home-screen edit-apps mode.
    func dispatchEditApps() {
        connection.sendLongPress(.select, ms: 1000)
    }

    /// Power-button toggle. Companion protocol's `.wake` and `.sleep` are
    /// separate explicit keycodes (not a single toggle), so we track our
    /// last action and alternate. Assumption is reset to "awake" whenever
    /// the connection becomes `.connected` (sleeping TVs aren't connectable).
    func dispatchPower() {
        if hasSentSleep {
            connection.send(.wake)
            hasSentSleep = false
        } else {
            connection.send(.sleep)
            hasSentSleep = true
        }
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
