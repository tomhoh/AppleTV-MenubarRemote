import SwiftUI
import AppKit
import Combine

/// Shared focus signal between the AppKit window (which knows when it
/// actually became key) and the SwiftUI TextField (which needs to be
/// told). SwiftUI silently drops a `focused = true` if the hosting
/// NSWindow isn't key yet — asking for focus once on `.task` is a race.
/// Watching `pulse` and re-applying focus each time the window keys up
/// makes the request stick regardless of timing.
@MainActor
final class TextInputFocusSignal: ObservableObject {
    @Published var pulse: Int = 0
    func request() { pulse &+= 1 }
}

/// Floating, borderless, transparent input strip that appears centered on
/// screen when the ATV surfaces a text field (`_tiStarted`).
///
/// Design goals:
///   * Not attached to the menu-bar popover — this appears wherever the
///     user is looking, screen-center.
///   * No window chrome — no title bar, no close button, no visible
///     window frame. The NSWindow is transparent; only the inner
///     rounded capsule and the TextField are drawn.
///   * Auto-dismisses when the ATV closes the text field
///     (`keyboardActive → false`) or the connection drops.
@MainActor
final class TextInputWindowManager: NSObject {
    static let shared = TextInputWindowManager()

    private var window: NSWindow?
    private weak var connection: CompanionConnection?
    private var keyboardActiveObserver: AnyCancellable?
    private let focusSignal = TextInputFocusSignal()
    private var outsideClickMonitor: Any?

    func setUp(connection: CompanionConnection) {
        self.connection = connection
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenNotification),
            name: KeyboardNotificationManager.openKeyboardSheetNotification,
            object: nil
        )
        keyboardActiveObserver = connection.$keyboardActive
            .removeDuplicates()
            .sink { [weak self] active in
                Task { @MainActor in
                    guard let self else { return }
                    if !active { self.closeWindow() }
                }
            }
    }

    @objc private func handleOpenNotification() {
        openWindow()
    }

    /// True while the floating input window exists and thus needs the
    /// menu-bar popover held open despite key-focus moving away from it.
    private var popoverLocked = false

    func openWindow() {
        guard let connection else { return }
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = TextInputView(
            connection: connection,
            focusSignal: focusSignal
        ) { [weak self] in
            self?.closeWindow()
        }
        let contentRect = NSRect(x: 0, y: 0, width: 480, height: 72)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = contentRect
        hostingView.autoresizingMask = [.width, .height]

        // Borderless + transparent: no title bar, no visible NSWindow
        // frame at all. The only thing on screen is the SwiftUI content
        // (which draws its own translucent capsule around the field).
        //
        // Using KeyableBorderlessWindow so the borderless style still
        // accepts keyboard focus — plain NSWindow refuses to become key
        // when styleMask is .borderless.
        let w = KeyableBorderlessWindow(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        // hasShadow=true on a borderless window with a clear background
        // makes macOS draw a rounded-rect window shadow whose corner
        // radii don't match the SwiftUI content — a rectangular halo
        // with more-rounded top corners than bottom. Turning the OS
        // shadow off removes that artifact; the field's own drawing is
        // all the chrome we want.
        w.hasShadow = false
        w.level = .floating
        w.isReleasedWhenClosed = false
        // Position: horizontally centered on the main screen, vertically
        // *below* the menu-bar popover so the input strip doesn't sit
        // behind the remote UI. Fallback to screen-center when the
        // popover isn't currently open (e.g. user clicked a keyboard-
        // input notification while the popover was closed).
        let inputSize = contentRect.size
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let originX = screenFrame.midX - inputSize.width / 2
        let originY: CGFloat
        if let popFrame = MenuBarController.shared.popoverWindowFrame() {
            // AppKit Y grows upward, so "below the popover" means Y
            // strictly less than popover.minY.
            originY = popFrame.minY - 20 - inputSize.height
        } else {
            originY = screenFrame.midY - inputSize.height / 2
        }
        w.setFrame(NSRect(origin: NSPoint(x: originX, y: originY),
                          size: inputSize),
                   display: false)
        w.contentView = hostingView
        // Force the underlying content-view layer to render fully clear
        // and un-rounded, otherwise macOS 26 draws its own subtle
        // window-frame rounding around a borderless NSWindow — the
        // "rectangular border" with mismatched top / bottom corners.
        w.contentView?.wantsLayer = true
        w.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        w.contentView?.layer?.cornerRadius = 0
        w.contentView?.layer?.masksToBounds = false
        // Same treatment on the NSHostingView itself so SwiftUI's own
        // wantsLayer default doesn't reintroduce a background.
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        w.delegate = self
        // Order matters: bring the app forward BEFORE keying the window,
        // otherwise the accessory-policy app can leave the window
        // technically key while another app remains frontmost — SwiftUI
        // then refuses to install first-responder focus on the field.
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        // Kick the focus signal — SwiftUI's .focused($focused) request
        // on first appearance often races the window becoming key.
        // The `windowDidBecomeKey` callback below pulses it again once
        // the window is actually key, so focus lands whichever tick
        // wins.
        focusSignal.request()

        KeyboardNotificationManager.shared.cancelAttention()
        window = w
        // Keep the menu-bar popover from auto-dismissing when the user
        // clicks into the floating input — its default `.transient`
        // behavior would close it the moment this window becomes key.
        // Balanced in closeWindow / windowWillClose.
        if !popoverLocked {
            popoverLocked = true
            MenuBarController.shared.lockPopover()
        }
        // With the popover held open, we lose its transient click-out
        // dismissal. Restore that manually via a global-monitor: any
        // click outside this app dismisses BOTH the input strip and
        // the popover. Clicks inside our own windows (popover or the
        // input) don't trigger the global monitor, so they're safely
        // ignored.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.closeWindow()
                MenuBarController.shared.dismissPopover()
            }
        }
    }

    func closeWindow() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        window?.close()
        window = nil
        KeyboardNotificationManager.shared.resetNotify()
        if popoverLocked {
            popoverLocked = false
            MenuBarController.shared.unlockPopover()
        }
    }
}

