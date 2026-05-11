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

        // Prefer our custom Siri-Remote silhouette from the asset catalog;
        // fall back to SF Symbols if the bundle resource isn't found (e.g.
        // when running outside the proper resource bundle layout).
        let img = NSImage(named: NSImage.Name("MenuBarIcon"))
                ?? Bundle.module.image(forResource: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "appletv.remote.gen2", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "tv.fill", accessibilityDescription: nil)
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

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            NSApp.deactivate()
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
