import SwiftUI
import AppKit
import Combine
import ServiceManagement
import AppleTVLogging
import AppleTVProtocol
import AppleTVIPC

/// Owns the menu-bar status item and the popover that hosts the SwiftUI
/// remote. Menu-bar-only — no main window. Resizes the popover when
/// `RootView` posts a content-size change (e.g. when the app launcher
/// slide-out toggles).
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    static let shared = MenuBarController()

    private var statusItem:       NSStatusItem?
    private var popover:          NSPopover?
    private var session:          RemoteSession?
    private var stateCancellable: AnyCancellable?
    private var sizeObserver:     NSObjectProtocol?

    // Trackpad swipe-to-arrow state. Active only while the popover is open.
    private var scrollMonitor: Any?
    private var scrollAccumX: CGFloat = 0
    private var scrollAccumY: CGFloat = 0
    private let scrollSwipeThreshold: CGFloat = 35

    // Sustained-swipe escalation: after the user fires this many consecutive
    // arrow steps in the same direction within `swipeChainWindow` seconds,
    // we switch from discrete `RemoteCommand` presses to the Companion
    // protocol's `sendSwipe` gesture (the "trackpad flick" tvOS interprets
    // as a fast/momentum scroll — what the Siri Remote does when you click
    // and swipe).
    private var lastSwipeDirection: TrackpadDirection?
    private var lastSwipeTime: TimeInterval = 0
    private var sustainedSwipeCount: Int = 0
    private let sustainedSwipeAfter: Int = 2          // 3rd same-direction fire switches to gesture
    private let swipeChainWindow: TimeInterval = 0.5  // must be within this gap to count as sustained

    private weak var connection:  CompanionConnection?
    private weak var discovery:   DeviceDiscovery?
    private weak var autoConnect: AutoConnectStore?

    func setUp(discovery: DeviceDiscovery,
               connection: CompanionConnection,
               autoConnect: AutoConnectStore,
               reconnector: AutoReconnector) {
        guard statusItem == nil else { return }
        self.connection  = connection
        self.discovery   = discovery
        self.autoConnect = autoConnect

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        guard let button = item.button else { return }

        // Custom Siri-Remote silhouette. SwiftPM doesn't run `actool`, so the
        // `.xcassets` directory ships as raw files in the resource bundle —
        // `NSImage(named:)` won't find the icon. Load the PDF directly by
        // path instead, then fall back to SF Symbols if that fails.
        let pdfURL = Bundle.module.url(
            forResource: "MenuBarIcon",
            withExtension: "pdf",
            subdirectory: "Assets.xcassets/MenuBarIcon.imageset"
        )
        let img: NSImage?
        if let url = pdfURL, let pdfImage = NSImage(contentsOf: url) {
            img = pdfImage
        } else {
            img = NSImage(systemSymbolName: "appletv.remote.gen2", accessibilityDescription: nil)
              ?? NSImage(systemSymbolName: "tv.fill", accessibilityDescription: nil)
        }
        img?.isTemplate = true
        img?.size = NSSize(width: 18, height: 18)
        button.image = img
        button.imageScaling = .scaleProportionallyDown
        button.action = #selector(toggle(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let session = RemoteSession(connection: connection)
        self.session = session

        let vc = NSHostingController(rootView:
            RootView()
                .environmentObject(discovery)
                .environmentObject(connection)
                .environmentObject(autoConnect)
                .environmentObject(reconnector)
                .environmentObject(session)
        )
        vc.sizingOptions = .preferredContentSize

        let pop = NSPopover()
        pop.contentViewController = vc
        pop.contentSize = NSSize(
            width: RemoteTheme.popoverWidth,
            height: RemoteTheme.popoverHeight
        )
        pop.behavior = .transient
        pop.delegate = self
        popover = pop

        // Re-key the popover window when state changes while visible so it
        // doesn't look washed-out after a disconnect/reconnect.
        stateCancellable = connection.$state
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.popover?.isShown == true, NSApp.isActive else { return }
                self.popover?.contentViewController?.view.window?.makeKey()
            }

        // Resize popover when RootView signals a content-size change
        // (e.g. user toggled the app launcher slide-out).
        sizeObserver = NotificationCenter.default.addObserver(
            forName: .menuBarPopoverContentSizeChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let size = note.userInfo?["size"] as? CGSize else { return }
            Task { @MainActor in self.popover?.contentSize = size }
        }
    }

    nonisolated func popoverDidShow(_ notification: Notification) {
        Task { @MainActor in self.installScrollMonitor() }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            self.removeScrollMonitor()
            NSApp.deactivate()
        }
    }

    // MARK: - Trackpad swipe-to-arrow

    /// Listens for trackpad scroll + 2-finger-click (right-mouse-down) events
    /// while the popover is open. Scroll deltas translate to directional
    /// commands; 2-finger clicks fire `.select`. Clicks on the status item
    /// button itself are ignored so right-clicking the icon still opens the
    /// context menu.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollAccumX = 0
        scrollAccumY = 0
        scrollMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .scrollWheel:
                // Only react to trackpad-style precise deltas. Mouse wheels
                // emit imprecise deltas that would feel jittery here.
                guard event.hasPreciseScrollingDeltas else { return event }
                Task { @MainActor in self.handleTrackpadScroll(event) }
                return nil  // consume

            case .rightMouseDown:
                // Don't hijack right-clicks on our own status item — those
                // are how the user opens the context menu.
                if let btnWin = self.statusItem?.button?.window,
                   event.window === btnWin {
                    return event
                }
                Task { @MainActor in self.session?.dispatch(.select) }
                return nil  // consume

            default:
                return event
            }
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        scrollAccumX = 0
        scrollAccumY = 0
        lastSwipeDirection = nil
        lastSwipeTime = 0
        sustainedSwipeCount = 0
    }

    private enum TrackpadDirection {
        case up, down, left, right

        var asRemoteCommand: AppleTVProtocol.RemoteCommand {
            switch self {
            case .up: return .up
            case .down: return .down
            case .left: return .left
            case .right: return .right
            }
        }

        var asSwipeDirection: AppleTVProtocol.SwipeDirection {
            switch self {
            case .up: return .up
            case .down: return .down
            case .left: return .left
            case .right: return .right
            }
        }
    }

    private func handleTrackpadScroll(_ event: NSEvent) {
        scrollAccumX += event.scrollingDeltaX
        scrollAccumY += event.scrollingDeltaY

        let ax = abs(scrollAccumX), ay = abs(scrollAccumY)
        guard max(ax, ay) >= scrollSwipeThreshold else { return }

        let direction: TrackpadDirection
        if ax >= ay {
            // Horizontal: positive deltaX = finger swept right → .right.
            direction = scrollAccumX > 0 ? .right : .left
            scrollAccumX = 0
        } else {
            // Vertical: positive scrollingDeltaY = content scrolled down → finger swept up → .up.
            // Empirically reversed in user testing — match what feels right.
            direction = scrollAccumY > 0 ? .down : .up
            scrollAccumY = 0
        }

        // Sustained-swipe escalation: after N consecutive same-direction
        // fires within the chain window, switch from discrete arrow presses
        // to the Companion protocol's sendSwipe gesture — tvOS treats that
        // as a trackpad flick and triggers fast/momentum scrolling, which
        // is what a "click and swipe" does on a real Siri Remote.
        let now = ProcessInfo.processInfo.systemUptime
        let isChained = lastSwipeDirection == direction &&
                        (now - lastSwipeTime) < swipeChainWindow
        sustainedSwipeCount = isChained ? sustainedSwipeCount + 1 : 0
        lastSwipeDirection = direction
        lastSwipeTime = now

        if sustainedSwipeCount >= sustainedSwipeAfter {
            // Sustained motion → click-and-swipe (press select + drag).
            // tvOS apps distinguish this from a plain flick (e.g. Hulu
            // opens the full Guide on click-swipe down, not on tap-swipe).
            session?.dispatchClickAndSwipe(direction.asSwipeDirection)
        } else {
            session?.dispatch(direction.asRemoteCommand)
        }
    }

    @objc private func toggle(_ sender: AnyObject?) {
        guard let pop = popover, let button = statusItem?.button else { return }

        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }

        if pop.isShown {
            NSApp.deactivate()
            pop.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: false)
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            DispatchQueue.main.async {
                let popWin = pop.contentViewController?.view.window
                popWin?.makeKey()
                popWin?.makeFirstResponder(nil)
            }
        }
    }

    /// Programmatically open the popover. Kept for IPCServer callers that
    /// previously called `openMainWindow()`; routing to the popover is the
    /// closest equivalent now that there is no main window.
    func openMainWindow() {
        guard let pop = popover, let button = statusItem?.button else { return }
        if !pop.isShown {
            NSApp.activate(ignoringOtherApps: true)
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Right-click context menu

    private func showContextMenu() {
        let menu = NSMenu()
        menu.delegate = self

        // ── Header: connection status ─────────────────────────────────────
        let statusItem: NSMenuItem
        switch connection?.state ?? .disconnected {
        case .connected:
            let name = connection?.currentDevice?.name ?? "Apple TV"
            statusItem = NSMenuItem(title: "Connected: \(name)", action: nil, keyEquivalent: "")
        case .connecting:
            statusItem = NSMenuItem(title: "Connecting…", action: nil, keyEquivalent: "")
        case .waking:
            statusItem = NSMenuItem(title: "Waking Apple TV…", action: nil, keyEquivalent: "")
        case .awaitingPairingPin:
            statusItem = NSMenuItem(title: "Awaiting PIN…", action: nil, keyEquivalent: "")
        case .error:
            statusItem = NSMenuItem(title: "Connection error", action: nil, keyEquivalent: "")
        case .disconnected:
            statusItem = NSMenuItem(title: "Not connected", action: nil, keyEquivalent: "")
        }
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(.separator())

        // ── Devices ───────────────────────────────────────────────────────
        let devices = discovery?.devices ?? []
        if devices.isEmpty {
            let empty = NSMenuItem(title: "No Apple TVs detected", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Apple TVs", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let currentId = connection?.currentDevice?.id
            for device in devices {
                let isCurrent = device.id == currentId && connection?.state == .connected
                let isPaired = device.isPaired

                let suffix: String
                if isCurrent      { suffix = "  •  connected" }
                else if isPaired  { suffix = "  •  paired" }
                else              { suffix = "  •  click to pair" }

                let item = NSMenuItem(
                    title: "\(device.name)\(suffix)",
                    action: isCurrent ? nil : #selector(deviceSelected(_:)),
                    keyEquivalent: ""
                )
                if isCurrent {
                    item.state = .on
                    item.isEnabled = false
                } else {
                    item.target = self
                    item.representedObject = device
                }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())

        // ── Connected-only actions ────────────────────────────────────────
        if connection?.state == .connected {
            let refresh = NSMenuItem(title: "Refresh App List",
                                     action: #selector(refreshAppList), keyEquivalent: "")
            refresh.target = self
            menu.addItem(refresh)

            let disconnect = NSMenuItem(title: "Disconnect",
                                        action: #selector(disconnect), keyEquivalent: "")
            disconnect.target = self
            menu.addItem(disconnect)

            menu.addItem(.separator())
        }

        // ── App-level actions ─────────────────────────────────────────────
        let about = NSMenuItem(title: "About Apple TV Remote",
                               action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let shortcuts = NSMenuItem(title: "Keyboard Shortcuts…",
                                   action: #selector(showKeyboardShortcuts), keyEquivalent: "")
        shortcuts.target = self
        menu.addItem(shortcuts)

        let launch = NSMenuItem(title: "Launch at Startup",
                                action: #selector(toggleLaunchAtStartup), keyEquivalent: "")
        launch.target = self
        launch.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Apple TV Remote",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)

        self.statusItem?.menu = menu
        self.statusItem?.button?.performClick(nil)
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        Task { @MainActor in self.statusItem?.menu = nil }
    }

    // MARK: - Menu actions

    @objc private func deviceSelected(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AppleTVDevice else { return }
        connection?.wakeAndConnect(to: device)
        // Open the popover so the user sees the pairing UI if a PIN is needed.
        openMainWindow()
    }

    @objc private func refreshAppList(_ sender: Any?) {
        connection?.fetchApps()
    }

    @objc private func disconnect(_ sender: Any?) {
        connection?.disconnect()
    }

    @objc private func showKeyboardShortcuts(_ sender: Any?) {
        KeyboardShortcutsWindowController.shared.show()
    }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let stamp: String = {
            let path = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { return "unknown" }
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMddHHmm"
            fmt.timeZone = TimeZone.current
            return fmt.string(from: mtime)
        }()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Apple TV Remote",
            .applicationVersion: "\(AppVersion.major)-\(stamp)",
            .version: "",
            .credits: NSAttributedString(
                string: "Control your AppleTV(s) from your Mac.",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
            )
        ])
    }

    @objc private func toggleLaunchAtStartup(_ sender: Any?) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.app.fail("Launch at startup toggle failed: \(error)")
        }
    }
}
