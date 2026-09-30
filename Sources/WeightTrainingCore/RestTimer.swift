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
    ///
    /// Optional because not every rest is anchored to a set. A rest started by
    /// hand — the voice `.startTimer` command, or a deliberate restart when
    /// none is running (#173) — has no `SetRecord` to point at. Before this it
    /// was non-optional, which forced the voice path to fabricate a `UUID()`
    /// that named a set that never existed; `nil` says plainly that this rest
    /// isn't tied to one, and undo (keyed on `setID == record.id`) simply never
    /// matches it, which is the correct behaviour — there's nothing to undo.
    public let setID: UUID?

    public init(startedAt: Date, duration: TimeInterval, setID: UUID?) {
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

    /// How long the count-up runs past the target before the clock gives up.
    ///
    /// Rest running long is information (see `overrun`), but a clock counting
    /// into a second hour is not: it means the phone was put down, not that
    /// anyone is resting. Ten minutes is past any real rest and short enough
    /// that a forgotten session stops claiming to be one.
    public static let maximumOverrun: TimeInterval = 600

    /// When the clock stops counting and the rest is treated as abandoned.
    public var expiresAt: Date {
        endsAt.addingTimeInterval(RestTimer.maximumOverrun)
    }

    public func hasExpired(at now: Date) -> Bool {
        now >= expiresAt
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

    /// Rebuilds a rest from a Live Activity's content state after a lock or a
    /// relaunch (#200).
    ///
    /// `restStartedAt`/`restSetID` are the timer's own identity, kept
    /// separate from `lastLoggedSetID` on purpose — the set named there is
    /// the Undo offer, not necessarily what this rest is timing. Before #200
    /// the only way to rebuild a rest was through that logged set, which is
    /// exactly why a rest started by hand or by voice (`setID == nil`,
    /// #173/#195) had nothing to survive a lock with.
    ///
    /// `restStartedAt` is nil only for an activity written by a build before
    /// this fix — both new fields are always set together from here on, so
    /// its absence is the signal, not something to check per field. For that
    /// older activity every rest it could have produced was implied by the
    /// logged set, exactly the way it used to be, so `loggedSet` is consulted
    /// only in that branch: falling back to it once the new fields exist
    /// would silently reattach a hand-started rest to an unrelated, older
    /// Undo offer.
    public static func reconciled(
        restEndsAt: Date?,
        restStartedAt: Date?,
        restSetID: UUID?,
        loggedSet: (id: UUID, performedAt: Date)?
    ) -> RestTimer? {
        guard let endsAt = restEndsAt else { return nil }
        if let startedAt = restStartedAt {
            return RestTimer(
                startedAt: startedAt,
                duration: max(0, endsAt.timeIntervalSince(startedAt)),
                setID: restSetID
            )
        }
        guard let loggedSet else { return nil }
        return RestTimer(
            startedAt: loggedSet.performedAt,
            duration: max(0, endsAt.timeIntervalSince(loggedSet.performedAt)),
            setID: loggedSet.id
        )
    }
}

extension RestTimer {
    /// What the lock screen and Dynamic Island draw for the rest (#265).
    ///
    /// The widget has no app behind it while the phone is locked, so nothing
    /// calls `expireRestIfNeeded` there. It has only `restEndsAt` and the
    /// moment it is rendered, and it gets a guaranteed re-render just once, at
    /// the stale date (`restEndsAt`). This decides the face from those alone,
    /// so it follows the app's own rule rather than a second copy of it.
    public enum LockScreenFace: Equatable {
        /// No clock: the face `expireRestIfNeeded` publishes, with Log back.
        case noRest
        /// Counting down to the target.
        case countingDown(to: Date)
        /// Counting up from the target. The range ends at the cap, so the
        /// system's own ticking stops at `maximumOverrun` rather than
        /// running on for an hour as it used to.
        case overrun(ClosedRange<Date>)

        /// Says which clock is being read, since a countdown and an overrun
        /// look alike at a glance.
        public var caption: String {
            switch self {
            case .noRest: "ready"
            case .countingDown: "resting"
            case .overrun: "over"
            }
        }
    }

    /// Past the cap the face is `.noRest`: the same thing the app shows once
    /// `expireRestIfNeeded` has run, so unlocking never reveals the two
    /// disagreeing about whether a rest exists. The alternative, a fixed
    /// "10:00+", was rejected because it is still a rest the app no longer
    /// has.
    ///
    /// The render time decides, not the activity's `isStale` flag, which can
    /// lag the clock — a countdown range starting past its end would trap.
    ///
    /// A face rendered before the cap and not re-rendered after it holds its
    /// count-up at the cap's value (`10:00`, "over"), because that is where a
    /// `Text(timerInterval:)` range stops. It stops counting there, which is
    /// the promise; the switch to `.noRest` waits for the system's next render
    /// or the next time the app runs.
    public static func lockScreenFace(restEndsAt: Date?, now: Date) -> LockScreenFace {
        guard let endsAt = restEndsAt else { return .noRest }
        if now < endsAt { return .countingDown(to: endsAt) }
        let cap = endsAt.addingTimeInterval(maximumOverrun)
        if now >= cap { return .noRest }
        return .overrun(endsAt...cap)
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

    /// Rest between working sets: the lift's own override if the person set
    /// one, otherwise 3 minutes on compounds / 90 seconds on isolation.
    ///
    /// The gym report behind #174 was "keep defaults the same but let me
    /// adjust" — not a request to change the heuristic, so it stays exactly
    /// as it was, consulted only when `restOverride` is nil.
    public var restTarget: TimeInterval {
        restOverride ?? (isCompound ? 180 : 90)
    }
}
