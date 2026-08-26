import Foundation
import WeightTrainingCore
@testable import WeightTrainingStore

// A corpus, not a fixture.
//
// The unit tests for #87/#88 prove the round trip on one carefully-built
// history. That's the right shape for a test and the wrong shape for the
// question an eval asks, which is whether the property holds across the range
// of histories this app actually produces — warmups, half-point efforts, a
// measured apparatus, a lift loaded by bodyweight, sets logged either side of
// midnight, and a history long enough that ordering starts to matter.

/// A whole training history as value types, ready to be written into a store.
public struct HistoryShape {
    public let name: String
    public var exercises: [Exercise] = []
    public var sets: [SetRecord] = []
    public var states: [ProgressState] = []
    public var templates: [DayTemplate] = []
    public var bodyweights: [BodyweightReading] = []

    /// Writes the shape through the ordinary logging surface, not through
    /// `restore`. Seeding by the same path the app uses means the corpus is
    /// made of stores that could really exist.
    @MainActor
    public func seed(into store: TrainingStore) throws {
        try store.upsert(exercises)
        for template in templates { try store.upsert(template) }
        for set in sets { try store.log(set) }
        for state in states { try store.save(state) }
        for reading in bodyweights {
            try store.record(reading, calendar: Corpus.calendar)
        }
    }
}

public enum Corpus {

