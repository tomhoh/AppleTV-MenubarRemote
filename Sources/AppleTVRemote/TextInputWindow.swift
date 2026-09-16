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
        let contentRect = NSRect(x: 0, y: 0, width: 380, height: 56)
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
        w.hasShadow = true
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.contentView = hostingView
        w.center()
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
    }

    func closeWindow() {
        window?.close()
        window = nil
        KeyboardNotificationManager.shared.resetNotify()
    }
}

extension TextInputWindowManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        window = nil
        KeyboardNotificationManager.shared.resetNotify()
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
            .font(.system(size: 18))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
            )
            .padding(6)  // gutter for the shadow so it isn't clipped
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
