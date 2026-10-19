// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ModelPull",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DLCore", path: "src/DLCore"),
        .executableTarget(name: "ModelPullApp", dependencies: ["DLCore"], path: "src/ModelPullApp"), // macOS only (SwiftUI)
        .executableTarget(name: "ModelPullWeb", dependencies: ["DLCore"], path: "src/ModelPullWeb"),  // Linux (+ macOS): local web UI
        // No XCTest in Command Line Tools -> self-check runner instead.
        .executableTarget(name: "DLChecks", dependencies: ["DLCore"], path: "tests/DLChecks"),
    ]
)
