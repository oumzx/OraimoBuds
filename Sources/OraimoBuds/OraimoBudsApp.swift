import SwiftUI

@main
struct OraimoBudsApp: App {
    @StateObject private var ble: BLEManager

    init() {
        setvbuf(stdout, nil, _IONBF, 0)

        guard let soURL = Self.locateResourceFile("libjl_bluetooth.so") else {
            fatalError("could not locate bundled libjl_bluetooth.so")
        }
        guard RCSPCrypto.load(soPath: soURL.path) else {
            fatalError("failed to load native RCSP crypto module")
        }

        let manager = BLEManager()
        _ble = StateObject(wrappedValue: manager)
        manager.start()
    }

    @AppStorage(PreferenceKey.showBatteryInMenuBar) private var showBatteryInMenuBar = true

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(ble)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: Self.menuBarIcon)
                    .opacity(ble.connectionState == .ready ? 1.0 : 0.35)
                if showBatteryInMenuBar, ble.connectionState == .ready, let percent = lowestBatteryPercent {
                    Text("\(percent)%")
                }
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }

    /// The Oraimo logo, pre-rendered as a black silhouette on transparent
    /// background (MenuBarIcon.png) and marked as a template image so
    /// AppKit auto-tints it correctly for the light/dark menu bar —
    /// connection state is conveyed by dimming it rather than swapping
    /// glyphs, so the brand mark stays consistent everywhere.
    private static let menuBarIcon: NSImage = {
        let image: NSImage
        if let url = locateResourceFile("MenuBarIcon.png"), let loaded = NSImage(contentsOf: url) {
            image = loaded
        } else {
            image = NSImage(systemSymbolName: "airpods", accessibilityDescription: nil) ?? NSImage()
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    /// Shown next to the menu bar icon when enabled — the lower of the two
    /// earbuds' percentages, since that's the one about to die first.
    private var lowestBatteryPercent: UInt8? {
        guard let battery = ble.battery else { return nil }
        return [battery.leftPercent, battery.rightPercent].compactMap { $0 }.min()
    }

    /// A packaged .app bundle keeps bundled files flat in Contents/Resources
    /// (so codesign can seal them properly — SPM's generated `Bundle.module`
    /// accessor looks for its resource bundle as a sibling of Contents/,
    /// which breaks code signing on a real .app). `swift run`/debug builds
    /// fall back to `Bundle.module`.
    private static func locateResourceFile(_ name: String) -> URL? {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent(name),
           FileManager.default.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }
        let nameNoExt = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return Bundle.module.url(forResource: nameNoExt, withExtension: ext.isEmpty ? nil : ext)
    }
}
