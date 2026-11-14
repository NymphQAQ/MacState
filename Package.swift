// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacState",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MacState", targets: ["MacState"])],
    targets: [
        .target(name: "SystemBridge", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "MacState", dependencies: ["SystemBridge"], resources: [.copy("Resources/Web"), .copy("Resources/Lens"), .copy("Resources/TraditionalColors"), .copy("Resources/LocalTranslation")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "MacStateTests", dependencies: ["MacState"])
    ]
)
