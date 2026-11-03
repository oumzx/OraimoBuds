import Foundation

/// Identifies which Oraimo earbuds model is advertising, from the BLE
/// manufacturer-specific data, and what that model supports.
///
/// Layout (from the official app's `AuthInfo.java`; CoreBluetooth keeps the
/// 2-byte company ID at the front):
/// `[cid LE16 = 0x0942][featureMask][pid LE16][classic BT address, 6 bytes
/// XOR 0xAD][...]`. The pid → model mapping comes from
/// `MyUtils.getDeviceTypeByPid` / `MyUtils.getDeviceName` in the same app;
/// the 0xAD obfuscation from `DeviceBeaconV3/V4.deobfuscateBtAddress`.
struct EarbudsModel: Equatable {
    let pid: UInt16
    let name: String
    /// Whether the model has active noise cancelling at all. The official app
    /// hides its noise-control section for the plain SpaceBuds Neo (type 323)
    /// and only shows it for the Neo+ variants (323P / 323MJL) and the
    /// SpaceBuds (type 630).
    let hasANC: Bool

    /// Bluetooth company ID Oraimo's JieLi-based earbuds advertise with
    /// (`ABEarbuds.MANUFACTURER_ID = 2370`).
    static let oraimoCompanyID: UInt16 = 0x0942

    /// Models known to speak the RCSP command set this app uses.
    static let known: [EarbudsModel] = [
        // oraimo SpaceBuds (type 630). Confirmed live 2026-11-03 on pid 32
        // ("630_Normal"): auth, battery, ANC read/write, EQ, gestures. The
        // other pids are variants of the same product in the official app.
        EarbudsModel(pid: 21, name: "SpaceBuds", hasANC: true),
        EarbudsModel(pid: 25, name: "SpaceBuds", hasANC: true), // 630_Game
        EarbudsModel(pid: 32, name: "SpaceBuds", hasANC: true), // 630_Normal
        EarbudsModel(pid: 33, name: "SpaceBuds", hasANC: true), // 630_Game_Batch
        // oraimo SpaceBuds Neo (type 323). Confirmed live 2026-11-03: auth,
        // battery, EQ, gestures work; noise-mode GET comes back empty.
        EarbudsModel(pid: 34, name: "SpaceBuds Neo", hasANC: false),
        // oraimo SpaceBuds Neo+ (OTW-323P), the app's original target.
        EarbudsModel(pid: 37, name: "SpaceBuds Neo+", hasANC: true),
        EarbudsModel(pid: 41, name: "SpaceBuds Neo+", hasANC: true), // 323MJL
    ]

    static func model(forPID pid: UInt16) -> EarbudsModel? {
        known.first { $0.pid == pid }
    }

    /// What an Oraimo advertisement tells us before connecting.
    struct Beacon: Equatable {
        let pid: UInt16
        /// Classic Bluetooth address of the earbuds ("82:07:20:00:D2:B6"),
        /// the one macOS shows for the audio connection. nil if too short.
        let classicAddress: String?
    }

    /// Returns nil unless `data` is Oraimo manufacturer data.
    static func beacon(fromManufacturerData data: Data?) -> Beacon? {
        guard let data, data.count >= 5 else { return nil }
        let b = [UInt8](data)
        let cid = UInt16(b[0]) | UInt16(b[1]) << 8
        guard cid == oraimoCompanyID else { return nil }
        let pid = UInt16(b[3]) | UInt16(b[4]) << 8
        var address: String?
        if b.count >= 11 {
            address = b[5...10].map { String(format: "%02X", $0 ^ 0xAD) }.joined(separator: ":")
        }
        return Beacon(pid: pid, classicAddress: address)
    }

    /// Normalises "82-07-20-00-d2-b6" (IOBluetooth) to "82:07:20:00:D2:B6".
    static func normalizedAddress(_ s: String) -> String {
        s.uppercased().replacingOccurrences(of: "-", with: ":")
    }

    /// Turns the BLE name ("oraimo SpaceBuds Neo BLE") into a display name.
    static func displayName(fromBLEName name: String?) -> String? {
        guard var name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        if name.hasSuffix(" BLE") { name.removeLast(4) }
        if name.lowercased().hasPrefix("oraimo ") { name.removeFirst(7) }
        return name
    }
}
