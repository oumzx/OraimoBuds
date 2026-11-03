import Foundation

/// Shared UserDefaults keys. SwiftUI views read/write these via
/// `@AppStorage(PreferenceKey.xxx)`; non-view code (BLEManager) reads them
/// directly from UserDefaults.standard — same underlying storage either way.
enum PreferenceKey {
    static let showBatteryInMenuBar = "showBatteryInMenuBar"
    static let lowBatteryNotifications = "lowBatteryNotifications"
    static let lowBatteryThreshold = "lowBatteryThreshold"
    /// CoreBluetooth identifier of the earbuds we bonded to, so we don't
    /// switch to a neighbour's Oraimo device on the next scan.
    static let rememberedPeripheralID = "rememberedPeripheralID"
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
    var rememberedPeripheralID: UUID? {
        get { string(forKey: PreferenceKey.rememberedPeripheralID).flatMap(UUID.init(uuidString:)) }
        set { set(newValue?.uuidString, forKey: PreferenceKey.rememberedPeripheralID) }
    }
}
