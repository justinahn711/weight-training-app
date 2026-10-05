import CoreData
import Foundation
import SwiftData

/// Pushes every record type and field the store uses to the CloudKit
/// **Development** environment in one go, ready for "Deploy Schema Changes"
/// to Production in the CloudKit Console.
///
/// Without this, Development only learns a type or field when a synced build
/// happens to save one, so a field nobody exercised before the deploy never
/// reaches Production, and a release build then falls back to local-only
/// storage (#19). This is Apple's documented route for SwiftData: build a
/// Core Data model from the same `@Model` types, open an
/// `NSPersistentCloudKitContainer` on it, and call `initializeCloudKitSchema()`.
///
/// It runs against a **throwaway local file**, never the lifter's store:
/// `initializeCloudKitSchema` uploads placeholder records to Development to
/// create the schema, and nothing here should read or write real training
/// data. The file is removed afterwards. Only ever call this from a Debug
/// build. Development is the only environment it can reach, but it still
/// talks to iCloud.
public enum CloudKitSchemaInitializer {

    public enum Failure: Error, CustomStringConvertible {
        case modelUnavailable
        case storeFailedToLoad(Error)

        public var description: String {
            switch self {
            case .modelUnavailable:
                return "Couldn't build a Core Data model from TrainingSchema.models"
            case .storeFailedToLoad(let error):
                return "Throwaway store failed to load: \(error.localizedDescription)"
            }
        }
    }

    /// - Parameter containerIdentifier: the app's iCloud container, as in its
    ///   entitlements (`iCloud.com.justinloves.ChickenBreast`).
    public static func run(containerIdentifier: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CloudKitSchemaInit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try autoreleasepool {
            guard let model = NSManagedObjectModel.makeManagedObjectModel(for: TrainingSchema.models) else {
                throw Failure.modelUnavailable
            }
            let description = NSPersistentStoreDescription(url: directory.appending(path: "schema.store"))
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: containerIdentifier
            )
            description.shouldAddStoreAsynchronously = false

            let container = NSPersistentCloudKitContainer(name: "ChickenBreastSchema", managedObjectModel: model)
            container.persistentStoreDescriptions = [description]
            var loadError: Error?
            container.loadPersistentStores { _, error in loadError = error }
            if let loadError { throw Failure.storeFailedToLoad(loadError) }

            try container.initializeCloudKitSchema()

            // Released before SwiftData opens the real store, so the two never
            // share a coordinator.
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        }
    }
}
