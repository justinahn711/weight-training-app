import Foundation

/// The rest clock between sets.
///
/// Stores *when the rest started* rather than a count that ticks down. Every
/// reading is computed from wall-clock time, so the timer is automatically
/// correct after the app is backgrounded, the screen locks, or the process is
/// killed and relaunched — there is no running state to lose. That's the whole
/// requirement in #6, and a decrementing counter cannot satisfy it.
public struct RestTimer: Hashable, Sendable {
    public let startedAt: Date
    public let duration: TimeInterval

    /// The set that started this rest, so undoing that set can take the timer
    /// away with it (#8).
    public let setID: UUID

    public init(startedAt: Date, duration: TimeInterval, setID: UUID) {
        self.startedAt = startedAt
        self.duration = duration
        self.setID = setID
    }

    public var endsAt: Date {
        startedAt.addingTimeInterval(duration)
    }

    /// Seconds left, floored at zero.
    public func remaining(at now: Date) -> TimeInterval {
        max(0, endsAt.timeIntervalSince(now))
    }

    /// Seconds past the target, which keeps counting up.
    ///
    /// Rest running long is information, not an error — it's the first sign a
    /// session is dragging — so the clock never stops or hides itself.
    public func overrun(at now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(endsAt))
    }

    public func isComplete(at now: Date) -> Bool {
        now >= endsAt
    }

    /// `2:30`, or `+0:45` once the target has passed.
    public func displayTime(at now: Date) -> String {
        let complete = isComplete(at: now)
        let seconds = Int((complete ? overrun(at: now) : remaining(at: now)).rounded())
        let formatted = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return complete ? "+\(formatted)" : formatted
    }

    /// Fraction elapsed, 0 to 1, for a progress ring.
    public func progress(at now: Date) -> Double {
        guard duration > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(startedAt) / duration))
    }
}

extension Exercise {
    /// Whether the lift is heavy enough to need a full rest.
    ///
    /// A crude split, and deliberately so: anything involving three or more
    /// muscles, or built from plates on a bar, is systemically taxing enough
    /// that cutting rest short costs reps on the next set. Everything else is
    /// an isolation movement where a shorter rest is fine.
    ///
    /// This is a starting point rather than a prescription — the timer is a
    /// suggestion that can be skipped, in keeping with the app suggesting and
    /// never deciding.
    public var isCompound: Bool {
        muscles.count >= 3 || equipment.isPlateBuilt
    }

    /// Default rest between working sets: 3 minutes on compounds, 90 seconds
    /// on isolation.
    public var restTarget: TimeInterval {
        isCompound ? 180 : 90
    }
}
