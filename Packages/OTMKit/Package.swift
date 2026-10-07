// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OTMKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OTMKit", targets: ["OTMKit"]),
        .executable(name: "otm", targets: ["otm"]),
    ],
    targets: [
        .target(
            name: "OTMKit",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("SystemConfiguration"), .linkedFramework("CoreWLAN")]
        ),
        .executableTarget(
            name: "otm",
            dependencies: ["OTMKit"]
        ),
        .testTarget(
            name: "OTMKitTests",
            dependencies: ["OTMKit"]
        ),
    ]
)
