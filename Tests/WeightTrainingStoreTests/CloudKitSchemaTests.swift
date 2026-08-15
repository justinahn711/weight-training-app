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
}
