import Foundation
import CRCSPCrypto

/// BLE identifiers and RCSP envelope/command building, decoded from the
/// Oraimo "oraimo sound" Android app's decompiled sources (com.jieli.bluetooth
/// SDK / RCSP protocol). See project notes for the full derivation.
enum RCSP {
    static let serviceUUID = CBUUIDLiteral("0000AE00-0000-1000-8000-00805F9B34FB")
    static let writeCharUUID = CBUUIDLiteral("0000AE01-0000-1000-8000-00805F9B34FB")
    static let notifyCharUUID = CBUUIDLiteral("0000AE02-0000-1000-8000-00805F9B34FB")

    /// Literal bytes from `RcspAuth.getResetAuthFlagCmdData()`: a fully
    /// enveloped command (magic FE DC BA, flags 0xC0, opcode 6, paramLen 2,
    /// paramData 00 01, footer EF) that resets the device's auth state
    /// before a challenge/response exchange starts.
    static let resetAuthFlagCmd: [UInt8] = [0xFE, 0xDC, 0xBA, 0xC0, 0x06, 0x00, 0x02, 0x00, 0x01, 0xEF]

    /// Ack payload sent by both sides after validating the other's
    /// encrypted challenge response: byte 0x02 followed by ASCII "pass".
    static let authOkPayload: [UInt8] = [0x02, 0x70, 0x61, 0x73, 0x73]

    static func isAuthOk(_ bytes: [UInt8]) -> Bool {
        bytes.count >= authOkPayload.count && Array(bytes.prefix(authOkPayload.count)) == authOkPayload
    }

    /// function-group byte for GetSysInfo/SetSysInfo commands.
    enum FunctionGroup: UInt8 {
        case bt = 0
        case music = 1
        case rtc = 2
        case aux = 3
        case fm = 4
        case light = 5
        case fmtx = 6
        case eq = 7
        case spdif = 8
        case pcSlave = 9
        case lowPower = 22
        case `public` = 0xFF // -1 as unsigned byte
    }

    enum Opcode: UInt8 {
        case getSysInfo = 7
        case setSysInfo = 8
        case notifySysInfo = 9 // observed on unsolicited device pushes
        // ADV_INFO family (com.jieli.bluetooth.constant.Command): a
        // separate command family from GetSysInfo/SetSysInfo, used for
        // battery/device-name/key-settings/led-settings/etc. Confirmed:
        // the mystery 0xC2 push we saw earlier is CMD_ADV_DEVICE_NOTIFY.
        case advSetInfo = 192 // CMD_ADV_SETTINGS
        case advGetInfo = 193 // CMD_ADV_GET_INFO
        case advNotify = 194 // CMD_ADV_DEVICE_NOTIFY (unsolicited push)
    }

    /// ADV_TYPE_* from AttrAndFunCode.java, used as bit positions in the
    /// ADV_INFO family's mask (separate numbering from PublicAttrBit).
    enum AdvInfoBit: Int {
        case batteryQuantity = 0
        case deviceName = 1
        case keySettings = 2
        case ledSettings = 3
        case micChannelSettings = 4
        case workMode = 5
        case vidUidPid = 6
        case inEarCheck = 8
        case language = 9
        case ancModeList = 10
    }

    /// SYS_INFO_ATTR_* bit positions used with the PUBLIC function group,
    /// from AttrAndFunCode.java.
    enum PublicAttrBit: Int {
        case battery = 0
        case eq = 4
        case eqPresetValue = 12
        case currentNoiseMode = 13 // ANC on/off/transparency
        case allNoiseMode = 14 // device's supported ANC mode list
    }

    /// Builds a full RCSP frame: FE DC BA [flags] [opcode] [paramLen BE16]
    /// [status] [opCodeSn] [paramData] EF.
    /// - Parameters:
    ///   - hasResponse: true for GET commands (we want a reply).
    static func buildFrame(opcode: Opcode, opCodeSn: UInt8, hasResponse: Bool, paramData: [UInt8]) -> [UInt8] {
        // Confirmed against the known-good literal `resetAuthFlagCmd`
        // (FE DC BA C0 06 00 02 00 01 EF, flags=0xC0): outgoing/command
        // frames set bit7 (type=TYPE_COMMAND) unconditionally, bit6 only
        // when a response is wanted, and carry NO status byte (that field
        // only appears on type=0/TYPE_RESPONSE frames coming back from the
        // device) — body is just [opCodeSn] + paramData.
        let flags: UInt8 = 0x80 | (hasResponse ? 0x40 : 0)
        let body = [opCodeSn] + paramData
        var frame: [UInt8] = [0xFE, 0xDC, 0xBA, flags, opcode.rawValue]
        let paramLen = UInt16(body.count)
        frame.append(UInt8(paramLen >> 8))
        frame.append(UInt8(paramLen & 0xFF))
        frame.append(contentsOf: body)
        frame.append(0xEF)
        return frame
    }