extension TextInputWindowManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        window = nil
        KeyboardNotificationManager.shared.resetNotify()
        if popoverLocked {
            popoverLocked = false
            MenuBarController.shared.unlockPopover()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Now that the window is actually key, ask the SwiftUI content
        // to (re-)focus the TextField. Cheap and idempotent.
        focusSignal.request()
    }
}

// MARK: - Keyable borderless window

/// A borderless NSWindow that can still become key/main, so its
/// SwiftUI TextField accepts keyboard focus. Plain NSWindow with
/// styleMask `.borderless` returns false from `canBecomeKey`.
private final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Inline SwiftUI content

/// One `TextField` with a "Search" placeholder, wrapped in a
/// translucent rounded capsule for legibility over the transparent
/// window. Nothing else — no title, no icon, no trash button.
private struct TextInputView: View {
    @ObservedObject var connection: CompanionConnection
    @ObservedObject var focusSignal: TextInputFocusSignal
    var onClose: () -> Void

    @State private var text: String = ""
    @State private var previousText: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Search", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 24))
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                // Single symmetric rounded fill — no double borders,
                // no asymmetric OS window rounding fighting a nested
                // wrapper. Fills the whole NSWindow so nothing else
                // is visible.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.thinMaterial)
            )
            .focused($focused)
            .task(id: focusSignal.pulse) {
                // The focus signal is pulsed both by openWindow (before
                // the window keys up) and by NSWindowDelegate.
                // windowDidBecomeKey (once it actually is). One tick of
                // sleep lets the runloop settle so SwiftUI's focus
                // machinery accepts the request.
                try? await Task.sleep(nanoseconds: 50_000_000)
                focused = true
            }
            .onSubmit(onClose)
            .onExitCommand(perform: onClose)  // Esc closes the strip
            .onChange(of: text) { newValue in
                handleChange(old: previousText, new: newValue)
                previousText = newValue
            }
            .onChange(of: connection.keyboardActive) { active in
                if !active { onClose() }
            }
            .onChange(of: connection.state) { state in
                if case .disconnected = state { onClose() }
                if case .error        = state { onClose() }
            }
    }

    private func handleChange(old: String, new: String) {
        if new.count > old.count {
            let appended = String(new.dropFirst(old.count))
            connection.sendText(appended) { _ in }
        } else if new.count < old.count {
            let removed = old.count - new.count
            for _ in 0..<removed {
                connection.sendBackspace { _ in }
            }
        } else if new != old {
            connection.sendText(new) { _ in }
        }
    }
}
