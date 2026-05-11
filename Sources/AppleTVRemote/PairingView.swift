import SwiftUI
import AppleTVProtocol

/// First-run / disconnected UI. Lists discovered Apple TVs; tapping one
/// initiates pairing via `CompanionConnection.wakeAndConnect`. When the
/// connection transitions to `.awaitingPairingPin`, shows a PIN entry field.
struct PairingView: View {
    @EnvironmentObject private var connection: CompanionConnection
    @EnvironmentObject private var discovery: DeviceDiscovery
    @EnvironmentObject private var autoConnect: AutoConnectStore

    var body: some View {
        VStack(spacing: 12) {
            header
            Spacer(minLength: 0)
            content
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: RemoteTheme.popoverWidth, height: RemoteTheme.popoverHeight)
    }

    private var header: some View {
        VStack(spacing: 2) {
            Image(systemName: "appletv")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
            Text("Apple TV Remote")
                .font(.callout.weight(.semibold))
            Text(subheadline)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var subheadline: String {
        switch connection.state {
        case .awaitingPairingPin: return "Enter the PIN shown on the Apple TV"
        case .connecting:         return "Connecting…"
        case .waking:             return "Waking Apple TV…"
        case .error:              return "Connection error"
        default:                  return "Pair a device to get started"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch connection.state {
        case .awaitingPairingPin:
            PinEntryView { connection.submitPairingPin($0) }
        case .connecting, .waking:
            centeredSpinner(connection.state == .waking ? "Waking…" : "Connecting…")
        case .error(let message):
            errorView(message)
        case .disconnected, .connected:
            // .connected here would be a transient race; RootView usually
            // routes to RemoteView. .disconnected = pick a device.
            deviceList
        }
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if discovery.devices.isEmpty {
                VStack(spacing: 10) {
                    Text("Looking for Apple TVs…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView().controlSize(.small)
                }
                .frame(maxWidth: .infinity)
            } else {
                Text("Tap a device to pair")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(discovery.devices) { device in
                    deviceRow(device)
                }
            }
        }
    }

    private func deviceRow(_ device: AppleTVDevice) -> some View {
        Button {
            connection.wakeAndConnect(to: device)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "tv")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.caption.weight(.medium)).lineLimit(1)
                    Text(device.host ?? "discovering…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if device.isPaired {
                    Text("paired")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                connection.disconnect()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private func centeredSpinner(_ label: String) -> some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - PIN entry

private struct PinEntryView: View {
    let onSubmit: (String) -> Void

    @State private var pin: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            Text("Enter the PIN shown on your Apple TV")
                .font(.caption)
                .multilineTextAlignment(.center)
            TextField("1234", text: $pin)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .focused($focused)
                .onAppear { focused = true }
                .onSubmit(submit)
                .onChange(of: pin) { new in
                    pin = String(new.filter(\.isNumber).prefix(4))
                    if pin.count == 4 { submit() }
                }
            Button("Submit", action: submit)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(pin.count < 4)
        }
    }

    private func submit() {
        guard pin.count == 4 else { return }
        onSubmit(pin)
    }
}
