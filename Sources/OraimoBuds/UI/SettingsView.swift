import SwiftUI
import ServiceManagement

struct SettingsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case updates = "Updates"
        case about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .updates: return "arrow.triangle.2.circlepath"
            case .about: return "info.circle"
            }
        }
    }

    @State private var selection: Tab = .general

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $selection) { tab in
                Label(tab.rawValue, systemImage: tab.icon).tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(150)
        } detail: {
            Group {
                switch selection {
                case .general: GeneralSettingsTab()
                case .updates: UpdatesSettingsTab()
                case .about: AboutSettingsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
        }
        .frame(width: 560, height: 420)
    }
}

private struct GeneralSettingsTab: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(PreferenceKey.showBatteryInMenuBar) private var showBatteryInMenuBar = true
    @AppStorage(PreferenceKey.lowBatteryNotifications) private var lowBatteryNotifications = true
    @AppStorage(PreferenceKey.lowBatteryThreshold) private var lowBatteryThreshold = 20

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in setLaunchAtLogin(newValue) }
                Toggle("Show battery percentage in menu bar", isOn: $showBatteryInMenuBar)
            }

            Section {
                Toggle("Low battery notifications", isOn: $lowBatteryNotifications)
                if lowBatteryNotifications {
                    Stepper(value: $lowBatteryThreshold, in: 5...50, step: 5) {
                        Text("Notify below \(lowBatteryThreshold)%")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[LaunchAtLogin] \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct UpdatesSettingsTab: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Current version", value: AppInfo.versionString)
            }
            Section {
                Text("OraimoBuds is a personal build — it isn't distributed through the App Store or an update server, so there's no automatic update check.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("To update: pull the latest source and run build_app.sh again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettingsTab: View {
    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }
            Text("OraimoBuds")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Version \(AppInfo.versionString)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("A native menu bar controller for Oraimo SpaceBuds Neo+ — ANC, EQ, battery, and gestures, talking directly to the earbuds' RCSP protocol over Bluetooth LE.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Text("Copyright © 2026 Passidi DIAW")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }
}

enum AppInfo {
    static var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }
}