    /// AttrBean TLV: [len+1][type][data...].
    static func attrBean(type: UInt8, data: [UInt8]) -> [UInt8] {
        [UInt8(data.count + 1), type] + data
    }

    /// Builds a GET_SYS_INFO command requesting the given attribute bitmask
    /// within a function group (e.g. .public for battery/EQ/ANC).
    static func buildGetSysInfoCmd(group: FunctionGroup, mask: UInt32, opCodeSn: UInt8) -> [UInt8] {
        var paramData: [UInt8] = [group.rawValue]
        paramData.append(UInt8(mask >> 24))
        paramData.append(UInt8((mask >> 16) & 0xFF))
        paramData.append(UInt8((mask >> 8) & 0xFF))
        paramData.append(UInt8(mask & 0xFF))
        return buildFrame(opcode: .getSysInfo, opCodeSn: opCodeSn, hasResponse: true, paramData: paramData)
    }

    static func buildGetBatteryCmd(opCodeSn: UInt8) -> [UInt8] {
        buildGetSysInfoCmd(group: .public, mask: 1 << PublicAttrBit.battery.rawValue, opCodeSn: opCodeSn)
    }

    static func buildGetCurrentAncModeCmd(opCodeSn: UInt8) -> [UInt8] {
        buildGetSysInfoCmd(group: .public, mask: 1 << PublicAttrBit.currentNoiseMode.rawValue, opCodeSn: opCodeSn)
    }

    static func buildGetEqCmd(opCodeSn: UInt8) -> [UInt8] {
        buildGetSysInfoCmd(group: .public, mask: 1 << PublicAttrBit.eq.rawValue, opCodeSn: opCodeSn)
    }

    /// EQ bands: 31/63/125/250/500/1000/2000/4000/8000/16000 Hz
    /// (BluetoothConstant.DEFAULT_EQ_FREQS). Wire format: `[modeId][10
    /// signed gain bytes]` (11 bytes).
    ///
    /// `modeId` is a named-value enum (`EqInfo.java`): 0=Standard,
    /// 1=Rock, 2=Popular, 3=Classical, 4=Jazz, 5=Country, **6=Custom**.
    /// Confirmed live: modes 0-5 make the device apply its OWN internal
    /// gain table and ignore whatever gain bytes accompany the command;
    /// only mode 6 actually stores and applies the given per-band gains
    /// (round-tripped byte-for-byte against real hardware, including a
    /// full restore of the original gains afterwards).
    static func buildSelectEqPresetCmd(presetId: UInt8, gains: [Int8], opCodeSn: UInt8) -> [UInt8] {
        precondition(gains.count == 10)
        let data = [presetId] + gains.map { UInt8(bitPattern: $0) }
        let attr = attrBean(type: 4, data: data)
        let paramData: [UInt8] = [FunctionGroup.public.rawValue] + attr
        return buildFrame(opcode: .setSysInfo, opCodeSn: opCodeSn, hasResponse: true, paramData: paramData)
    }

    /// mode: 0 = Off, 1 = ANC (denoise), 2 = Transparency.
    /// leftMax/rightMax/leftCur/rightCur observed as 0x4000 (fixed, no
    /// adjustable ANC strength on this earbud model).
    static func buildSetAncModeCmd(mode: UInt8, opCodeSn: UInt8) -> [UInt8] {
        var voiceMode: [UInt8] = [mode]
        for _ in 0..<4 { voiceMode.append(0x40); voiceMode.append(0x00) }
        let attr = attrBean(type: 13, data: voiceMode)
        let paramData: [UInt8] = [FunctionGroup.public.rawValue] + attr
        return buildFrame(opcode: .setSysInfo, opCodeSn: opCodeSn, hasResponse: true, paramData: paramData)
    }