    /// UTC, so a run on a laptop in one timezone and a runner in another
    /// exercise the same calendar boundaries.
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Anchored to a fixed midday, never built from `Date()` with offsets:
    /// the store groups sets by calendar day, so a fixture near midnight
    /// straddles two of them, which failed for real at 23:56 (#79).
    static func at(day: Int, hour: Int = 12, minute: Int = 0, second: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)!
    }

    static func library(_ name: String) -> Exercise {
        ExerciseLibrary.all.first { $0.name == name }!
    }

    public static var all: [HistoryShape] {
        [minimal, warmupsIncluded, threeWeekBlock, measuredApparatus,
         bodyweightLifting, halfPointEfforts, eitherSideOfMidnight, aLongRun]
    }

    // MARK: - Shapes

    /// The floor: one lift, one session. If the round trip can't manage this,
    /// nothing below matters.
    static var minimal: HistoryShape {
        let lift = library("Incline DB Press")
        return HistoryShape(
            name: "one lift, one session",
            exercises: [lift],
            sets: (0..<3).map { index in
                SetRecord(exerciseID: lift.id, load: Load(70), reps: 8, rpe: RPE(8)!,
                          performedAt: at(day: 10, minute: index * 3))
            },
            states: [ProgressState(exerciseID: lift.id, targetLoad: Load(70),
                                   targetReps: 9, targetRPE: RPE(8)!,
                                   lastPerformedAt: at(day: 10))]
        )
    }

    /// Warmups are excluded from progression, volume, e1RM and records — which
    /// makes them exactly the rows an export written against the insight layer
    /// would drop without anything downstream noticing.
    static var warmupsIncluded: HistoryShape {
        let lift = library("Flat Bench")
        var shape = HistoryShape(name: "warmups and working sets", exercises: [lift])
        shape.sets = [
            SetRecord(exerciseID: lift.id, load: Load(45), reps: 10,
                      isWarmup: true, performedAt: at(day: 11, minute: 0)),
            SetRecord(exerciseID: lift.id, load: Load(95), reps: 5,
                      isWarmup: true, performedAt: at(day: 11, minute: 3)),
            SetRecord(exerciseID: lift.id, load: Load(185), reps: 5, rpe: RPE(8)!,
                      performedAt: at(day: 11, minute: 8))
        ]
        return shape
    }

    /// Three weeks of push/pull/legs. Several lifts, several days, progression
    /// state on each — the ordinary case, at the scale the app runs at.
    static var threeWeekBlock: HistoryShape {
        let lifts = [library("Incline DB Press"), library("Flat Bench"),
                     library("Lateral Raise"), library("Tricep Pressdown")]
        var shape = HistoryShape(name: "a three-week block", exercises: lifts)

        for week in 0..<3 {
            for (offset, lift) in lifts.enumerated() {
                let day = 10 + week * 7 + offset
                for index in 0..<3 {
                    shape.sets.append(SetRecord(
                        exerciseID: lift.id,
                        load: Load(60 + Double(week) * 5),
                        reps: 8 + index,
                        rpe: RPE(8)!,
                        performedAt: at(day: day, minute: index * 4)
                    ))
                }
            }
        }

        shape.states = lifts.map { lift in
            ProgressState(exerciseID: lift.id, targetLoad: Load(75), targetReps: 10,
                          targetRPE: RPE(8)!, stallCount: 0, consecutiveTopHits: 1,
                          lastE1RM: Load(95), lastPerformedAt: at(day: 24))
        }
        shape.templates = [DayTemplate(kind: .push, slots: [
            Slot(name: "Chest", candidateExerciseIDs: lifts.map(\.id), rotates: true)
        ])]
        return shape
    }

    /// A measured plate-built apparatus. `LoadingStyle` is the one place a
    /// computed weight becomes a real one (#39), and it rides along inside the
    /// exercise — so a restore that loses it produces plate breakdowns that
    /// disagree with the rack.
    static var measuredApparatus: HistoryShape {
        let hack = Exercise(
            name: "Hack Squat (measured)",
            muscles: [.primary(.quads), .secondary(.glutes)],
            equipment: .plateLoaded,
            increment: LoadIncrement(pounds: 5),
            progressionRule: .doubleProgression(range: RepRange(8, 12)),
            loading: LoadingStyle(baseWeight: Load(88), sleeves: 2,
                                  availablePlates: [45, 25, 10, 5, 2.5])
        )
        return HistoryShape(
            name: "a measured apparatus",
            exercises: [hack],
            sets: (0..<4).map { index in
                SetRecord(exerciseID: hack.id, load: Load(178), reps: 10, rpe: RPE(8.5)!,
                          performedAt: at(day: 12, minute: index * 5))
            },
            states: [ProgressState(exerciseID: hack.id, targetLoad: Load(178),
                                   targetReps: 11, lastPerformedAt: at(day: 12))]
        )
    }

    /// A lift loaded by what you weigh (#71), plus the weigh-ins it reads.
    /// Bodyweight is the one entity identified by its day rather than an id,
    /// so it reconciles by a different rule than everything else.
    static var bodyweightLifting: HistoryShape {
        let pullUp = Exercise(
            name: "Pull-Up",
            muscles: [.primary(.lats), .secondary(.biceps)],
            equipment: .bodyweight,
            progressionRule: .doubleProgression(range: RepRange(5, 10))
        )
        return HistoryShape(
            name: "bodyweight lifting",
            exercises: [pullUp],
            sets: (0..<3).map { index in
                SetRecord(exerciseID: pullUp.id, load: Load(178), reps: 7, rpe: RPE(8)!,
                          performedAt: at(day: 13, minute: index * 4))
            },
            bodyweights: (0..<5).map { index in
                BodyweightReading(pounds: 177.5 + Double(index) * 0.5,
                                  recordedAt: at(day: 10 + index, hour: 7))
            }
        )
    }

    /// 6.5 is storable but never offered as a chip, which makes it the value a
    /// round trip is most likely to quietly round away.
    static var halfPointEfforts: HistoryShape {
        let lift = library("Seated DB OHP")
        return HistoryShape(
            name: "half-point efforts",
            exercises: [lift],
            sets: [6.5, 7.5, 8.5, 9.5].enumerated().map { index, value in
                SetRecord(exerciseID: lift.id, load: Load(45), reps: 9,
                          rpe: RPE(value)!, performedAt: at(day: 14, minute: index * 3))
            }
        )
    }

    /// The #79 hazard, deliberately: a session that straddles midnight. These
    /// are two calendar days and must stay two, wherever they're restored.
    static var eitherSideOfMidnight: HistoryShape {
        let lift = library("Chest Fly")
        return HistoryShape(
            name: "either side of midnight",
            exercises: [lift],
            sets: [
                SetRecord(exerciseID: lift.id, load: Load(30), reps: 12, rpe: RPE(8)!,
                          performedAt: at(day: 15, hour: 23, minute: 56)),
                SetRecord(exerciseID: lift.id, load: Load(30), reps: 11, rpe: RPE(8.5)!,
                          performedAt: at(day: 16, hour: 0, minute: 4))
            ]
        )
    }

    /// Six months at three sessions a week. Long enough that any ordering
    /// assumption in the export or the restore has room to show itself.
    static var aLongRun: HistoryShape {
        let lifts = [library("Incline DB Press"), library("Lateral Raise")]
        var shape = HistoryShape(name: "six months of training", exercises: lifts)
        for session in 0..<78 {
            let lift = lifts[session % lifts.count]
            for index in 0..<3 {
                shape.sets.append(SetRecord(
                    exerciseID: lift.id,
                    load: Load(50 + Double(session / 6) * 5),
                    reps: 8 + (session % 4),
                    rpe: RPE(8)!,
                    performedAt: at(day: 1 + session * 2, minute: index * 4)
                ))
            }
        }
        return shape
    }
}
