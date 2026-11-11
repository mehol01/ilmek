// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IlmekKit",
    defaultLocalization: "tr",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "IlmekKit", targets: ["IlmekKit"]),
    ],
    targets: [
        .target(name: "IlmekKit"),
        .testTarget(name: "IlmekKitTests", dependencies: ["IlmekKit"]),
    ]
)
