import Foundation

/// Shared UserDefaults keys. SwiftUI views read/write these via
/// `@AppStorage(PreferenceKey.xxx)`; non-view code (BLEManager) reads them
/// directly from UserDefaults.standard — same underlying storage either way.
enum PreferenceKey {
    static let showBatteryInMenuBar = "showBatteryInMenuBar"
    static let lowBatteryNotifications = "lowBatteryNotifications"
    static let lowBatteryThreshold = "lowBatteryThreshold"
}

extension UserDefaults {
    var showBatteryInMenuBar: Bool {
        object(forKey: PreferenceKey.showBatteryInMenuBar) == nil ? true : bool(forKey: PreferenceKey.showBatteryInMenuBar)
    }
    var lowBatteryNotifications: Bool {
        object(forKey: PreferenceKey.lowBatteryNotifications) == nil ? true : bool(forKey: PreferenceKey.lowBatteryNotifications)
    }
    var lowBatteryThreshold: Int {
        let v = integer(forKey: PreferenceKey.lowBatteryThreshold)
        return v == 0 ? 20 : v
    }
}
