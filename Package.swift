// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WeightTrainingCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "WeightTrainingCore", targets: ["WeightTrainingCore"]),
    ],
    targets: [
        // Pure Swift domain layer — no SwiftData, no UIKit, no platform APIs.
        // Everything here is testable from the command line, which is what keeps
        // the progression rules (M2) verifiable without booting a simulator.
        .target(name: "WeightTrainingCore"),
        .testTarget(name: "WeightTrainingCoreTests", dependencies: ["WeightTrainingCore"]),
    ]
)
