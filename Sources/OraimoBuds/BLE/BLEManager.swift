import Foundation
import AppKit
import CoreBluetooth
import Combine

enum BLEConnectionState: Equatable {
    case disconnected
    case scanning
    case connecting
    case authenticating
    case ready
}

/// Owns the CoreBluetooth session with the earbuds: scanning, connecting,
/// running the RCSP auth handshake, and translating RCSP frames to/from
/// published state the SwiftUI layer observes. All command building/parsing
/// itself lives in RCSPProtocol.swift — this class is just the BLE plumbing
/// and the auth/state machine around it.
final class BLEManager: NSObject, ObservableObject {
    @Published private(set) var connectionState: BLEConnectionState = .disconnected {
        didSet { stateEnteredAt = Date() }
    }
    @Published private(set) var deviceName: String?
    @Published private(set) var battery: RCSP.BatteryInfo?
    @Published private(set) var ancMode: UInt8?
    @Published private(set) var eqMode: UInt8?
    @Published private(set) var eqGains: [Int8]?
    @Published private(set) var keySettings: [RCSP.KeySetting] = []
    @Published private(set) var lastError: String?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private enum AuthStep {
        case notStarted
        case waitingDeviceChallengeResponse(ourChallenge: [UInt8])
        case waitingDeviceChallenge
        case waitingFinalAck
        case done
    }
    private var authStep: AuthStep = .notStarted
    private var opCodeSnCounter: UInt8 = 1

    private func nextOpCodeSn() -> UInt8 {
        defer { opCodeSnCounter &+= 1 }
        return opCodeSnCounter
    }

