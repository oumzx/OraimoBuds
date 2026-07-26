import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var ble: BLEManager
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if ble.connectionState == .ready {
                Divider()
                batterySection
                Divider()
                ancSection
                Divider()
                eqSection
                Divider()
                gesturesSection
            } else if let error = ble.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(ble.deviceName ?? "OraimoBuds")
                .font(.headline)
            Spacer()
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch ble.connectionState {
        case .ready: return .green
        case .disconnected: return .red
        default: return .yellow
        }
    }

    private var statusText: String {
        switch ble.connectionState {
        case .disconnected: return "Disconnected"
        case .scanning: return "Scanning…"
        case .connecting: return "Connecting…"
        case .authenticating: return "Authenticating…"
        case .ready: return "Connected"
        }
    }

    // MARK: - Battery

    private var batterySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Battery")
            HStack(spacing: 16) {
                batteryColumn(label: "L", info: ble.battery?.leftPercent, charging: ble.battery?.leftCharging ?? false)
                batteryColumn(label: "R", info: ble.battery?.rightPercent, charging: ble.battery?.rightCharging ?? false)
                batteryColumn(label: "Case", info: ble.battery?.casePercent, charging: ble.battery?.caseCharging ?? false)
            }
        }
    }

    private func batteryColumn(label: String, info: UInt8?, charging: Bool) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                Image(systemName: charging ? "battery.100.bolt" : batteryIcon(info))
                Text(info.map { "\($0)%" } ?? "—")
                    .font(.system(.body, design: .rounded))
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func batteryIcon(_ percent: UInt8?) -> String {
        guard let percent else { return "battery.0" }
        switch percent {
        case 0..<20: return "battery.0"
        case 20..<50: return "battery.25"
        case 50..<80: return "battery.50"
        case 80..<95: return "battery.75"
        default: return "battery.100"
        }
    }

    // MARK: - ANC

    private var ancSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Noise Control")
            Picker("", selection: Binding(
                get: { ble.ancMode ?? 0 },
                set: { ble.setAncMode($0) }
            )) {
                Text("Off").tag(UInt8(0))
                Text("ANC").tag(UInt8(1))
                Text("Transparency").tag(UInt8(2))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: - EQ

    /// "Custom" (MODE_CUSTOM=6, arbitrary per-band gains via sliders) was
    /// tried twice and reliably locked up the popover in this MenuBarExtra
    /// context for reasons not pinned down (no crash log, process stays
    /// alive) — dropped per explicit instruction rather than keep guessing.
    /// Only the named presets remain, which are simple picker selections
    /// confirmed working live.
    private var eqSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Equalizer")

            Picker("", selection: eqPresetBinding) {
                ForEach(EqPreset.named) { preset in
                    Text(preset.name).tag(preset.wireId)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            EqGainsView(gains: EqPreset.named(wireId: ble.eqMode ?? 0)?.previewGains ?? ble.eqGains ?? Array(repeating: 0, count: 10))
                .opacity(0.7)
        }
    }

    private var eqPresetBinding: Binding<UInt8> {
        Binding(get: { ble.eqMode ?? 0 }, set: { ble.setEqPreset($0) })
    }

    // MARK: - Gestures

    private var gesturesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Gestures")
            if ble.keySettings.isEmpty {
                Text("No data yet").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(ble.keySettings.enumerated()), id: \.offset) { _, setting in
                    HStack {
                        Text("\(Labels.side(setting.keyNum)) · \(Labels.action(setting.action))")
                            .font(.caption)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { setting.function },
                            set: { ble.setKeySetting(side: setting.keyNum, action: setting.action, function: $0) }
                        )) {
                            ForEach(RCSP.selectableFunctions, id: \.self) { f in
                                Text(Labels.function(f)).tag(f)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Refresh") { ble.refreshAll() }
                .disabled(ble.connectionState != .ready)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .font(.caption)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.subheadline).fontWeight(.semibold)
    }
}

/// Tiny bar-chart rendering of the 10 EQ band gains, no external deps.
private struct EqGainsView: View {
    let gains: [Int8]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(gains.enumerated()), id: \.offset) { _, gain in
                RoundedRectangle(cornerRadius: 2)
                    .fill(.tint)
                    .frame(width: 12, height: barHeight(gain))
            }
        }
        .frame(height: 40, alignment: .bottom)
    }

    private func barHeight(_ gain: Int8) -> CGFloat {
        let clamped = max(-10, min(10, Int(gain)))
        return CGFloat(20 + clamped * 2)
    }
}
