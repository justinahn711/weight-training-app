import Foundation

/// One reading of one measure, on one day.
///
/// Deliberately source-agnostic: Oura writes these to HealthKit, but so do a
/// watch, a ring, a chest strap, or a person typing into Health. #26's point is
/// that the app reads the measure and does not care what produced it.
public struct HealthSample: Hashable, Sendable {
    public let date: Date
    public let value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

/// How recovered you look this morning, as a proxy.
///
/// Oura's own Readiness score doesn't export, so this reconstructs one from the
/// measures that do: HRV and resting heart rate against your own recent
/// baseline, plus how long you slept. Not a clinical figure and not a
/// prescription — a lifter already knows they slept badly, and the value here
/// is having it sit next to "bench RPE is up a point" rather than being
/// remembered separately.
///
/// Judged against your own 14-day baseline rather than population norms,
/// because HRV in particular is meaningless between people: 30ms is alarming
/// for one person and ordinary for another.
public struct Readiness: Hashable, Sendable {

    /// 0–100, where 50 is an ordinary day against your own baseline.
    public let score: Int

    /// What moved the score, for the digest line. Empty when everything sat
    /// close to baseline — a day with nothing to say about it.
    public let notes: [String]

    /// How far HRV sat from baseline, as a fraction. Positive is above.
    public let hrvDeviation: Double?
    /// How far resting heart rate sat from baseline, in beats. Positive is
    /// above, which is the unwelcome direction.
    public let restingHRDeviation: Double?
    /// Last night, in hours.
    public let sleepHours: Double?

    /// Which measures actually contributed.
    ///
    /// Recorded so a reading can never imply more than it knows. HRV and
    /// resting heart rate go missing in ordinary ways — a ring left on the
    /// charger, an export that quietly stops — and a score computed from sleep
    /// alone must not be presented as a full recovery picture.
    public let basis: Set<Measure>

    public enum Measure: String, Hashable, Sendable, Comparable {
        case hrv, restingHR, sleep

        public static func < (a: Measure, b: Measure) -> Bool {
            a.rawValue < b.rawValue
        }
    }

    /// True when nothing cardiac was available, so this is a sleep score
    /// wearing a recovery label.
    public var isSleepOnly: Bool { basis == [.sleep] }

    public enum Level: String, Sendable {
        case low, fair, good

        public var summary: String {
            switch self {
            case .low:  return "Recovery looks low"
            case .fair: return "Recovery looks about normal"
            case .good: return "Recovery looks good"
            }
        }
    }

    public var level: Level {
        switch score {
        case ..<40:  return .low
        case ..<65:  return .fair
        default:     return .good
        }
    }

    /// Days of history required before a baseline means anything.
    ///
    /// Below this the app says nothing rather than comparing today against two
    /// other days and calling it a trend. A wrong readiness reading is worse
    /// than none: it gets believed, and it argues for skipping a session.
    public static let minimumBaselineDays = 7

    /// The window the baseline is drawn from.
    public static let baselineDays = 14

