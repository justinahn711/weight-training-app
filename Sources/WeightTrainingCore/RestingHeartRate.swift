import Foundation

/// Reconstructs a resting heart rate from an overnight heart-rate series.
///
/// Exists because the measure is present but not where Apple keeps it (#59).
/// Oura exports resting heart rate into Health's Heart Rate category rather
/// than reliably populating the dedicated `restingHeartRate` type, so a phone
/// with a perfectly good sync reports no resting heart rate at all and
/// readiness ends up running on sleep alone.
///
/// A resting heart rate is the floor of your night, so that is what this takes:
/// a low percentile of the beats recorded while you were actually asleep.
/// Bounded to the sleep intervals rather than to clock hours, because "midnight
/// to eight" is a guess about someone's life, and a late night would measure
/// them walking around.
public enum RestingHeartRate {

    /// How far into the sorted night to read.
    ///
    /// Not the minimum. A single low sample is as likely to be an artefact as a
    /// measurement, and one bad reading would then set the baseline that every
    /// later night is judged against.
    public static let percentile = 0.05

    /// One resting heart rate per night, attributed to the morning it ended on.
    ///
    /// - Parameters:
    ///   - heartRate: every heart-rate sample available, in any order.
    ///   - asleep: the stretches actually spent asleep.
    public static func perNight(
        heartRate: [HealthSample],
        asleep: [SleepInterval],
        calendar: Calendar = .current
    ) -> [HealthSample] {
        let nights = SleepSummary.union(of: asleep)
        guard !nights.isEmpty, !heartRate.isEmpty else { return [] }

        let sorted = heartRate.sorted { $0.date < $1.date }
        var byMorning: [Date: [Double]] = [:]

        for night in nights {
            let during = sorted
                .drop { $0.date < night.start }
                .prefix { $0.date <= night.end }
                .map(\.value)
            guard !during.isEmpty else { continue }
            let morning = calendar.startOfDay(for: night.end)
            byMorning[morning, default: []] += during
        }

        return byMorning
            .compactMap { morning, values in
                lowPercentile(of: values).map { HealthSample(date: morning, value: $0) }
            }
            .sorted { $0.date < $1.date }
    }

    /// The value `percentile` of the way up the sorted list.
    static func lowPercentile(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * percentile).rounded())
        return sorted[index]
    }
}
