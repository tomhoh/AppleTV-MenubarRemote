import SwiftUI
import AppKit
import Combine

/// Bridges the ATV's "text field opened" event to the menu-bar popover.
///
/// The Apple TV pushes `_tiStarted` frames when the user navigates to a
/// text field (Hulu search, App Store search, sign-in, etc.).
/// `CompanionConnection.sessionDidChangeKeyboardActive` flips
/// `keyboardActive`, and `RootView` swaps its content to `TextInputView`
/// — an inline field that lives *inside* the popover, iPhone-Remote-
/// style, rather than a separate floating window.
///
/// This manager's remaining job is small: when the ATV surfaces a text
/// field and the user isn't already looking at the popover, bring the
/// popover forward so the input is reachable. Everything else — the
/// TextField itself, focus, dismissal on `keyboardActive` going false —
/// is `RootView` / `TextInputView` territory.
@MainActor
final class TextInputWindowManager: NSObject {
    static let shared = TextInputWindowManager()

    private weak var connection: CompanionConnection?

    func setUp(connection: CompanionConnection) {
        self.connection = connection
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenNotification),
            name: KeyboardNotificationManager.openKeyboardSheetNotification,
            object: nil
        )
    }

    @objc private func handleOpenNotification() {
        // Route the "sheet please" signal into "open the menu-bar popover".
        // If it's already showing, this is a no-op inside openMainWindow.
        MenuBarController.shared.openMainWindow()
        KeyboardNotificationManager.shared.cancelAttention()
    }
}

// MARK: - Inline text-input view (hosted inside the popover)

/// The keyboard-input field the popover shows while `keyboardActive` is
/// true. Deliberately minimal: one `TextField` with a "Search" placeholder
/// and nothing else — mirrors the iPhone Apple TV Remote's input strip.
struct TextInputView: View {
    @ObservedObject var connection: CompanionConnection

    /// Local mirror of the text we've sent to the ATV. Diffing against the
    /// new textbox value is how we decide between `sendText` (append),
    /// `sendBackspace` (shrink), or a fresh send (paste-replace).
    @State private var text: String = ""
    @State private var previousText: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Search", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .task {
                // Slight defer avoids a first-layout focus race on
                // macOS 26 (same class of NSHostingView invalidation
                // loop we hit in the old floating-window path).
                try? await Task.sleep(nanoseconds: 50_000_000)
                focused = true
            }
            .onSubmit {
                // The TV closes the field itself via the remote's Menu /
                // Home button. Submit here just yields focus back so
                // arrow keys and the D-pad work again immediately.
                focused = false
            }
            .onChange(of: text) { newValue in
                handleChange(old: previousText, new: newValue)
                previousText = newValue
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
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
            // Same length, different content — paste-replace. Send
            // the new content as a fresh append; acceptable simplification.
            connection.sendText(new) { _ in }
        }
    }
}
