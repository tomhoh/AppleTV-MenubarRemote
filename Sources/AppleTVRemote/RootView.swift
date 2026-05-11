import SwiftUI
import Combine

/// Top-level router for the menu-bar popover. Picks the right inner view
/// based on `CompanionConnection.state`, manages app-launcher slide-out
/// visibility, and bubbles content-size changes up so `MenuBarController`
/// can resize the `NSPopover`.
struct RootView: View {
    @EnvironmentObject private var connection: CompanionConnection
    @EnvironmentObject private var session: RemoteSession
    @State private var showAppLauncher: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            if showAppLauncher && isConnected {
                AppLauncherPanel(isPresented: $showAppLauncher)
                    .frame(width: RemoteTheme.appLauncherWidth,
                           height: RemoteTheme.popoverHeight)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            content
                .frame(width: RemoteTheme.popoverWidth,
                       height: RemoteTheme.popoverHeight)
        }
        .frame(height: RemoteTheme.popoverHeight)
        .animation(RemoteTheme.appLauncherAnimation, value: showAppLauncher)
        .onChange(of: showAppLauncher) { _ in
            postSizeChanged()
        }
        .onChange(of: isConnected) { _ in
            if !isConnected, showAppLauncher {
                showAppLauncher = false
            }
        }
        .onAppear { postSizeChanged() }
    }

    @ViewBuilder
    private var content: some View {
        switch connection.state {
        case .connected:
            RemoteView(onToggleAppLauncher: toggleAppLauncher)
        default:
            PairingView()
        }
    }

    private var isConnected: Bool {
        if case .connected = connection.state { return true }
        return false
    }

    private func toggleAppLauncher() {
        guard isConnected else { return }
        showAppLauncher.toggle()
        if showAppLauncher {
            // Refresh the list when revealed; the connection caches the
            // last fetched list but the user may have installed apps since.
            connection.fetchApps(completion: nil)
            // Also force an icon-cache refresh — the auto-refresh observer
            // only fires when appList *changes*, so revisiting the launcher
            // with the same list won't otherwise retry any apps that were
            // marked notFound or whose fetch failed.
            let ids = connection.appList.map { $0.id }
            if !ids.isEmpty {
                AppIconCache.shared.refresh(bundleIDs: ids)
            }
        }
    }

    private func postSizeChanged() {
        let width = (showAppLauncher && isConnected)
            ? RemoteTheme.popoverWidth + RemoteTheme.appLauncherWidth
            : RemoteTheme.popoverWidth
        let size = CGSize(width: width, height: RemoteTheme.popoverHeight)
        NotificationCenter.default.post(
            name: .menuBarPopoverContentSizeChanged,
            object: nil,
            userInfo: ["size": size]
        )
    }
}

extension Notification.Name {
    /// Posted by `RootView` when its target content size changes (e.g. when
    /// the app-launcher slide-out is toggled). `MenuBarController` listens
    /// and updates `NSPopover.contentSize` accordingly.
    static let menuBarPopoverContentSizeChanged = Notification.Name(
        "com.appletvremote.menuBarPopoverContentSizeChanged"
    )
}
