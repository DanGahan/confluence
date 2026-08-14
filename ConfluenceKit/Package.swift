// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ConfluenceKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ConfluenceKit", targets: ["ConfluenceKit"]),
    ],
    targets: [
        .target(name: "ConfluenceKit"),
        .testTarget(name: "ConfluenceKitTests", dependencies: ["ConfluenceKit"]),
    ]
)
