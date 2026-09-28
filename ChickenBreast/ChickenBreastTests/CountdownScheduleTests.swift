import SwiftUI
import XCTest
@testable import ChickenBreast

/// The voice auto-commit ring's clock (#238): ticks counted back from the
/// deadline, so the last one lands on it at any tick rate.
final class CountdownScheduleTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    /// Seconds left at each tick, to the millisecond — date arithmetic isn't
    /// exact, and a tick 1e-13s off the whole second is still on it.
    private func left(_ ticks: [Date], _ deadline: Date) -> [Double] {
        ticks.map { (deadline.timeIntervalSince($0) * 1000).rounded() / 1000 }
    }

    func test_oneTickASecond_stepsInWholeSecondsAndEndsOnTheDeadline() {
        let deadline = start.addingTimeInterval(3)
        let ticks = CountdownSchedule(deadline: deadline, interval: 1)
            .entries(from: start, mode: .normal)
        XCTAssertEqual(left(ticks, deadline), [3, 2, 1, 0])
    }

    func test_aLateStart_stillEndsOnTheDeadlineNotATickPastIt() {
        // Appeared 0.4s into the countdown: a forward-counting 1s schedule
        // would tick at 2.6s and 1.6s left, then 0.6s *past* the deadline.
        let deadline = start.addingTimeInterval(2.6)
        let ticks = CountdownSchedule(deadline: deadline, interval: 1)
            .entries(from: start, mode: .normal)
        XCTAssertEqual(ticks.last, deadline)
        XCTAssertEqual(left(ticks, deadline), [2.6, 2, 1, 0])
    }

    func test_smoothRate_isStrictlyIncreasingAndEndsOnTheDeadline() {
        let deadline = start.addingTimeInterval(3)
        let ticks = CountdownSchedule(deadline: deadline, interval: 1 / 30)
            .entries(from: start, mode: .normal)
        XCTAssertEqual(ticks.last, deadline)
        XCTAssertTrue(zip(ticks, ticks.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertGreaterThanOrEqual(ticks.count, 90)
    }

    func test_pastTheDeadline_ticksOnceSoTheCommitStillFires() {
        let ticks = CountdownSchedule(deadline: start.addingTimeInterval(-1), interval: 1)
            .entries(from: start, mode: .normal)
        XCTAssertEqual(ticks, [start])
    }
}
