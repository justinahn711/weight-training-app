// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WeightTrainingCore",
    // SwiftData sets the floor: iOS 17 / macOS 14.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WeightTrainingCore", targets: ["WeightTrainingCore"]),
        .library(name: "WeightTrainingStore", targets: ["WeightTrainingStore"]),
    ],
    targets: [
        // Pure Swift domain layer — no SwiftData, no UIKit, no platform APIs.
        // Everything here is testable from the command line, which is what keeps
        // the progression rules (M2) verifiable without booting a simulator.
        .target(name: "WeightTrainingCore"),
        .testTarget(name: "WeightTrainingCoreTests", dependencies: ["WeightTrainingCore"]),

        // Persistence. Isolated from Core so that importing the domain types
        // never drags SwiftData into a test or a preview that doesn't need it.
        .target(name: "WeightTrainingStore", dependencies: ["WeightTrainingCore"]),
        .testTarget(name: "WeightTrainingStoreTests", dependencies: ["WeightTrainingStore"]),
    ]
)
