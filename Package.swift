// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexQuickOK",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexQuickOKCore", targets: ["CodexQuickOKCore"]),
        .executable(name: "CodexQuickOKApp", targets: ["CodexQuickOKApp"]),
    ],
    targets: [
        .target(name: "CodexQuickOKCore"),
        .executableTarget(name: "CodexQuickOKApp", dependencies: ["CodexQuickOKCore"]),
        .testTarget(name: "CodexQuickOKCoreTests", dependencies: ["CodexQuickOKCore"]),
        .testTarget(
            name: "CodexQuickOKAppTests",
            dependencies: ["CodexQuickOKApp", "CodexQuickOKCore"]
        ),
    ]
)
