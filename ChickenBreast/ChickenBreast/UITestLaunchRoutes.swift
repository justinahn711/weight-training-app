//
//  UITestLaunchRoutes.swift
//  ChickenBreast
//

#if DEBUG
import Foundation
import WeightTrainingCore
import WeightTrainingStore

/// A screen in a known state, opened from a launch argument.
///
/// An agent changing a view needs to see the result, and before this, every
/// look started from the split cover on an empty store: answer setup, find
/// the day, start it, then log enough sets for the screen to show anything.
/// That run of taps was slow, broke easily, and was repeated for every
/// screenshot. These two arguments skip it:
///
///     sh Tools/sim-open.sh history progress
///
/// which launches with `-UITestIsolatedStore -UITestResetState
/// -UITestFixture history -UITestRoute progress`, checks the process really
/// got them (#321), and waits until the fixture is written.
///
/// - `-UITestFixture <name>` answers first-launch setup with push/pull/legs,
///   so the app opens on Train instead of the split cover. `fresh` stops
///   there. `history` also logs twelve weeks of training, enough to fill
///   History's calendar, Progress's trends and records, and Train's cycle
///   line. It runs only on a store whose setup is still unanswered, so a
///   relaunch without `-UITestResetState` doesn't log the weeks twice.
/// - `-UITestRoute <where>` opens a screen once the store is ready:
///   `train`, `history`, `progress`, `settings`, `preview:<day>` (the
///   roster before a workout starts) or `session:<day>` (a workout started,
///   on its first lift). Opening a day needs the split to exist, so a day
///   route goes with a fixture.
///
/// Both work only on the isolated store, like every other argument in
/// `UITestLaunchState` (`AppStore.swift`), so no argument combination writes
/// to the lifter's real data. App target only: the widget extension compiles
/// `AppStore.swift`, and a route names the app's tabs.
extension UITestLaunchState {
    static let fixtureArgument = "-UITestFixture"
    static let routeArgument = "-UITestRoute"
    static let fixtureWeeks = 12

    enum Fixture: String {
        /// Push/pull/legs chosen, nothing logged: the first day after setup.
        case fresh
        /// Push/pull/legs, three days a week for `fixtureWeeks` weeks.
        case history
    }

    /// Where the app opens once the store is ready.
    enum Route: Equatable {
        case tab(HomeTab)
        case settings
        /// The roster for a day, before it starts (#137).
        case preview(DayKind)
        /// A workout started on that day.
        case session(DayKind)

        init?(_ text: String) {
            let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
            let day = parts.count == 2 ? DayKind(rawValue: parts[1]) : nil
            switch (parts.first, day) {
            case ("preview", let day?): self = .preview(day)
            case ("session", let day?): self = .session(day)
            case ("settings", nil): self = .settings
            default:
                guard parts.count == 1, let tab = HomeTab(rawValue: text) else { return nil }
                self = .tab(tab)
            }
        }
    }

    /// The fixture this launch asked for. A name it doesn't know is logged
    /// and ignored, so a typo shows up in the console instead of quietly
    /// opening on the split cover.
    static var fixture: Fixture? {
        guard usesIsolatedStore, let name = value(after: fixtureArgument) else { return nil }
        guard let fixture = Fixture(rawValue: name) else {
            NSLog("UITestLaunchState: unknown %@ \"%@\", ignored", fixtureArgument, name)
            return nil
        }
        return fixture
    }

    static var route: Route? {
        guard usesIsolatedStore, let text = value(after: routeArgument) else { return nil }
        guard let route = Route(text) else {
            NSLog("UITestLaunchState: unknown %@ \"%@\", ignored", routeArgument, text)
            return nil
        }
        return route
    }

    /// The argument after `flag`, so `-UITestRoute history` reads `history`.
    private static func value(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// Runs after `seedYesterdayIfAsked`, once the library and templates are
    /// seeded, and before the split is read for the cover.
    static func applyFixtureIfAsked(_ store: TrainingStore) throws {
        guard let fixture, try store.gymConfig().trainingSplit == nil else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weeks = fixture == .history ? fixtureWeeks : 0
        let start = calendar.date(byAdding: .day, value: -7 * weeks, to: today) ?? today
        let began = Date()
        var config = try store.gymConfig()
        config.trainingSplit = DayTemplateLibrary.split(.pushPullLegs, startedAt: start)
        try store.saveGymConfig(config)
        if fixture == .history {
            try seedHistory(store, weeks: weeks, from: start, before: today, calendar: calendar)
        }
        // `Tools/sim-open.sh` waits for this line. The history fixture takes
        // a few seconds to write, and a screenshot taken before then shows
        // the launch screen.
        NSLog("UITestLaunchState: fixture %@ ready in %.1fs", fixture.rawValue, Date().timeIntervalSince(began))
    }

    /// Three days a week, push → pull → legs in turn, at midday (#79). Each
    /// slot's due lift gets three working sets at RPE 8, and the load climbs
    /// one increment every second week, so trends rise and records land.
    /// Logged through `logWorkoutSet` and `finishExerciseSessions`, the calls
    /// a real workout makes, so the result is a store the app could really
    /// have. Nothing is logged today, so Train opens on a day that is due,
    /// not one already done.
    private static func seedHistory(_ store: TrainingStore, weeks: Int, from start: Date,
                                    before end: Date, calendar: Calendar) throws {
        let library = Dictionary(try store.exercises().map { ($0.id, $0) }) { first, _ in first }
        let days = DayTemplateLibrary.split(.pushPullLegs).days
        var fills: [UUID: Int] = [:]
        var session = 0
        for week in 0..<weeks {
            for offset in [0, 2, 4] {
                guard let day = calendar.date(byAdding: .day, value: 7 * week + offset, to: start),
                      day < end,
                      let startedAt = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)
                else { continue }
                let template = days[session % days.count]
                session += 1
                try logWorkout(template, week: week, startedAt: startedAt,
                               library: library, fills: &fills, into: store)
            }
        }
    }

    private static func logWorkout(_ template: DayTemplate, week: Int, startedAt: Date,
                                   library: [UUID: Exercise], fills: inout [UUID: Int],
                                   into store: TrainingStore) throws {
        let workoutID = UUID()
        var performedAt = startedAt
        for slot in template.slots {
            defer { fills[slot.id, default: 0] += 1 }
            guard let id = slot.dueCandidate(completionCount: fills[slot.id, default: 0]),
                  let lift = library[id],
                  let first = startingLoad(lift.equipment) else { continue }
            let load = Load(first + Double(week / 2) * lift.increment.pounds)
            for reps in [8, 8, 7] {
                performedAt += 150
                let set = SetRecord(exerciseID: lift.id, load: load, reps: reps, rpe: RPE(8),
                                    performedAt: performedAt)
                _ = try store.logWorkoutSet(set, workoutID: workoutID, startedAt: startedAt,
                                            effortReported: true)
            }
        }
        try store.finishExerciseSessions(workoutID: workoutID, at: performedAt)
    }

    /// A believable first working weight, in pounds. Nil for bodyweight,
    /// whose load depends on a weigh-in this fixture doesn't have.
    private static func startingLoad(_ equipment: Equipment) -> Double? {
        switch equipment {
        case .barbell: return 135
        case .plateLoaded: return 90
        case .dumbbell: return 30
        case .machineStack, .cable: return 50
        case .bodyweight: return nil
        }
    }
}
#endif
