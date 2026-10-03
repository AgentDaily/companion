// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuendaCompanion",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CompanionCore", targets: ["CompanionCore"]),
        .library(name: "CompanionUI", targets: ["CompanionUI"]),
        .executable(name: "QuendaCompanionMac", targets: ["QuendaCompanionMac"]),
    ],
    targets: [
        .target(name: "CompanionCore"),
        .target(name: "CompanionUI", dependencies: ["CompanionCore"]),
        .executableTarget(name: "QuendaCompanionMac", dependencies: ["CompanionCore", "CompanionUI"]),
        .testTarget(name: "CompanionCoreTests", dependencies: ["CompanionCore", "CompanionUI"]),
    ],
    swiftLanguageModes: [.v5]
)