    private var stateEnteredAt = Date()
    private var watchdogTimer: Timer?

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil)
        installStabilityHooks()
    }

    /// Two long-running-stability safeguards, since a menu bar utility is
    /// meant to sit connected for days/weeks, not just a test session:
    /// 1. A watchdog that force-restarts scanning if we've been stuck in a
    ///    non-terminal state (scanning/connecting/authenticating) for too
    ///    long — guards against CoreBluetooth wedging in some edge state.
    /// 2. A wake-from-sleep observer, since a connection is often silently
    ///    dropped across sleep and CoreBluetooth doesn't always reliably
    ///    fire a disconnect callback for that.
    private func installStabilityHooks() {
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkWatchdog()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleSystemWake()
        }
    }

    private func checkWatchdog() {
        guard connectionState != .ready, connectionState != .disconnected else { return }
        let stuckFor = Date().timeIntervalSince(stateEnteredAt)
        guard stuckFor > 45 else { return }
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        reconnectAfterDisconnect()
    }

    private func handleSystemWake() {
        guard connectionState != .ready else { return }
        reconnectAfterDisconnect()
    }

    // MARK: - Public commands

    func setAncMode(_ mode: UInt8) {
        send(RCSP.buildSetAncModeCmd(mode: mode, opCodeSn: nextOpCodeSn()))
    }

    /// `presetId` 0/1/2/3/4/5/8 are named presets (Standard/Bass/Rock/Jazz/
    /// Vocal/Treble/Balance — see EqPreset.swift): the device applies its
    /// own internal gain table for these and ignores whatever gain bytes
    /// accompany the command (confirmed live), so `gains` only matters for
    /// `presetId=6` (MODE_CUSTOM, from EqInfo.java) — the one mode that
    /// actually stores and applies arbitrary per-band gains.
    func setEqPreset(_ presetId: UInt8, gains: [Int8] = Array(repeating: 0, count: 10)) {
        send(RCSP.buildSelectEqPresetCmd(presetId: presetId, gains: gains, opCodeSn: nextOpCodeSn()))
    }

    /// Unlike ANC/EQ, the device does NOT push an unsolicited update after a
    /// key-settings change (confirmed empirically) — without an explicit
    /// follow-up GET, `keySettings` would stay stale until the user hit
    /// Refresh themselves. Mirrors the CLI test that validated this SET.
    func setKeySetting(side: UInt8, action: UInt8, function: UInt8) {
        let setting = RCSP.KeySetting(keyNum: side, action: action, function: function)
        send(RCSP.buildSetKeySettingsCmd([setting], opCodeSn: nextOpCodeSn()))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.send(RCSP.buildGetKeySettingsCmd(opCodeSn: self.nextOpCodeSn()))
        }
    }

    func refreshAll() {
        send(RCSP.buildGetBatteryAdvCmd(opCodeSn: nextOpCodeSn()))
        send(RCSP.buildGetCurrentAncModeCmd(opCodeSn: nextOpCodeSn()))
        send(RCSP.buildGetEqCmd(opCodeSn: nextOpCodeSn()))
        send(RCSP.buildGetKeySettingsCmd(opCodeSn: nextOpCodeSn()))
    }

    private func send(_ bytes: [UInt8]) {
        guard connectionState == .ready, let peripheral, let writeChar else { return }
        peripheral.writeValue(Data(bytes), for: writeChar, type: .withoutResponse)
    }

    private func log(_ s: String) {
        print("[BLE] \(s)")
    }

    private var lowBatteryNotified: Set<String> = []

    /// Notifies once per side when it first drops below the threshold, and
    /// resets that side's "already notified" flag once it goes back above
    /// (e.g. after a recharge) so a future drop notifies again.
    private func checkLowBattery(_ info: RCSP.BatteryInfo) {
        guard UserDefaults.standard.lowBatteryNotifications else { return }
        let threshold = UInt8(UserDefaults.standard.lowBatteryThreshold)
        let sides: [(String, UInt8?, Bool)] = [
            ("Left earbud", info.leftPercent, info.leftCharging),
            ("Right earbud", info.rightPercent, info.rightCharging),
            ("Case", info.casePercent, info.caseCharging),
        ]
        for (name, percent, charging) in sides {
            guard let percent, !charging else { continue }
            if percent <= threshold {
                if !lowBatteryNotified.contains(name) {
                    lowBatteryNotified.insert(name)
                    NotificationManager.shared.postLowBattery(side: name, percent: percent)
                }
            } else {
                lowBatteryNotified.remove(name)
            }
        }
    }

    private func reconnectAfterDisconnect() {
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        authStep = .notStarted
        connectionState = .scanning
        central.scanForPeripherals(withServices: [RCSP.serviceUUID], options: nil)
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            connectionState = .scanning
            central.scanForPeripherals(withServices: [RCSP.serviceUUID], options: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.peripheral == nil else { return }
                central.scanForPeripherals(withServices: nil, options: nil)
            }
        case .poweredOff:
            connectionState = .disconnected
            lastError = "Bluetooth is off"
        case .unauthorized:
            connectionState = .disconnected
            lastError = "Bluetooth permission not granted"
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let matchesService = advertisedServices.contains(RCSP.serviceUUID)
        let matchesName = name.lowercased().contains("oraimo") || name.lowercased().contains("spacebuds")
        guard matchesService || matchesName else { return }
        self.peripheral = peripheral
        deviceName = peripheral.name
        connectionState = .connecting
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([RCSP.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        lastError = "connect failed: \(error?.localizedDescription ?? "?")"
        reconnectAfterDisconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        reconnectAfterDisconnect()
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == RCSP.serviceUUID }) else {
            lastError = "service 0xAE00 not found: \(error?.localizedDescription ?? "?")"
            return
        }
        peripheral.discoverCharacteristics([RCSP.writeCharUUID, RCSP.notifyCharUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            if c.uuid == RCSP.writeCharUUID { writeChar = c }
            if c.uuid == RCSP.notifyCharUUID { notifyChar = c }
        }
        guard writeChar != nil, let notifyChar else {
            lastError = "missing characteristics"
            return
        }
        connectionState = .authenticating
        peripheral.setNotifyValue(true, for: notifyChar)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            lastError = "failed to subscribe: \(error!.localizedDescription)"
            return
        }
        // Mirrors device timing observed empirically (RCSP auth needs a
        // beat after notifications are enabled before it responds).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.startAuthHandshake()
        }
    }

    private func startAuthHandshake() {
        guard let peripheral, let writeChar else { return }
        peripheral.writeValue(Data(RCSP.resetAuthFlagCmd), for: writeChar, type: .withoutResponse)

        let ourChallenge = RCSPCrypto.randomChallenge()
        authStep = .waitingDeviceChallengeResponse(ourChallenge: ourChallenge)
        peripheral.writeValue(Data(ourChallenge), for: writeChar, type: .withoutResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == RCSP.notifyCharUUID, let data = characteristic.value else { return }
        let bytes = [UInt8](data)

        switch authStep {
        case .waitingDeviceChallengeResponse(let ourChallenge):
            guard bytes.count == 17, bytes[0] == 0x01,
                  let expected = RCSPCrypto.encrypt(ourChallenge), expected == bytes else {
                lastError = "auth: device challenge-response verification failed"
                return
            }
            authStep = .waitingDeviceChallenge
            peripheral.writeValue(Data(RCSP.authOkPayload), for: writeChar!, type: .withoutResponse)

        case .waitingDeviceChallenge:
            guard bytes.count == 17, bytes[0] == 0x00, let response = RCSPCrypto.encrypt(bytes) else {
                lastError = "auth: unexpected frame waiting for device's challenge"
                return
            }
            authStep = .waitingFinalAck
            peripheral.writeValue(Data(response), for: writeChar!, type: .withoutResponse)

        case .waitingFinalAck:
            guard RCSP.isAuthOk(bytes) else {
                lastError = "auth: final ack mismatch"
                return
            }
            authStep = .done
            connectionState = .ready
            lastError = nil
            refreshAll()

        case .done, .notStarted:
            guard let parsed = RCSP.parseFrame(bytes) else { return }
            applyParsedFrame(parsed)
        }
    }

    /// Both responses to our own GETs and unsolicited device pushes
    /// (opcode 9/194) carry the same payload shapes, so both update the
    /// published state the same way — this is how the UI stays live
    /// without polling.
    private func applyParsedFrame(_ parsed: RCSP.ParsedFrame) {
        if parsed.opcode == RCSP.Opcode.advGetInfo.rawValue || parsed.opcode == RCSP.Opcode.advNotify.rawValue {
            for (type, data) in RCSP.parseAdvInfoTLVs(parsed.paramData) {
                if type == UInt8(RCSP.AdvInfoBit.batteryQuantity.rawValue) {
                    let info = RCSP.parseBatteryInfo(data)
                    battery = info
                    checkLowBattery(info)
                } else if type == UInt8(RCSP.AdvInfoBit.keySettings.rawValue) {
                    keySettings = RCSP.parseKeySettings(data)
                }
            }
        } else if parsed.opcode == RCSP.Opcode.getSysInfo.rawValue || parsed.opcode == RCSP.Opcode.notifySysInfo.rawValue,
                  parsed.paramData.first == RCSP.FunctionGroup.public.rawValue {
            let attrs = Array(parsed.paramData.dropFirst())
            guard attrs.count >= 2 else { return }
            let type = attrs[1]
            let value = Array(attrs.dropFirst(2))
            if type == 13, value.count == 9 { // CURRENT_NOISE_MODE
                ancMode = value[0]
            } else if type == 4, value.count >= 11 { // EQ
                eqMode = value[0]
                eqGains = value[1...10].map { Int8(bitPattern: $0) }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { lastError = "write error: \(error.localizedDescription)" }
    }
}

extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
