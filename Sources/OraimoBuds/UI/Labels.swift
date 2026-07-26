import Foundation

/// Human-readable labels for the raw RCSP byte values, from the
/// decompiled Oraimo app's enums (DeviceSide / JLUiAction / JLUiFunction).
enum Labels {
    static func side(_ v: UInt8) -> String {
        switch v {
        case 0: return "All"
        case 1: return "Left"
        case 2: return "Right"
        case 3: return "Case"
        case 4: return "Left (call)"
        case 5: return "Right (call)"
        default: return "?(\(v))"
        }
    }

    static func action(_ v: UInt8) -> String {
        switch v {
        case 0: return "None"
        case 1: return "Click"
        case 2: return "Double-click"
        case 3: return "Triple-click"
        case 4: return "Long press"
        case 5: return "Long press x3"
        default: return "?(\(v))"
        }
    }

    static func function(_ v: UInt8) -> String {
        switch v {
        case 0: return "None"
        case 2: return "Voice assistant"
        case 3: return "Previous"
        case 4: return "Next"
        case 5: return "Play/Pause"
        case 8: return "Recall"
        case 9: return "Volume up"
        case 10: return "Volume down"
        case 11: return "Game mode"
        case 255: return "ANC cycle"
        default: return "?(\(v))"
        }
    }

    static func ancMode(_ v: UInt8?) -> String {
        switch v {
        case 0: return "Off"
        case 1: return "Noise Cancelling"
        case 2: return "Transparency"
        default: return "Unknown"
        }
    }
}
