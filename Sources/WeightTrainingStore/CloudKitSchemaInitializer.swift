import CloudKit
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

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case noICloudAccount(status: String)
        case accountStatusTimedOut
        case modelUnavailable
        case storeFailedToLoad(String)

        public var description: String {
            switch self {
            case .noICloudAccount(let status):
                return "iCloud isn't available on this device (account status: \(status)). "
                    + "Sign in under Settings → Apple Account, then run again."
            case .accountStatusTimedOut:
                return "CloudKit didn't report the iCloud account status within 10 s; nothing was pushed."
            case .modelUnavailable:
                return "Couldn't build a Core Data model from TrainingSchema.models"
            case .storeFailedToLoad(let reason):
                return "Throwaway store failed to load: \(reason)"
            }
        }
    }

    /// Asks CloudKit whether this device has a usable iCloud account. Nil
    /// means it didn't answer in time. Injected so a test can run the
    /// not-signed-in path without iCloud.
    public typealias AccountStatus = (_ containerIdentifier: String) -> CKAccountStatus?

    public static let liveAccountStatus: AccountStatus = { identifier in
        let answered = DispatchSemaphore(value: 0)
        var status: CKAccountStatus?
        CKContainer(identifier: identifier).accountStatus { result, _ in
            status = result
            answered.signal()
        }
        return answered.wait(timeout: .now() + 10) == .success ? status : nil
    }

    /// - Parameter containerIdentifier: the app's iCloud container, as in its
    ///   entitlements (`iCloud.com.justinloves.ChickenBreast`).
    /// - Parameter accountStatus: checked first. Without a signed-in iCloud
    ///   account, `initializeCloudKitSchema()` doesn't fail; it waits
    ///   indefinitely (seen on a simulator with no account, which logged
    ///   `CKAccountStatusTemporarilyUnavailable` and never returned). So
    ///   this fails in seconds, says why, and opens nothing.
    public static func run(containerIdentifier: String,
                           accountStatus: AccountStatus = liveAccountStatus) throws {
        guard let status = accountStatus(containerIdentifier) else { throw Failure.accountStatusTimedOut }
        guard status == .available else { throw Failure.noICloudAccount(status: name(of: status)) }

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
            if let loadError { throw Failure.storeFailedToLoad(loadError.localizedDescription) }

            try container.initializeCloudKitSchema()

            // Released before SwiftData opens the real store, so the two never
            // share a coordinator.
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        }
    }

    static func name(of status: CKAccountStatus) -> String {
        switch status {
        case .available: return "available"
        case .noAccount: return "no account"
        case .restricted: return "restricted"
        case .couldNotDetermine: return "could not determine"
        case .temporarilyUnavailable: return "temporarily unavailable"
        @unknown default: return "unknown (\(status.rawValue))"
        }
    }
}
