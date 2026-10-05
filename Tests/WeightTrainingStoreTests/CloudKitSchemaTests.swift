import CloudKit
import CoreData
import SwiftData
import XCTest
@testable import WeightTrainingStore

/// Guards the schema constraints CloudKit mirroring imposes (#19).
///
/// These are not style rules. CloudKit validates the schema as a whole and
/// rejects it entirely, so a single non-optional attribute without a default —
/// anywhere, in any model — makes `ModelContainer` init throw and drops the app
/// to local-only storage. `TrainingStore` catches that and keeps working, which
/// is right for the user and terrible for noticing: the app behaves normally
/// and nothing ever reaches iCloud.
///
/// `StoredDayTemplate.slotsData` shipped that way, and the only symptom was an
/// empty CloudKit dashboard. Asserting it here means the next model added can't
/// disable sync without a test going red.
final class CloudKitSchemaTests: XCTestCase {

    /// Every attribute must be optional or carry a default.
    func testEveryAttributeIsOptionalOrHasADefault() throws {
        var offenders: [String] = []

        for entity in Schema(TrainingSchema.models).entities {
            for attribute in entity.attributes
            where !attribute.isOptional && attribute.defaultValue == nil {
                offenders.append("\(entity.name).\(attribute.name)")
            }
        }

        XCTAssertEqual(
            offenders, [],
            """
            CloudKit rejects the whole schema over these, silently falling back \
            to a local store: \(offenders.joined(separator: ", "))
            """
        )
    }

    /// No attribute may be unique.
    ///
    /// The other half of the same contract: a mirrored store can't enforce
    /// uniqueness, because two offline devices can each create the same row and
    /// neither is wrong. `TrainingStore.upsert` and `deduplicate()` carry that
    /// job instead.
    func testNoAttributeIsUnique() throws {
        var offenders: [String] = []

        for entity in Schema(TrainingSchema.models).entities {
            for attribute in entity.attributes where attribute.isUnique {
                offenders.append("\(entity.name).\(attribute.name)")
            }
        }

        XCTAssertEqual(offenders, [], "CloudKit mirroring forbids unique constraints")
    }

    /// `CloudKitSchemaInitializer` (the Debug-only way to push the whole
    /// schema to CloudKit Development) starts by building a Core Data model
    /// from the same `@Model` types the store opens. If that ever fails, or
    /// drops a type, the initializer would push an incomplete schema, so it's
    /// checked here, where no iCloud account is needed.
    func testTheCloudKitSchemaInitializerCanBuildAModelOfEveryStoredType() throws {
        let model = try XCTUnwrap(NSManagedObjectModel.makeManagedObjectModel(for: TrainingSchema.models))
        let names = Set(model.entities.compactMap(\.name))
        for type in TrainingSchema.models {
            XCTAssertTrue(names.contains(String(describing: type)),
                          "\(type) is missing from the model the schema initializer would push")
        }
        XCTAssertEqual(model.entities.count, TrainingSchema.models.count)
    }

    /// Without a usable iCloud account the initializer fails at once, saying
    /// why, instead of waiting forever inside initializeCloudKitSchema().
    func testTheSchemaInitializerFailsFastWithoutAnICloudAccount() {
        for status in [CKAccountStatus.noAccount, .temporarilyUnavailable, .restricted, .couldNotDetermine] {
            XCTAssertThrowsError(try CloudKitSchemaInitializer.run(containerIdentifier: "iCloud.test",
                                                                   accountStatus: { _ in status })) { error in
                guard case CloudKitSchemaInitializer.Failure.noICloudAccount = error else {
                    return XCTFail("\(status): expected noICloudAccount, got \(error)")
                }
            }
        }
        XCTAssertThrowsError(try CloudKitSchemaInitializer.run(containerIdentifier: "iCloud.test",
                                                               accountStatus: { _ in nil })) { error in
            XCTAssertEqual(error as? CloudKitSchemaInitializer.Failure, .accountStatusTimedOut)
        }
    }
}
