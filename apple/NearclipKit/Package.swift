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
        // Embedded Tailscale node (tailnet/build.sh apple). Static library; Go needs these system libraries.
        .binaryTarget(name: "NCTailnet", path: "Binaries/NCTailnet.xcframework"),
        .target(name: "NearclipKit", dependencies: ["NCTailnet"],
                linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("Security"), .linkedLibrary("resolv")]),
        .executableTarget(name: "nearclip-cli", dependencies: ["NearclipKit"]),
        .testTarget(name: "NearclipKitTests", dependencies: ["NearclipKit"]),
    ],
    swiftLanguageVersions: [.v5]
)

