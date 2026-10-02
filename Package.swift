// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Grantch",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Grantch", targets: ["GrantchApp"]),
        .executable(name: "grantch-hook", targets: ["GrantchHook"]),
        .executable(name: "grantch-config", targets: ["GrantchConfig"]),
        .library(name: "GrantchCore", targets: ["GrantchCore"])
    ],
    targets: [
        .target(name: "GrantchCore"),
        .executableTarget(name: "GrantchApp", dependencies: ["GrantchCore"]),
        .executableTarget(name: "GrantchHook", dependencies: ["GrantchCore"]),
        .executableTarget(name: "GrantchConfig"),
        .testTarget(name: "GrantchCoreTests", dependencies: ["GrantchCore"])
    ]
)
