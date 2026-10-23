// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NearclipKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "NearclipKit", targets: ["NearclipKit"]),
        .executable(name: "nearclip-cli", targets: ["nearclip-cli"]),
    ],
    targets: [
        .target(name: "NearclipKit"),
        .executableTarget(name: "nearclip-cli", dependencies: ["NearclipKit"]),
        .testTarget(name: "NearclipKitTests", dependencies: ["NearclipKit"]),
    ],
    swiftLanguageVersions: [.v5]
)

