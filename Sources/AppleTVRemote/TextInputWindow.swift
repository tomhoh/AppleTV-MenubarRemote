import SwiftUI
import AppKit
import Combine

/// Standalone floating window that opens when the Apple TV reports an active
/// text field. Replaces the in-main-window sheet from the original UI.
@MainActor
final class TextInputWindowManager: NSObject {
    static let shared = TextInputWindowManager()

    private var window: NSWindow?
    private weak var connection: CompanionConnection?
    private var keyboardActiveObserver: AnyCancellable?

    func setUp(connection: CompanionConnection) {
        self.connection = connection
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenNotification),
            name: KeyboardNotificationManager.openKeyboardSheetNotification,
            object: nil
        )

        // Also auto-close if the Apple TV closes the text field while we
        // weren't watching (e.g. user navigated away).
        keyboardActiveObserver = connection.$keyboardActive
            .removeDuplicates()
            .sink { [weak self] active in
                if !active { Task { @MainActor in self?.closeWindow() } }
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

        let view = TextInputView(connection: connection) { [weak self] in
            self?.closeWindow()
        }
        let hosting = NSHostingController(rootView: view)
        hosting.preferredContentSize = NSSize(width: 360, height: 90)

        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable]
        w.title = "Apple TV Keyboard"
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 360, height: 90))
        w.center()
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

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
}

// MARK: - Inner view

private struct TextInputView: View {
    @ObservedObject var connection: CompanionConnection
    var onClose: () -> Void

    /// Mirrors the text we believe is on the Apple TV right now (or at least
    /// everything we've sent since the window opened). Diffing against new
    /// values is how we decide whether to send `sendText` or `sendBackspace`.
    @State private var text: String = ""
    @State private var previousText: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .foregroundStyle(.secondary)
                Text("Type to Apple TV")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { connection.sendClearText(completion: { _ in }) }
                    text = ""
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear text on Apple TV")
            }
            TextField("Type and it appears on the TV…", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onAppear { focused = true }
                .onSubmit(onClose)
                .onChange(of: text) { newValue in
                    handleChange(old: previousText, new: newValue)
                    previousText = newValue
                }
        }
        .padding(10)
        .frame(width: 340)
        .background(.thickMaterial)
        .onChange(of: connection.keyboardActive) { active in
            if !active { onClose() }
        }
        .onChange(of: connection.state) { state in
            if case .disconnected = state { onClose() }
            if case .error = state { onClose() }
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
        }
        // Same length but different content = paste-replace; send the new
        // content as fresh input. Acceptable simplification for v1.
        else if new != old {
            connection.sendText(new) { _ in }
        }
    }
}
