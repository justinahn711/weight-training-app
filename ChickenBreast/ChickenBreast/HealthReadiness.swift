//
//  HealthReadiness.swift
//  ChickenBreast
//

import Foundation
import HealthKit
import WeightTrainingCore

/// Reads recovery data out of HealthKit (#26).
///
/// Read-only and source-agnostic. Oura writes sleep stages, HRV, resting heart
/// rate and respiratory rate into Health; so do a watch, a chest strap, or a
/// person typing. This asks Health for the measure and never asks who wrote it,
/// which is the difference between supporting a ring and supporting every ring.
///
/// Nothing here writes, and nothing here is required: a phone with no Health
/// data, or with permission refused, simply produces no readiness and the app
/// carries on. Recovery is context, not a dependency.
@MainActor
final class HealthReadiness {
    private let store = HKHealthStore()

    /// The measures asked for, and the only ones.
    ///
    /// Respiratory rate is deliberately not requested despite #26 listing it as
    /// available: nothing consumes it yet, and asking for data that goes unused
    /// is how a Health permission sheet turns into something people decline.
    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        if let hrv = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) {
            types.insert(hrv)
        }
        if let restingHR = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) {
            types.insert(restingHR)
        }
        // Asked for because resting heart rate often arrives here instead (#59).
        if let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            types.insert(heartRate)
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        return types
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Asks once, at launch.
    ///
    /// HealthKit cannot return anything without authorisation, so #26's "never
    /// prompts" has to mean "asks once and then never again" rather than
    /// literally never — which is what this does. iOS shows its own sheet a
    /// single time, and declining is remembered and respected.
    ///
    /// Note that iOS never reports read permission back: `getRequestStatus`
    /// tells you whether asking is still needed, and a refusal is
    /// indistinguishable from having no data at all. So there is no state to
    /// keep here — the query simply comes back empty.
    func requestAccess() async {
        guard isAvailable else { return }
        try? await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// Today's readiness, or nil when Health has nothing to say.
    func current(now: Date = Date()) async -> Readiness? {
        guard isAvailable else { return nil }

        async let hrv = dailyAverages(.heartRateVariabilitySDNN,
                                      unit: HKUnit.secondUnit(with: .milli), now: now)
        async let restingHR = dailyAverages(.restingHeartRate,
                                            unit: HKUnit.count().unitDivided(by: .minute()),
                                            now: now)
        async let asleep = asleepIntervals()

        let nights = await asleep
        let resting = await restingHR

        return Readiness.from(
            hrv: await hrv,
            // Derived from the overnight series when Apple's dedicated type is
            // empty (#59). Oura exports resting heart rate into the Heart Rate
            // category rather than that type, so a phone with a perfectly good
            // sync reports none at all and readiness runs on sleep alone.
            restingHR: resting.isEmpty ? await derivedRestingHR(asleep: nights) : resting,
            sleep: SleepSummary.hoursPerNight(nights),
            now: now
        )
    }

    /// Resting heart rate rebuilt from the beats recorded while asleep.
    private func derivedRestingHR(asleep: [SleepInterval]) async -> [HealthSample] {
        guard !asleep.isEmpty else { return [] }
        return RestingHeartRate.perNight(heartRate: await heartRateSamples(), asleep: asleep)
    }

    // MARK: - Queries

    private var window: DateInterval {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day,
                                          value: -(Readiness.baselineDays + 1),
                                          to: end) ?? end
        return DateInterval(start: start, end: end)
    }

    /// One value per day, averaged.
    ///
    /// Averaged rather than taken raw because a ring writes many HRV samples a
    /// night, and a single reading picked arbitrarily from among them is noise
    /// dressed as a measurement.
    private func dailyAverages(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        now: Date
    ) async -> [HealthSample] {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
            return []
        }
        let interval = window
        let predicate = HKQuery.predicateForSamples(withStart: interval.start,
                                                    end: interval.end)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage,
                anchorDate: Calendar.current.startOfDay(for: interval.start),
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, results, _ in
                var samples: [HealthSample] = []
                results?.enumerateStatistics(from: interval.start, to: interval.end) { stat, _ in
                    if let average = stat.averageQuantity() {
                        samples.append(HealthSample(date: stat.startDate,
                                                    value: average.doubleValue(for: unit)))
                    }
                }
                continuation.resume(returning: samples)
            }
            store.execute(query)
        }
    }

    /// Every heart-rate sample in the window, timestamps intact.
    ///
    /// Not averaged per day like the other measures: the whole point is to find
    /// the floor of a night, and a daily average has already thrown that away.
    private func heartRateSamples() async -> [HealthSample] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            return []
        }
        let interval = window
        let unit = HKUnit.count().unitDivided(by: .minute())
        let predicate = HKQuery.predicateForSamples(withStart: interval.start,
                                                    end: interval.end)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                                   ascending: true)]
            ) { _, results, _ in
                let samples = (results as? [HKQuantitySample] ?? []).map {
                    HealthSample(date: $0.startDate, value: $0.quantity.doubleValue(for: unit))
                }
                continuation.resume(returning: samples)
            }
            store.execute(query)
        }
    }

    /// The stretches spent asleep.
    ///
    /// Sums the asleep stages rather than measuring time in bed: Oura writes
    /// core, deep and REM separately, and counting the gaps between them would
    /// credit a night spent awake staring at the ceiling.
    private func asleepIntervals() async -> [SleepInterval] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return []
        }
        let interval = window
        let predicate = HKQuery.predicateForSamples(withStart: interval.start,
                                                    end: interval.end)

        let samples: [HKCategorySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate,
                                                   ascending: true)]
            ) { _, results, _ in
                continuation.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }

        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]

        return samples
            .filter { asleep.contains($0.value) }
            .map { SleepInterval(start: $0.startDate, end: $0.endDate) }
    }
}
