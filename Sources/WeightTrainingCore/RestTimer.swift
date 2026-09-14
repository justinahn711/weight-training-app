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
