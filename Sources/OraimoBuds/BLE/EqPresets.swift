import Foundation

/// Real named EQ presets, extracted from the Oraimo app's own
/// `com.transsion.oraimosound.constant.EqPreset` enum (NOT made up). Each
/// `wireId` is the presetId byte sent in the SET_SYS_INFO(EQ) command —
/// selecting a named preset makes the device apply its OWN internal gain
/// table and ignore whatever gain bytes accompany it (confirmed live), so
/// the `gains` here are only used for our own preview bar chart, matching
/// what the original app itself shows.
///
/// `EqPreset.getIndex()` had a genuine collision in the decompiled source
/// (TREBLE and NORMAL both used index 5) — NORMAL (all-zero gains) is
/// dropped here as it's unreachable via the app's own `valueOf(int)` lookup
/// (which returns the first match, TREBLE) and looks like leftover/dead code.
///
/// MODE_CUSTOM (presetId=6, arbitrary per-band gains) was dropped from the
/// UI — it reliably locked up the MenuBarExtra popover for reasons not
/// pinned down (no crash log, process stayed alive), tried twice with
/// different slider layouts. Only named presets are exposed here now.
struct EqPreset: Identifiable {
    let name: String
    let wireId: UInt8
    let previewGains: [Int8]
    var id: UInt8 { wireId }

    static let named: [EqPreset] = [
        EqPreset(name: "Standard", wireId: 0, previewGains: [-3, -2, 4, 1, 2, 1, 3, 0, 0, 0]),
        EqPreset(name: "Bass", wireId: 1, previewGains: [4, 3, 4, -2, -3, -4, -4, 0, 0, 0]),
        EqPreset(name: "Rock", wireId: 2, previewGains: [3, 2, -3, -2, 3, 2, 5, 0, 0, 0]),
        EqPreset(name: "Jazz", wireId: 3, previewGains: [-6, -3, -2, 1, 1, 4, 6, 0, 0, 0]),
        EqPreset(name: "Vocal", wireId: 4, previewGains: [-6, -3, 6, 4, 3, -4, -6, 0, 0, 0]),
        EqPreset(name: "Treble", wireId: 5, previewGains: [-12, -6, 0, 4, 5, 3, 0, 0, 0, 0]),
        EqPreset(name: "Balance", wireId: 8, previewGains: [-2, 0, -1, 0, 1, 1, 3, 0, 0, 0]),
    ]

    static func named(wireId: UInt8) -> EqPreset? {
        named.first { $0.wireId == wireId }
    }
}