    // MARK: - ADV_INFO family (battery, gestures/key settings, ...)

    /// GetADVInfoParam's wire format is simpler than GetSysInfo's: just a
    /// 4-byte BE mask, no leading function-group byte.
    static func buildGetADVInfoCmd(mask: UInt32, opCodeSn: UInt8) -> [UInt8] {
        let paramData: [UInt8] = [
            UInt8(mask >> 24), UInt8((mask >> 16) & 0xFF), UInt8((mask >> 8) & 0xFF), UInt8(mask & 0xFF),
        ]
        return buildFrame(opcode: .advGetInfo, opCodeSn: opCodeSn, hasResponse: true, paramData: paramData)
    }

    static func buildGetBatteryAdvCmd(opCodeSn: UInt8) -> [UInt8] {
        buildGetADVInfoCmd(mask: 1 << AdvInfoBit.batteryQuantity.rawValue, opCodeSn: opCodeSn)
    }

    static func buildGetKeySettingsCmd(opCodeSn: UInt8) -> [UInt8] {
        buildGetADVInfoCmd(mask: 1 << AdvInfoBit.keySettings.rawValue, opCodeSn: opCodeSn)
    }

    /// SetADVInfoCmd's payload is a single packed TLV: [len][type][data...]
    /// (same len=dataLen+1 convention as AttrBean), built once at the top
    /// level — unlike GetSysInfo/SetSysInfo there's no per-entry TLV plus
    /// an outer function-group byte, just this one TLV wrapping whatever
    /// raw bytes belong to that ADV_TYPE.
    static func packLTV(type: UInt8, data: [UInt8]) -> [UInt8] {
        [UInt8(data.count + 1), type] + data
    }

    struct KeySetting {
        let keyNum: UInt8 // DeviceSide: 0=ALL,1=LEFT,2=RIGHT,3=CASE,4=LEFT_CALL,5=RIGHT_CALL
        let action: UInt8 // JLUiAction: 0=NONE,1=CLICK,2=DOUBLE_CLICK,3=TRIPLE_HIT,4=LONG_PRESS,5=LONG_PRESS_TRIPLE
        let function: UInt8 // JLUiFunction: 0=NONE,2=ASSISTANT,3=PREVIOUS,4=NEXT,5=PLAY_PAUSE,8=RECALL,9=VOL_UP,10=VOL_DOWN,11=GAME_MODE,255=ANC_SETTING
        var bytes: [UInt8] { [keyNum, action, function] }
    }

    /// JLUiFunction's assignable values (NONE excluded isn't needed — it's
    /// a valid "do nothing" choice too), for a gesture-editing picker.
    static let selectableFunctions: [UInt8] = [0, 2, 3, 4, 5, 8, 9, 10, 11, 255]

    static func buildSetKeySettingsCmd(_ settings: [KeySetting], opCodeSn: UInt8) -> [UInt8] {
        let raw = settings.flatMap(\.bytes)
        let paramData = packLTV(type: UInt8(AdvInfoBit.keySettings.rawValue), data: raw)
        return buildFrame(opcode: .advSetInfo, opCodeSn: opCodeSn, hasResponse: true, paramData: paramData)
    }

    struct BatteryInfo {
        let leftPercent: UInt8?
        let leftCharging: Bool
        let rightPercent: UInt8?
        let rightCharging: Bool
        let casePercent: UInt8?
        let caseCharging: Bool
    }

    /// Parses ADV_INFO paramData: a sequence of [len][type][data (len-1
    /// bytes)] TLVs (len includes the type byte, matching AttrBean/packLTV).
    static func parseAdvInfoTLVs(_ paramData: [UInt8]) -> [(type: UInt8, data: [UInt8])] {
        var result: [(UInt8, [UInt8])] = []
        var i = 0
        while i + 2 <= paramData.count {
            let len = Int(paramData[i])
            guard len >= 1, i + 1 + len <= paramData.count else { break }
            let type = paramData[i + 1]
            let data = Array(paramData[(i + 2)..<(i + 1 + len)])
            result.append((type, data))
            i += 1 + len
        }
        return result
    }

