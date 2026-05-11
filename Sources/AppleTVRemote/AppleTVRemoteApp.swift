import SwiftUI
import AppKit
import Combine
import AppleTVProtocol

/// Menu-bar-only entry point. There is no main window — the entire UI is
/// the popover hosted by `MenuBarController` and the floating text-input
/// window opened by `TextInputWindowManager`.
@main
struct AppleTVRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var discovery   = DeviceDiscovery()
    @StateObject private var connection  = CompanionConnection()
    @StateObject private var autoConnect = AutoConnectStore()
    @StateObject private var reconnector = AutoReconnector()
    @State       private var ipcServer:           IPCServer?
    @State       private var autoConnectObserver: AnyCancellable?
    @State       private var appListObserver:     AnyCancellable?
    @State       private var iconRefreshTimer:    Timer?

    var body: some Scene {
        // Register setUp on the delegate during body evaluation so it's ready
        // before applicationDidFinishLaunching fires (especially for headless
        // `open -g` launches with no visible window).
        let _ = { appDelegate.onFinishLaunching = setUp }()

        // SwiftUI's App protocol requires at least one Scene; we don't show
        // a main window, so a Settings scene with EmptyView() is the
        // standard no-op placeholder. The user never sees it.
        return Settings { EmptyView() }
    }

    /// Called by AppDelegate.applicationDidFinishLaunching. Idempotent.
    private func setUp() {
        appDelegate.onFinishLaunching = nil
        appDelegate.connection = connection

        // Pure menu-bar-only app — no Dock icon, no menu bar.
        NSApp.setActivationPolicy(.accessory)

        discovery.startDiscovery()
        MenuBarController.shared.setUp(
            discovery: discovery,
            connection: connection,
            autoConnect: autoConnect,
            reconnector: reconnector
        )
        reconnector.setUp(connection: connection, discovery: discovery, autoConnect: autoConnect)
        TextInputWindowManager.shared.setUp(connection: connection)

        if ipcServer == nil {
            let server = IPCServer(connection: connection,
                                   discovery: discovery,
                                   autoConnect: autoConnect,
                                   reconnector: reconnector)
            server.start()
            ipcServer = server
        }
        if autoConnectObserver == nil {
            autoConnectObserver = discovery.$devices
                .receive(on: DispatchQueue.main)
                .sink { [connection, autoConnect] devices in
                    guard connection.state == .disconnected else { return }
                    if let device = devices.first(where: {
                        autoConnect.isEnabled($0.id) && $0.host != nil
                    }) {
                        connection.wakeAndConnect(to: device)
                    }
                }
        }
        if appListObserver == nil {
            appListObserver = connection.$appList
                .receive(on: DispatchQueue.main)
                .sink { apps in
                    guard !apps.isEmpty else { return }
                    let ids = apps.map { $0.id }
                    AppIconCache.shared.refresh(bundleIDs: ids)
                }
        }
        if iconRefreshTimer == nil {
            iconRefreshTimer = Timer.scheduledTimer(withTimeInterval: 12 * 60 * 60, repeats: true) { [weak connection] _ in
                Task { @MainActor in
                    guard let ids = connection?.appList.map({ $0.id }), !ids.isEmpty else { return }
                    AppIconCache.shared.refreshIfStale(bundleIDs: ids)
                }
            }
        }
    }
}

// MARK: - App delegate

enum LaunchSettle {
    /// Settle delay used after first appear to suppress visual flashes from
    /// transient state (connection churn). Centralised here so any timers
    /// can stay in sync.
    static let delay: TimeInterval = 0.5
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by AppleTVRemoteApp after SwiftUI initialises its @StateObjects.
    var onFinishLaunching: (() -> Void)?

    weak var connection: CompanionConnection?

    func applicationDidFinishLaunching(_ notification: Notification) {
        onFinishLaunching?()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu-bar-only — never quit just because the popover or text input
        // window closed.
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // If the user clicks a "type to Apple TV" notification while a text
        // field is active on the TV, surface the text-input window.
        guard KeyboardNotificationManager.shared.wasNotified,
              connection?.keyboardActive == true else { return }
        KeyboardNotificationManager.shared.cancelAttention()
        NotificationCenter.default.post(
            name: KeyboardNotificationManager.openKeyboardSheetNotification, object: nil)
    }
}
