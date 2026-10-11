// swift-tools-version: 5.9
import PackageDescription

// Koala Touch: Koala Sampler on the Akai MPC Touch (the Koala + MPC part of Paper Picker, on its own).
let package = Package(
    name: "KoalaTouch",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "KoalaTouch", targets: ["KoalaTouch"])],
    targets: [
        .target(name: "MPCControllerSetup", path: "Sources/MPCControllerSetup", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("CoreMIDI"), .linkedFramework("CoreFoundation")]),
        .executableTarget(name: "KoalaTouch", dependencies: ["MPCControllerSetup"], path: "Sources/KoalaTouch",
                          resources: [.copy("Resources/Fonts")],
                          linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ApplicationServices")])
    ]
)