    /// Builds today's reading, or nil when there isn't enough history.
    ///
    /// - Parameters:
    ///   - hrv: heart rate variability samples, most recent last.
    ///   - restingHR: resting heart rate samples.
    ///   - sleep: total sleep per night, in hours.
    ///   - now: the moment "today" is measured from.
    public static func from(
        hrv: [HealthSample],
        restingHR: [HealthSample],
        sleep: [HealthSample],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Readiness? {
        let hrvPart = deviation(in: hrv, now: now, calendar: calendar)
        let hrPart = deviation(in: restingHR, now: now, calendar: calendar)
        let lastNight = mostRecent(in: sleep, now: now, calendar: calendar)

        // Nothing to say without at least one comparable measure. Sleep alone
        // is enough — it needs no baseline to interpret.
        guard hrvPart != nil || hrPart != nil || lastNight != nil else { return nil }

        var components: [(score: Double, weight: Double)] = []
        var notes: [String] = []
        var basis: Set<Measure> = []

        if let hrvPart {
            basis.insert(.hrv)
            // ±20% from baseline spans the whole range. HRV swings far more
            // than heart rate does, so a tighter band would peg the score at
            // an extreme on any ordinary night.
            components.append((normalised(hrvPart.ratio, span: 0.20), 0.4))
            if hrvPart.ratio <= -0.10 {
                notes.append("HRV \(percent(hrvPart.ratio)) below your 14-day average")
            } else if hrvPart.ratio >= 0.10 {
                notes.append("HRV \(percent(hrvPart.ratio)) above your 14-day average")
            }
        }

        if let hrPart {
            basis.insert(.restingHR)
            // Inverted: a resting heart rate above baseline is the bad
            // direction. 6 bpm is a wide day-to-day swing.
            components.append((normalised(-hrPart.absolute / 6, span: 1), 0.3))
            if hrPart.absolute >= 3 {
                notes.append("resting HR up \(Int(hrPart.absolute.rounded())) bpm")
            }
        }

        if let lastNight {
            basis.insert(.sleep)
            // Anchored to hours rather than to a baseline: eight hours is good
            // for almost everyone, and someone who habitually sleeps five
            // should not be told five is their normal and therefore fine.
            let sleepScore = clamp((lastNight - 5) / 3, 0, 1)
            components.append((sleepScore, 0.3))
            if lastNight < 6.5 {
                notes.append("slept \(hoursText(lastNight))")
            }
        }

        let totalWeight = components.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nil }
        let weighted = components.reduce(0) { $0 + $1.score * $1.weight } / totalWeight

        return Readiness(
            score: Int((weighted * 100).rounded()),
            notes: notes,
            hrvDeviation: hrvPart?.ratio,
            restingHRDeviation: hrPart?.absolute,
            sleepHours: lastNight,
            basis: basis
        )
    }

    // MARK: - Baselines

    /// Today's reading against the median of the preceding days.
    ///
    /// Median rather than mean: one dreadful night, or one artefact from a ring
    /// worn loose, should not drag the thing today is being judged against.
    private static func deviation(
        in samples: [HealthSample],
        now: Date,
        calendar: Calendar
    ) -> (ratio: Double, absolute: Double)? {
        guard let today = mostRecent(in: samples, now: now, calendar: calendar) else {
            return nil
        }
        let cutoff = calendar.date(byAdding: .day, value: -baselineDays, to: now) ?? now
        let history = samples
            .filter { $0.date >= cutoff && !calendar.isDate($0.date, inSameDayAs: now) }
            .map(\.value)

        guard history.count >= minimumBaselineDays, let baseline = median(history),
              baseline > 0 else { return nil }

        return ((today - baseline) / baseline, today - baseline)
    }

    /// The most recent reading, provided it's from today or last night.
    ///
    /// Stale data is worse than absent data here — a readiness score computed
    /// from Tuesday's sleep, shown on Friday, is simply wrong.
    private static func mostRecent(
        in samples: [HealthSample],
        now: Date,
        calendar: Calendar
    ) -> Double? {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        return samples
            .filter { calendar.isDate($0.date, inSameDayAs: now)
                   || calendar.isDate($0.date, inSameDayAs: yesterday) }
            .max { $0.date < $1.date }?
            .value
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    // MARK: - Scoring helpers

    /// Maps a deviation onto 0…1, with baseline sitting at 0.5.
    private static func normalised(_ deviation: Double, span: Double) -> Double {
        clamp(0.5 + (deviation / span) * 0.5, 0, 1)
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }

    private static func percent(_ ratio: Double) -> String {
        "\(Int((abs(ratio) * 100).rounded()))%"
    }

    private static func hoursText(_ hours: Double) -> String {
        let whole = Int(hours)
        let minutes = Int(((hours - Double(whole)) * 60).rounded())
        return minutes == 0 ? "\(whole)h" : "\(whole)h\(minutes)"
    }
}
