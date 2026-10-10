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
    private let scrollSwipeThreshold: CGFloat = 60

    // Per-session capture of the Option modifier so a mid-swipe modifier
    // release doesn't switch us back to discrete arrows partway through.
    private var scrollSessionOption: Bool = false

    // Rate-limit Option-held swipes — each `sendSwipe` is ~300ms of
    // interleaved touch events; firing them too fast causes overlapping
    // touch sessions on the tvOS side and subsequent swipes get dropped.
    private var lastOptionSwipeTime: TimeInterval = 0
    private let optionSwipeMinInterval: TimeInterval = 0.4

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
        // Remove the scroll monitor SYNCHRONOUSLY (not via a Task hop)
        // so no further trackpad events can slip through. Previously this
        // was dispatched to the main actor via Task, which left a brief
        // window where in-flight scroll events were still captured and
        // forwarded to the Apple TV after the popover was already gone.
        MainActor.assumeIsolated { self.removeScrollMonitor() }
        Task { @MainActor in NSApp.deactivate() }
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
            // Hard gate: if the popover isn't on-screen right now, don't
            // consume or dispatch anything. The monitor is normally torn
            // down in popoverDidClose, but AppKit can briefly leave it
            // live between the user's dismissing click and the removal,
            // and an in-flight scroll gesture captured in that window
            // used to still fire HID commands at the Apple TV.
            if self.popover?.isShown != true { return event }

            switch event.type {
            case .scrollWheel:
                // Skip when the launcher slide-out is open so the apps
                // grid's ScrollView can receive the events naturally.
                if let pop = self.popover,
                   pop.contentSize.width > RemoteTheme.popoverWidth + 20 {
                    return event
                }
                // Only react to trackpad-style precise deltas. Mouse wheels
                // emit imprecise deltas that would feel jittery here.
                guard event.hasPreciseScrollingDeltas else { return event }
                Task { @MainActor in
                    // Re-check at dispatch time: between the monitor
                    // callback firing and this task actually running on
                    // the main actor, the popover may have closed.
                    guard self.popover?.isShown == true else { return }
                    self.handleTrackpadScroll(event)
                }
                return nil  // consume

            case .rightMouseDown:
                // Don't hijack right-clicks on our own status item — those
                // are how the user opens the context menu.
                if let btnWin = self.statusItem?.button?.window,
                   event.window === btnWin {
                    return event
                }
                Task { @MainActor in
                    guard self.popover?.isShown == true else { return }
                    self.session?.dispatch(.select)
                }
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
    }

    private func handleTrackpadScroll(_ event: NSEvent) {
        // Ignore momentum (post-release) events. We only act on actual
        // finger movement so the gesture has a clear start and end.
        if event.momentumPhase != [] { return }

        // Session lifecycle via NSEvent.phase:
        //   .began    → reset accumulator + capture Option state for the session
        //   .ended/.cancelled → reset and stop
        // Capturing Option at .began protects against the modifier being
        // released mid-swipe (which would otherwise flip us back to arrows).
        if event.phase.contains(.began) {
            scrollAccumX = 0
            scrollAccumY = 0
            scrollSessionOption = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .contains(.option)
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            scrollAccumX = 0
            scrollAccumY = 0
            return
        }

        scrollAccumX += event.scrollingDeltaX
        scrollAccumY += event.scrollingDeltaY

        let threshold: CGFloat = scrollSessionOption ? 25 : scrollSwipeThreshold
        let ax = abs(scrollAccumX), ay = abs(scrollAccumY)
        guard max(ax, ay) >= threshold else { return }

        let isHorizontal = ax >= ay
        let positiveX = scrollAccumX > 0
        let positiveY = scrollAccumY > 0
        if isHorizontal { scrollAccumX = 0 } else { scrollAccumY = 0 }

        if scrollSessionOption {
            // Rate-limit so we don't queue overlapping touch sessions on the TV.
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastOptionSwipeTime >= optionSwipeMinInterval else { return }
            lastOptionSwipeTime = now

            let dir: AppleTVProtocol.SwipeDirection
            if isHorizontal {
                dir = positiveX ? .right : .left
            } else {
                dir = positiveY ? .down : .up
            }
            // Plain swipe (touch flick) — no select-press, so it won't
            // pause/unpause a playing video.
            session?.dispatchSwipe(dir)
        } else {
            let cmd: AppleTVProtocol.RemoteCommand
            if isHorizontal {
                cmd = positiveX ? .right : .left
            } else {
                cmd = positiveY ? .down : .up
            }
            session?.dispatch(cmd)
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

        // Attention state diagnostic — published by tvOS via FetchAttentionState.
        // Raw integer; semantics aren't publicly documented but the value is
        // useful for debugging connection health / active-content state.
        if let attn = connection?.attentionState {
            let item = NSMenuItem(title: "    Attention: \(attn)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

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
                // The device model's `isPaired` isn't populated by discovery —
                // ask the credential store directly so paired devices don't
                // masquerade as "click to pair" in the menu.
                let isPaired = connection?.isPaired(deviceID: device.id) ?? false

                let suffix: String
                if isCurrent      { suffix = "  •  connected" }
                else if isPaired  { suffix = "  •  click to connect" }
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

        // ── Manage pairings submenu ───────────────────────────────────────
        // Lets the user remove the on-disk credentials for a specific
        // paired Apple TV (or wipe all of them) without re-pairing. The TV
        // itself keeps its "Allowed Devices" entry until the user removes
        // it there — we don't implement HAP pair-remove (no reference
        // client-side implementation exists for the Companion transport).
        // The confirmation dialogs tell the user to clean up TV-side.
        let paired = CredentialStore().allDeviceIDs()
        if !paired.isEmpty {
            let manage = NSMenuItem(title: "Manage pairings", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            // Resolve each stored deviceID to a friendly name via the
            // current discovery snapshot. Offline ATVs fall back to the
            // short deviceID (hex suffix) so the user still has
            // SOMETHING to disambiguate.
            let devicesById = Dictionary(uniqueKeysWithValues:
                (discovery?.devices ?? []).map { ($0.id, $0.name) })
            for id in paired {
                let friendly = devicesById[id] ?? "Apple TV (\(id.suffix(6)))"
                let item = NSMenuItem(
                    title: "Unpair \(friendly)…",
                    action: #selector(unpairDevice(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = PairingRef(deviceID: id, displayName: friendly)
                sub.addItem(item)
            }
            sub.addItem(.separator())
            let clearAll = NSMenuItem(
                title: "Clear all pairings…",
                action: #selector(clearAllPairings),
                keyEquivalent: ""
            )
            clearAll.target = self
            sub.addItem(clearAll)
            manage.submenu = sub
            menu.addItem(manage)
        }

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
        guard let device = sender.representedObject as? AppleTVDevice,
              let connection else { return }
        // `wakeAndConnect` no-ops if we're already connected/connecting to
        // some other device (see its early return on non-disconnected
        // state). Tear the current session down first when needed, then
        // connect on the next runloop tick — the 0.3 s asyncAfter matches
        // the reconnect gap used by PairingFlow for a clean socket close.
        let needsTeardown: Bool
        switch connection.state {
        case .disconnected, .error: needsTeardown = false
        default:                    needsTeardown = true
        }
        if needsTeardown {
            connection.disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak connection] in
                connection?.wakeAndConnect(to: device)
            }
        } else {
            connection.wakeAndConnect(to: device)
        }
        // Open the popover so the user sees the pairing UI if a PIN is needed.
        openMainWindow()
    }

    @objc private func refreshAppList(_ sender: Any?) {
        connection?.fetchApps()
    }

    @objc private func disconnect(_ sender: Any?) {
        connection?.disconnect()
    }

    // MARK: - Unpair / clear-all pairings
    //
    // Local-only: deletes the credential file(s) from Application Support
    // and tears down the active session if the user unpaired the device
    // they're currently connected to. The Apple TV keeps its "Allowed
    // Devices" entry until the user removes it there — we don't implement
    // HAP pair-remove (no reference client-side implementation for the
    // Companion transport exists in pyatv or elsewhere, and getting the
    // frame type wrong risks TV-side state corruption). The confirmation
    // and completion dialogs tell the user to clean up TV-side.

    @objc private func unpairDevice(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? PairingRef else { return }

        let alert = NSAlert()
        alert.messageText = "Unpair \"\(ref.displayName)\" from this Mac?"
        alert.informativeText =
            "This deletes the stored credentials. You'll still need to " +
            "remove this Mac from the Apple TV: Settings → Users and " +
            "Accounts → Allowed Devices."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Unpair")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // If this device is currently connected, tear the session down
        // first so we don't keep sending frames with a credential that
        // no longer exists.
        if connection?.currentDevice?.id == ref.deviceID {
            connection?.disconnect()
        }

        let store = CredentialStore()
        store.delete(deviceID: ref.deviceID)
        store.deleteAirPlay(deviceID: ref.deviceID)

        let done = NSAlert()
        done.messageText = "Pairing removed from this Mac."
        done.informativeText =
            "Open your Apple TV: Settings → Users and Accounts → Allowed " +
            "Devices, and delete the entry for this Mac to finish cleanup."
        done.alertStyle = .informational
        done.addButton(withTitle: "OK")
        done.runModal()
    }

    @objc private func clearAllPairings(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Remove ALL stored Apple TV pairings from this Mac?"
        alert.informativeText =
            "This cannot be undone — you'll need to re-pair each Apple TV. " +
            "You should also remove this Mac from each Apple TV: Settings → " +
            "Users and Accounts → Allowed Devices."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear all")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        connection?.disconnect()
        let removed = CredentialStore().deleteAll()

        let done = NSAlert()
        done.messageText = "Cleared \(removed) pairing(s) from this Mac."
        done.informativeText =
            "Open each Apple TV: Settings → Users and Accounts → Allowed " +
            "Devices, and remove any lingering entries for this Mac."
        done.alertStyle = .informational
        done.addButton(withTitle: "OK")
        done.runModal()
    }

    /// Carries a paired-device reference through NSMenuItem.representedObject.
    /// NSMenuItem's representedObject requires AnyObject, so a class, not a
    /// struct.
    private final class PairingRef: NSObject {
        let deviceID: String
        let displayName: String
        init(deviceID: String, displayName: String) {
            self.deviceID = deviceID
            self.displayName = displayName
        }
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
