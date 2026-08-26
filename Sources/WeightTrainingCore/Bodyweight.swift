import Foundation

/// What you weighed, and when.
///
/// A series rather than a single number, because bodyweight moves. An e1RM for
/// a set of pull-ups computed against today's weight would quietly rewrite last
/// year's training every time the scale moves, and the shape can't be
/// retrofitted cheaply once anyone has history (#71).
public struct BodyweightReading: Hashable, Codable, Sendable, Comparable {
    public let pounds: Double
    public let recordedAt: Date

    public init(pounds: Double, recordedAt: Date) {
        self.pounds = pounds
        self.recordedAt = recordedAt
    }

    public static func < (a: BodyweightReading, b: BodyweightReading) -> Bool {
        a.recordedAt < b.recordedAt
    }
}

public extension Collection where Element == BodyweightReading {

    /// What you weighed on the day of `date`, as far as anything recorded knows.
    ///
    /// The most recent reading at or before the moment asked about — never a
    /// later one. A set performed in March is judged against March's weight,
    /// which is the whole reason this is a series.
    ///
    /// Nil before the first reading. A bodyweight lift performed before anyone
    /// stepped on a scale has no honest load, and inventing one would put a
    /// number into volume and e1RM that nobody measured.
    func weight(on date: Date) -> Double? {
        filter { $0.recordedAt <= date }
            .max()?
            .pounds
    }
}

public extension Exercise {

    /// Whether the lifter's own weight is part of the load.
    var isBodyweight: Bool { equipment == .bodyweight }
}

public extension BodyweightReading {

    /// What a bodyweight set starts from, before anything is added.
    ///
    /// A logged set stores the **total**, exactly as a barbell set does — a
    /// bench set records 185 including the 45 lb bar, so a chin-up set records
    /// 200 including the 175 lb lifter. The series is what seeds that number;
    /// it isn't consulted afterwards.
    ///
    /// That ordering matters. Storing the added weight and recomposing later
    /// would make every past set move whenever the scale did: a year of pull-up
    /// e1RMs quietly rewritten by breakfast. Recording the total freezes what
    /// was actually moved, on the day it was moved.
    var startingLoad: Load { Load(pounds) }
}
