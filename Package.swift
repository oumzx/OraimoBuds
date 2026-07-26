// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OraimoBuds",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CRCSPCrypto",
            path: "Sources/CRCSPCrypto"
        ),
        .executableTarget(
            name: "OraimoBuds",
            dependencies: ["CRCSPCrypto"],
            path: "Sources/OraimoBuds",
            resources: [
                .copy("Resources/libjl_bluetooth.so"),
                .copy("Resources/MenuBarIcon.png"),
            ]
        ),
    ]
)