    static func parseBatteryInfo(_ data: [UInt8]) -> BatteryInfo {
        func decode(_ b: UInt8) -> (percent: UInt8, charging: Bool) { (b & 0x7F, (b & 0x80) != 0) }
        var left: (UInt8, Bool)?, right: (UInt8, Bool)?, caseB: (UInt8, Bool)?
        if data.count >= 1 { left = decode(data[0]) }
        if data.count >= 2 { right = decode(data[1]) }
        if data.count >= 3 { caseB = decode(data[2]) }
        return BatteryInfo(
            leftPercent: left?.0, leftCharging: left?.1 ?? false,
            rightPercent: right?.0, rightCharging: right?.1 ?? false,
            casePercent: caseB?.0, caseCharging: caseB?.1 ?? false
        )
    }

    static func parseKeySettings(_ data: [UInt8]) -> [KeySetting] {
        var result: [KeySetting] = []
        var i = 0
        while i + 3 <= data.count {
            result.append(KeySetting(keyNum: data[i], action: data[i + 1], function: data[i + 2]))
            i += 3
        }
        return result
    }

    /// Parses a received frame (as delivered by the 0xAE02 notify
    /// characteristic). Returns nil if the magic/footer don't match.
    ///
    /// Confirmed against real hardware (2026-07-26): responses to our own
    /// GET_SYS_INFO commands come back with flags bit7=0 (TYPE_RESPONSE)
    /// and DO include a status byte before opCodeSn; this correctly echoed
    /// back our own opCodeSn across three sequential commands and decoded
    /// the ANC-mode payload byte-for-byte. Unsolicited device-initiated
    /// pushes (not requested by us) were seen with bit7=1 and opcode 0xC2 —
    /// now identified as CMD_ADV_DEVICE_NOTIFY (Command.java), the ADV_INFO
    /// family's own unsolicited push, distinct from CMD_SYS_INFO_AUTO_UPDATE
    /// (opcode 9). Both carry no status byte.
    struct ParsedFrame {
        let isResponse: Bool
        let opcode: UInt8
        let status: UInt8?
        let opCodeSn: UInt8
        let paramData: [UInt8]
    }

    static func parseFrame(_ bytes: [UInt8]) -> ParsedFrame? {
        guard bytes.count >= 8,
              bytes[0] == 0xFE, bytes[1] == 0xDC, bytes[2] == 0xBA,
              bytes.last == 0xEF else { return nil }
        let flags = bytes[3]
        let opcode = bytes[4]
        let paramLen = Int(bytes[5]) << 8 | Int(bytes[6])
        guard bytes.count == 8 + paramLen else { return nil }
        let isResponse = (flags & 0x80) == 0

        let status: UInt8?
        let opCodeSnIndex: Int
        if isResponse {
            status = bytes[7]
            opCodeSnIndex = 8
        } else {
            status = nil
            opCodeSnIndex = 7
        }
        let opCodeSn = bytes[opCodeSnIndex]
        let paramDataStart = opCodeSnIndex + 1
        let paramData = Array(bytes[paramDataStart..<(bytes.count - 1)])
        return ParsedFrame(isResponse: isResponse, opcode: opcode, status: status, opCodeSn: opCodeSn, paramData: paramData)
    }
}

/// Thin wrapper so CBUUID doesn't need to be imported at the top of this
/// file (keeps this file CoreBluetooth-import-free for easy unit testing).
import CoreBluetooth
func CBUUIDLiteral(_ s: String) -> CBUUID { CBUUID(string: s) }

/// Swift-friendly wrapper over the extracted native crypto routine.
enum RCSPCrypto {
    static func load(soPath: String) -> Bool {
        soPath.withCString { rcsp_crypto_load($0) == 0 }
    }

    static func randomChallenge() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 17)
        rcsp_crypto_random_challenge(&out)
        return out
    }

    /// Encrypts a 17-byte challenge (marker + 16 payload bytes) and returns
    /// the 17-byte result (marker=1 + 16 encrypted bytes), or nil on error.
    static func encrypt(_ input: [UInt8]) -> [UInt8]? {
        guard input.count == 17 else { return nil }
        var out = [UInt8](repeating: 0, count: 17)
        let rc = input.withUnsafeBufferPointer { inPtr -> Int32 in
            out.withUnsafeMutableBufferPointer { outPtr -> Int32 in
                rcsp_crypto_encrypt(inPtr.baseAddress, outPtr.baseAddress)
            }
        }
        return rc == 0 ? out : nil
    }
}
