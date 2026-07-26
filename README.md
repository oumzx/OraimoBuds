# OraimoBuds

A native macOS menu bar app to control Oraimo SpaceBuds Neo+ earbuds — ANC, EQ, battery, and touch gestures — talking directly to the earbuds' RCSP protocol over Bluetooth LE, the same way the official "oraimo sound" phone app does.

## Features

- **ANC control** — Off / Noise Cancelling / Transparency, read and write
- **Battery** — left / right / case percentage, with charging status
- **EQ** — named presets (Standard, Bass, Rock, Jazz, Vocal, Treble, Balance)
- **Gestures** — view and edit what each tap gesture does per earbud
- Menu bar icon with optional battery percentage, low-battery notifications
- Launch at login

## How it works

The earbuds use Zhuhai Jieli Technology's (JieLi) BLE chip and RCSP protocol — a proprietary binary protocol with a mandatory authentication handshake before any command is accepted. The handshake's crypto step is implemented in a small native ARM64 shared library shipped by JieLi (`libjl_bluetooth.so`, part of the official Android app's SDK).

Since the target Mac and that library are both ARM64 (Apple Silicon), this project loads the vendor's compiled machine code directly in-process via a minimal hand-written ELF loader (`Sources/CRCSPCrypto/crcsp_crypto.c`) rather than reverse-engineering and reimplementing the (non-standard, proprietary) cipher by hand — this guarantees bit-exact compatibility with the real handshake. See that file's comments for the two Apple-Silicon-specific hurdles it works around (W^X memory protection, and bionic-vs-Darwin TLS layout differences for the stack-protector canary).

Everything above the crypto handshake — the BLE envelope format, command opcodes, and attribute layouts for ANC/EQ/battery/gestures — was reverse engineered from the official Android app's decompiled sources and confirmed against real hardware.

### About `libjl_bluetooth.so`

This repository includes a copy of JieLi's compiled `libjl_bluetooth.so`, extracted from the official Oraimo Android app, so the project builds and runs out of the box. That file is **not licensed by this project** — it's the chip vendor's proprietary binary. If you'd rather not have it here, delete `Sources/OraimoBuds/Resources/libjl_bluetooth.so` and extract your own copy from the `oraimo sound` Android APK (`lib/arm64-v8a/libjl_bluetooth.so` inside the APK) before building.

## Building

Requires macOS 14+ and either Xcode or just the Command Line Tools (`xcode-select --install`) — no Xcode project needed.

```bash
swift build                # debug build, or:
./build_app.sh             # produces a real, double-clickable OraimoBuds.app
```

`build_app.sh` assembles the `.app` bundle by hand (Info.plist, icon, resources) and ad-hoc codesigns it — signing is required for the "Launch at Login" toggle (`ServiceManagement.SMAppService`) to work.

## Status

ANC, EQ (read/write), battery, and gestures (read/write) are all confirmed working against real hardware. See inline code comments for anything still marked as unconfirmed or a known limitation.
