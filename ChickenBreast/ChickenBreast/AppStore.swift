//
//  AppStore.swift
//  ChickenBreast
//

import ActivityKit
import Foundation
import UserNotifications
import WeightTrainingCore
import WeightTrainingStore

/// The process's one `TrainingStore`.
///
/// Exists because the session screen is no longer the only thing that writes.
/// A Live Activity button runs a `LiveActivityIntent` in this same process but
/// outside any view (#23), and if it opened its own store there would be two
/// `ModelContainer`s over one file: two caches that don't see each other's
/// writes, so a set logged from the lock screen would be missing from the
/// session screen until relaunch.
///
/// Opened lazily and kept, rather than injected, because the intent has nothing
/// to be injected from — it's constructed by the system.
@MainActor
final class AppStore {
    static let shared = AppStore()

    private var opened: TrainingStore?

    private init() {}

    /// The store, opening it on first use.
    ///
    /// Sync is requested here rather than at each call site so every entry
    /// point — the app launching, an intent firing on a locked phone — gets the
    /// same store with the same CloudKit configuration.
    func store() throws -> TrainingStore {
        if let opened { return opened }
        #if DEBUG
        if UITestLaunchState.usesIsolatedStore {
            let store = try TrainingStore(url: UITestLaunchState.prepareStore(), syncsWithCloudKit: false)
            opened = store
            return store
        }
        #endif
        let store = try TrainingStore(syncsWithCloudKit: true)
        opened = store
        return store
    }
}

#if DEBUG
/// A known starting state for each UI test (#285).
///
/// The UI suite used to share one on-disk store across every test in a run,
/// so each test inherited whatever the previous one left: a workout draft to
/// resume, parked on any exercise, sometimes with a rest still counting down
/// on the Live Activity that `reconcileLiveActivityActions` adopts back into
/// the session. The tests had grown tolerances for that, but a tolerance is
/// not a known state, and a rest carried in from an earlier test made one
/// audit's result depend on test order (#289).
///
/// Launch arguments, passed only by `ChickenBreastUITestCase`:
///
/// - `-UITestIsolatedStore` opens a separate store file that never mirrors
///   to CloudKit, instead of the lifter's store. A UI test never reads or
///   writes real training data, and never talks to iCloud.
/// - `-UITestResetState` deletes that isolated store before opening it, and
///   ends any Live Activity and pending rest alert an earlier launch left.
///   It only ever deletes the isolated store: without the first argument it
///   does nothing, so no argument combination can wipe the real one.
/// - `-UITestSeedYesterday` logs one working set of Incline DB Press, dated
///   yesterday at midday, into that isolated store (#293). A lift with
///   history from an earlier day is what most sessions open on — the full
///   Target / Last time card — and no UI test can reach it by tapping,
///   because a set logged today shows as today's work instead. Isolated
///   store only, like the reset.
///
/// Debug-only. The file header of `UITestSupport.swift` used to argue against
/// any test-only branch in startup because it would outlive the test; a
/// release build does not contain this code at all, and nothing but a
/// launch argument (which only Xcode and XCUITest pass) reaches it.
enum UITestLaunchState {
    static let isolatedStoreArgument = "-UITestIsolatedStore"
    static let resetArgument = "-UITestResetState"
    static let seedYesterdayArgument = "-UITestSeedYesterday"

    static var usesIsolatedStore: Bool {
        ProcessInfo.processInfo.arguments.contains(isolatedStoreArgument)
    }

    static var resets: Bool {
        usesIsolatedStore && ProcessInfo.processInfo.arguments.contains(resetArgument)
    }

    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "UITests", directoryHint: .isDirectory)
    }

    /// The isolated store's URL, emptied first when this launch resets.
    /// The whole directory goes, so SQLite's `-wal`/`-shm` go with it.
    static func prepareStore() throws -> URL {
        if resets, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "ChickenBreast-UITests.store")
    }

    /// See `-UITestSeedYesterday` above. Runs after the library is seeded,
    /// since the set needs a lift to belong to; midday, not an offset from
    /// now, so a run near midnight can't land it on the wrong day (#79).
    static func seedYesterdayIfAsked(_ store: TrainingStore) throws {
        guard usesIsolatedStore,
              ProcessInfo.processInfo.arguments.contains(seedYesterdayArgument),
              let lift = try store.exercises().first(where: { $0.name == "Incline DB Press" })
        else { return }
        let calendar = Calendar.current
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()),
              let midday = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: yesterday)
        else { return }
        try store.log(SetRecord(exerciseID: lift.id, load: Load(40), reps: 8, rpe: RPE(8), performedAt: midday))
    }

    /// Ends what outlives the process: a Live Activity (and the rest on it)
    /// and a rest alert still pending from an earlier test's rest, which
    /// would otherwise arrive as a banner over a later test.
    static func clearProcessStateIfResetting() {
        guard resets else { return }
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        Task {
            for activity in Activity<SessionActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
#endif
