import Foundation
import AppKit
import CoreBluetooth
import IOBluetooth
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
    /// Model identified from the advertisement's product ID, nil if the pid
    /// isn't in `EarbudsModel.known` (the app still tries to drive it).
    @Published private(set) var model: EarbudsModel?
    /// nil = not known yet. Set from the model table when the pid is known,
    /// otherwise learned from the device's answer to the noise-mode GET (an
    /// empty attribute list means no ANC hardware).
    @Published private(set) var ancSupported: Bool?
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
    /// opCodeSn of the last noise-mode GET, to recognise its (possibly empty) reply.
    private var ancQuerySn: UInt8?
    /// Peripherals that matched the scan filter but turned out not to expose
    /// the RCSP service (e.g. a Bluetrum-based Oraimo product): skipped on
    /// later scans so we don't keep reconnecting to them.
    private var ignoredPeripherals: Set<UUID> = []

    /// Levels (8 bytes) of each ANC mode, from the noise-mode list, so a mode
    /// switch re-sends that mode's own levels instead of overwriting them.
    private var ancLevels: [UInt8: [UInt8]] = [:]

    /// An Oraimo device seen nearby that is paired with this Mac, for the
    /// popover's device menu.
    struct NearbyDevice: Identifiable, Equatable {
        let id: UUID
        let name: String
        /// Its classic (audio) connection to this Mac is up right now.
        let isAudioConnected: Bool
        let rssi: Int
    }
    @Published private(set) var nearbyDevices: [NearbyDevice] = []
    @Published private(set) var connectedDeviceID: UUID?

    /// Several Oraimo devices can be advertising nearby (seen live: five at
    /// once, and a neighbour's BoomPop authenticated fine — same JieLi
    /// stack). So only devices PAIRED WITH THIS MAC are ever used: the
    /// beacon's classic address must be in IOBluetooth's paired list.
    /// Among those, selection order:
    /// 1. the device the user picked in the menu (`preferredPeripheralID`),
    /// 2. the one this Mac's audio is connected to right now,
    /// 3. after a short listening window, the strongest signal.
    private struct Candidate {
        let peripheral: CBPeripheral
        let bleName: String?
        let beacon: EarbudsModel.Beacon
        let pairedName: String?
        let isAudioConnected: Bool
        var rssi: Int
        var lastSeen: Date
    }
    /// Paired candidates seen recently (kept across scans for the menu).
    private var nearby: [UUID: Candidate] = [:]
    /// Ids seen during the current scan, i.e. actually in range now.
    private var seenThisScan: Set<UUID> = []
    private var loggedUnpaired: Set<UUID> = []
    private var selectionWork: DispatchWorkItem?
    private var switchTarget: Candidate?
    private static let selectionWindow: TimeInterval = 4

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
        let levels = ancLevels[mode] ?? RCSP.defaultAncLevels
        send(RCSP.buildSetAncModeCmd(mode: mode, levels: levels, opCodeSn: nextOpCodeSn()))
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

    /// Switches to another paired device from the menu, and remembers the
    /// choice so later reconnects prefer it.
    func selectDevice(_ id: UUID) {
        guard id != peripheral?.identifier, let target = nearby[id] else { return }
        UserDefaults.standard.preferredPeripheralID = id
        log("user selected '\(target.pairedName ?? target.bleName ?? "?")'")
        if let current = peripheral {
            switchTarget = target
            central.cancelPeripheralConnection(current) // didDisconnect → connect(to: switchTarget)
        } else {
            connect(to: target)
        }
    }

    /// Short scan to refresh the device menu while connected (scanning is
    /// otherwise stopped once connected, to spare battery).
    func refreshNearbyDevices() {
        guard let central, central.state == .poweredOn, connectionState == .ready else { return }
        central.scanForPeripherals(withServices: nil, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.connectionState == .ready else { return }
            self.central.stopScan()
        }
    }

    func refreshAll() {
        send(RCSP.buildGetBatteryAdvCmd(opCodeSn: nextOpCodeSn()))
        if ancSupported != false {
            let sn = nextOpCodeSn()
            ancQuerySn = sn
            send(RCSP.buildGetCurrentAncModeCmd(opCodeSn: sn))
            send(RCSP.buildGetAncModeListCmd(opCodeSn: nextOpCodeSn()))
        }
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

    private func resetSession() {
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        authStep = .notStarted
        ancQuerySn = nil
        connectedDeviceID = nil
        battery = nil
        ancMode = nil
        eqMode = nil
        eqGains = nil
        keySettings = []
    }

    private func reconnectAfterDisconnect() {
        resetSession()
        startScan()
    }

    /// Scans without a service filter: the SpaceBuds Neo doesn't list 0xAE00
    /// in its advertisement (only the Neo+ does), so a service-filtered scan
    /// would never find it. Filtering happens in `didDiscover` instead.
    private func startScan() {
        seenThisScan = []
        selectionWork?.cancel()
        selectionWork = nil
        connectionState = .scanning
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    private func pickBestCandidate() {
        selectionWork = nil
        guard peripheral == nil else { return }
        let inRange = seenThisScan.compactMap { nearby[$0] }
        let preferred = UserDefaults.standard.preferredPeripheralID
        let best = inRange.first { $0.peripheral.identifier == preferred }
            ?? inRange.first { $0.isAudioConnected }
            ?? inRange.max { $0.rssi < $1.rssi }
        guard let best else { return }
        log("picked '\(best.pairedName ?? best.bleName ?? "?")' among \(inRange.count) paired device(s) in range")
        connect(to: best)
    }

    /// Devices paired with this Mac, keyed by normalised classic address
    /// ("AA:BB:CC:DD:EE:FF"), with their macOS name and audio-connection state.
    private static func pairedDevices() -> [String: (name: String?, connected: Bool)] {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        var result: [String: (name: String?, connected: Bool)] = [:]
        for d in devices {
            guard let address = d.addressString else { continue }
            result[EarbudsModel.normalizedAddress(address)] = (d.name, d.isConnected())
        }
        return result
    }

    private func connect(to c: Candidate) {
        central.stopScan()
        selectionWork?.cancel()
        selectionWork = nil
        resetSession()
        peripheral = c.peripheral
        connectedDeviceID = c.peripheral.identifier
        ancLevels = [:]
        model = EarbudsModel.model(forPID: c.beacon.pid)
        ancSupported = model?.hasANC
        deviceName = model.map { "Oraimo \($0.name)" }
            ?? c.pairedName
            ?? EarbudsModel.displayName(fromBLEName: c.bleName).map { "Oraimo \($0)" }
        connectionState = .connecting
        central.connect(c.peripheral, options: nil)
    }

    private func publishNearby() {
        let cutoff = Date().addingTimeInterval(-120)
        nearbyDevices = nearby.values
            .filter { $0.lastSeen > cutoff || $0.peripheral.identifier == connectedDeviceID }
            .map { c in
                let modelName = EarbudsModel.model(forPID: c.beacon.pid).map { "Oraimo \($0.name)" }
                return NearbyDevice(
                    id: c.peripheral.identifier,
                    name: modelName ?? c.pairedName ?? EarbudsModel.displayName(fromBLEName: c.bleName) ?? "Oraimo device",
                    isAudioConnected: c.isAudioConnected,
                    rssi: c.rssi
                )
            }
            .sorted { ($0.isAudioConnected ? 1 : 0, $0.rssi) > ($1.isAudioConnected ? 1 : 0, $1.rssi) }
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScan()
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
        let id = peripheral.identifier
        guard !ignoredPeripherals.contains(id) else { return }
        // Only Oraimo beacons carrying a classic address can be checked
        // against this Mac's paired devices; anything else is ignored.
        guard let beacon = EarbudsModel.beacon(fromManufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data),
              let address = beacon.classicAddress else { return }
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let paired = Self.pairedDevices()[address] else {
            if loggedUnpaired.insert(id).inserted {
                log("ignoring unpaired '\(name ?? "?")' pid=\(beacon.pid)")
            }
            return
        }
        let rssi = RSSI.intValue == 127 ? -127 : RSSI.intValue // 127 = unavailable
        let candidate = Candidate(peripheral: peripheral, bleName: name, beacon: beacon, pairedName: paired.name,
                                  isAudioConnected: paired.connected, rssi: rssi, lastSeen: Date())
        if nearby[id] == nil {
            log("paired device '\(paired.name ?? name ?? "?")' pid=\(beacon.pid) audio=\(paired.connected) rssi=\(rssi)")
        }
        nearby[id] = candidate
        seenThisScan.insert(id)
        publishNearby()

        guard self.peripheral == nil, switchTarget == nil else { return } // connected: menu refresh only

        let preferred = UserDefaults.standard.preferredPeripheralID
        if id == preferred || (preferred == nil && paired.connected) {
            connect(to: candidate)
            return
        }
        if selectionWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.pickBestCandidate() }
            selectionWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.selectionWindow, execute: work)
        }
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
        if let target = switchTarget {
            switchTarget = nil
            connect(to: target)
        } else {
            reconnectAfterDisconnect()
        }
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == RCSP.serviceUUID }) else {
            log("no RCSP service on '\(peripheral.name ?? "?")', ignoring it")
            ignoredPeripherals.insert(peripheral.identifier)
            central.cancelPeripheralConnection(peripheral) // didDisconnect → rescan
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
            log("ready: \(deviceName ?? "?") model=\(model?.name ?? "unknown") ancSupported=\(String(describing: ancSupported))")
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
            if parsed.isResponse, parsed.opCodeSn == ancQuerySn {
                ancQuerySn = nil
                let hasNoiseAttr = attrs.count >= 2 && attrs[1] == 13
                if ancSupported == nil { ancSupported = hasNoiseAttr }
                log("noise-mode attribute present=\(hasNoiseAttr), ancSupported=\(String(describing: ancSupported))")
            }
            guard attrs.count >= 2 else { return }
            let type = attrs[1]
            let value = Array(attrs.dropFirst(2))
            if type == 13, value.count == 9 { // CURRENT_NOISE_MODE
                ancMode = value[0]
                ancLevels[value[0]] = Array(value[1...8])
            } else if type == 14 { // ALL_NOISE_MODE (supported modes + their levels)
                ancLevels.merge(RCSP.parseAncModeList(value)) { _, new in new }
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
