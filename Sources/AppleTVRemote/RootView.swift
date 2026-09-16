import SwiftUI
import Combine

/// Top-level router for the menu-bar popover. Picks the right inner view
/// based on `CompanionConnection.state`, manages app-launcher slide-out
/// visibility, conditionally shows a Now Playing banner above everything,
/// and bubbles content-size changes up so `MenuBarController` can resize
/// the `NSPopover`.
struct RootView: View {
    @EnvironmentObject private var connection: CompanionConnection
    @EnvironmentObject private var session: RemoteSession
    @State private var showAppLauncher: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if isConnected, hasNowPlaying {
                NowPlayingBanner()
                    .frame(width: totalWidth)
            }
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
        }
        .animation(RemoteTheme.appLauncherAnimation, value: showAppLauncher)
        .onChange(of: showAppLauncher) { _ in
            postSizeChanged()
        }
        .onChange(of: isConnected) { _ in
            if !isConnected, showAppLauncher {
                showAppLauncher = false
            }
            postSizeChanged()
        }
        .onChange(of: hasNowPlaying) { _ in
            postSizeChanged()
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

    private var hasNowPlaying: Bool {
        guard let info = connection.nowPlaying else { return false }
        return (info.title?.isEmpty == false)
            || (info.artist?.isEmpty == false)
            || (info.app?.isEmpty == false)
    }

    private var totalWidth: CGFloat {
        let w = RemoteTheme.popoverWidth
            + ((showAppLauncher && isConnected) ? RemoteTheme.appLauncherWidth : 0)
        return w
    }

    private func toggleAppLauncher() {
        guard isConnected else { return }
        showAppLauncher.toggle()
        if showAppLauncher {
            connection.fetchApps(completion: nil)
            let ids = connection.appList.map { $0.id }
            if !ids.isEmpty {
                AppIconCache.shared.refresh(bundleIDs: ids)
            }
        }
    }

    /// The NowPlayingBanner is shown at the top when nowPlaying has any
    /// content. ~36pt tall (varies with subtitle / progress bar presence —
    /// SwiftUI sizes it intrinsically, we estimate here for MenuBarController).
    private var bannerHeight: CGFloat {
        guard isConnected, hasNowPlaying, let info = connection.nowPlaying else { return 0 }
        var h: CGFloat = 16  // base padding + title line
        if info.artist?.isEmpty == false || info.app?.isEmpty == false { h += 14 }
        if let d = info.duration, d > 0 { h += 6 }
        return max(28, h)
    }

    private func postSizeChanged() {
        let width = (showAppLauncher && isConnected)
            ? RemoteTheme.popoverWidth + RemoteTheme.appLauncherWidth
            : RemoteTheme.popoverWidth
        let height = RemoteTheme.popoverHeight + bannerHeight
        let size = CGSize(width: width, height: height)
        NotificationCenter.default.post(
            name: .menuBarPopoverContentSizeChanged,
            object: nil,
            userInfo: ["size": size]
        )
    }
}

extension Notification.Name {
    /// Posted by `RootView` when its target content size changes (launcher
    /// toggle, now-playing appearance, connection-state transitions).
    /// `MenuBarController` listens and updates `NSPopover.contentSize`.
    static let menuBarPopoverContentSizeChanged = Notification.Name(
        "com.appletvremote.menuBarPopoverContentSizeChanged"
    )
}
