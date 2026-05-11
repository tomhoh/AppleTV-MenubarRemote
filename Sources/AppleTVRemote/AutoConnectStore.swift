import Foundation
import Combine

/// Tracks which Apple TVs should be auto-reconnected on launch / when they
/// become reachable again on the network. Backed by UserDefaults.
final class AutoConnectStore: ObservableObject {
    private let key = "com.adhir.appletv-remote.autoConnectDeviceIDs"

    @Published private(set) var deviceIDs: Set<String>

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "com.adhir.appletv-remote.autoConnectDeviceIDs") ?? []
        deviceIDs = Set(saved)
    }

    func isEnabled(_ id: String) -> Bool { deviceIDs.contains(id) }

    func setEnabled(_ id: String, _ on: Bool) {
        if on { deviceIDs.insert(id) } else { deviceIDs.remove(id) }
        UserDefaults.standard.set(Array(deviceIDs), forKey: key)
    }
}
