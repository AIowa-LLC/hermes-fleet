import Foundation
import os

// F0 — performance signposts.
//
// `FleetSignposts` wraps `OSSignposter(subsystem: "com.aiowa.hermesfleet",
// category: "perf")` behind a tiny vocabulary of named intervals so the
// networking and UI layers can measure the cached-first launch promise
// without importing each other (both already depend on FleetCore).
//
// Privacy by construction: an interval carries NO caller-supplied strings.
// Names come from the closed `FleetSignpostInterval` enum, the end marker
// from the closed `FleetSignpostOutcome` / `FleetSignpostVariant` enums, and
// the only dynamic value is an integer count emitted with `privacy: .private`.
// A hostname, session id, title, or bot name has no way to reach a signpost,
// the in-memory stats, or the diagnostics report.

/// The named performance intervals. Raw values are the stable trace names
/// shown in Instruments / `log stream --signpost`.
public enum FleetSignpostInterval: String, Sendable, CaseIterable {
    /// `App.init` to the first cached roster being visible.
    case launchToPaint = "launch.to-paint"
    /// Ticket mint / auth to `gateway.ready` for one gateway connect.
    case gatewayConnect = "gateway.connect"
    /// One reconnect replay pass (count = events replayed).
    case replayPass = "replay.pass"
    /// Route open to the first transcript rows rendered.
    case transcriptOpen = "transcript.open"
}

/// How an interval ended. `cancelled` is the marker for flows torn down (or
/// abandoned) before they settled, so an interval never leaks open.
public enum FleetSignpostOutcome: String, Sendable {
    case completed
    case failed
    case cancelled
}

/// Which path satisfied an interval (only meaningful for a completed one).
public enum FleetSignpostVariant: String, Sendable {
    /// Satisfied from the on-device cache.
    case cached
    /// Satisfied from the live gateway.
    case live
    /// Settled with nothing to show (no cache / empty transcript).
    case empty
}

/// One begin or end emission. Deliberately free of any string that is not a
/// closed-vocabulary enum raw value.
public struct FleetSignpostEvent: Sendable, Equatable {
    public enum Phase: String, Sendable { case begin, end }

    public let phase: Phase
    public let interval: FleetSignpostInterval
    /// Non-identifying per-interval id (a process-local counter).
    public let intervalID: UInt64
    public let outcome: FleetSignpostOutcome?
    public let variant: FleetSignpostVariant?
    public let count: Int?

    public init(
        phase: Phase,
        interval: FleetSignpostInterval,
        intervalID: UInt64,
        outcome: FleetSignpostOutcome? = nil,
        variant: FleetSignpostVariant? = nil,
        count: Int? = nil
    ) {
        self.phase = phase
        self.interval = interval
        self.intervalID = intervalID
        self.outcome = outcome
        self.variant = variant
        self.count = count
    }
}

/// Destination for signpost emissions. Production uses `FleetOSSignpostSink`;
/// tests inject a recorder (see `FleetSignpostRecorder`).
public protocol FleetSignpostSink: Sendable {
    func emit(_ event: FleetSignpostEvent)
}

/// `OSSignposter`-backed sink. Interval names are `StaticString`s chosen from
/// the closed enum; the end message is a fixed literal per outcome/variant,
/// and the only interpolated value (the count) is `.private`.
public final class FleetOSSignpostSink: FleetSignpostSink, Sendable {
    public static let subsystem = "com.aiowa.hermesfleet"
    public static let category = "perf"

    private struct State: @unchecked Sendable {
        let value: OSSignpostIntervalState
    }

    private let signposter = OSSignposter(subsystem: FleetOSSignpostSink.subsystem,
                                          category: FleetOSSignpostSink.category)
    private let open = OSAllocatedUnfairLock<[UInt64: State]>(initialState: [:])

    public init() {}

    public func emit(_ event: FleetSignpostEvent) {
        guard signposter.isEnabled else { return }
        let name = Self.name(for: event.interval)
        let id = OSSignpostID(event.intervalID)
        switch event.phase {
        case .begin:
            let state = signposter.beginInterval(name, id: id)
            open.withLock { $0[event.intervalID] = State(value: state) }
        case .end:
            guard let state = open.withLock({ $0.removeValue(forKey: event.intervalID) }) else { return }
            end(name, state.value, event)
        }
    }

    private static func name(for interval: FleetSignpostInterval) -> StaticString {
        switch interval {
        case .launchToPaint: return "launch.to-paint"
        case .gatewayConnect: return "gateway.connect"
        case .replayPass: return "replay.pass"
        case .transcriptOpen: return "transcript.open"
        }
    }

    private func end(_ name: StaticString, _ state: OSSignpostIntervalState, _ event: FleetSignpostEvent) {
        if let count = event.count {
            switch event.outcome ?? .completed {
            case .completed:
                signposter.endInterval(name, state, "completed count=\(count, privacy: .private)")
            case .failed:
                signposter.endInterval(name, state, "failed count=\(count, privacy: .private)")
            case .cancelled:
                signposter.endInterval(name, state, "cancelled count=\(count, privacy: .private)")
            }
            return
        }
        switch (event.outcome ?? .completed, event.variant) {
        case (.completed, .cached?): signposter.endInterval(name, state, "completed cached")
        case (.completed, .live?): signposter.endInterval(name, state, "completed live")
        case (.completed, .empty?): signposter.endInterval(name, state, "completed empty")
        case (.completed, nil): signposter.endInterval(name, state, "completed")
        case (.failed, _): signposter.endInterval(name, state, "failed")
        case (.cancelled, _): signposter.endInterval(name, state, "cancelled")
        }
    }
}

/// A live interval. Ends exactly once: later `end` calls are ignored, and an
/// interval released without an explicit end is closed as `cancelled` so it
/// can never leak open in a trace.
public final class FleetSignpostToken: Sendable {
    private let owner: FleetSignposts
    public let interval: FleetSignpostInterval
    public let intervalID: UInt64
    private let started: ContinuousClock.Instant
    private let didEnd = OSAllocatedUnfairLock(initialState: false)

    fileprivate init(owner: FleetSignposts, interval: FleetSignpostInterval,
                     intervalID: UInt64, started: ContinuousClock.Instant) {
        self.owner = owner
        self.interval = interval
        self.intervalID = intervalID
        self.started = started
    }

    deinit {
        finish(.cancelled, variant: nil, count: nil)
    }

    /// End the interval. Idempotent: only the first call is recorded.
    public func end(
        _ outcome: FleetSignpostOutcome = .completed,
        variant: FleetSignpostVariant? = nil,
        count: Int? = nil
    ) {
        finish(outcome, variant: variant, count: count)
    }

    /// End the interval for a thrown error: `cancelled` for cancellation,
    /// `failed` otherwise. The error itself is never recorded.
    public func end(after error: any Error) {
        let cancelled = error is CancellationError || Task.isCancelled
        finish(cancelled ? .cancelled : .failed, variant: nil, count: nil)
    }

    private func finish(_ outcome: FleetSignpostOutcome,
                        variant: FleetSignpostVariant?, count: Int?) {
        let first = didEnd.withLock { ended -> Bool in
            if ended { return false }
            ended = true
            return true
        }
        guard first else { return }
        owner.finished(self, outcome: outcome, variant: variant, count: count,
                       duration: ContinuousClock.now - started)
    }
}

/// Entry point for signposting. Use `FleetSignposts.shared` in the app; tests
/// build their own instance with a recording sink and private stats.
public final class FleetSignposts: Sendable {
    public static let shared = FleetSignposts(
        sink: FleetOSSignpostSink(), stats: FleetPerformanceStats.shared)

    private let sink: any FleetSignpostSink
    private let stats: FleetPerformanceStats?
    private let nextID = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private let launch = OSAllocatedUnfairLock<FleetSignpostToken?>(initialState: nil)

    public init(sink: any FleetSignpostSink, stats: FleetPerformanceStats? = nil) {
        self.sink = sink
        self.stats = stats
    }

    /// Begin a named interval. Keep this off hot per-token paths.
    public func begin(_ interval: FleetSignpostInterval) -> FleetSignpostToken {
        let id = nextID.withLock { value -> UInt64 in
            value += 1
            return value
        }
        sink.emit(FleetSignpostEvent(phase: .begin, interval: interval, intervalID: id))
        return FleetSignpostToken(owner: self, interval: interval, intervalID: id,
                                  started: ContinuousClock.now)
    }

    /// Begin `launch.to-paint` once per process (later calls are no-ops).
    public func beginLaunchToPaint() {
        launch.withLock { token in
            if token == nil { token = begin(.launchToPaint) }
        }
    }

    /// End `launch.to-paint` (first call wins; a no-op when never begun, e.g.
    /// in tests). Releases the held token.
    public func endLaunchToPaint(variant: FleetSignpostVariant, count: Int? = nil) {
        let token = launch.withLock { $0 }
        token?.end(variant: variant, count: count)
    }

    fileprivate func finished(
        _ token: FleetSignpostToken, outcome: FleetSignpostOutcome,
        variant: FleetSignpostVariant?, count: Int?, duration: Duration
    ) {
        sink.emit(FleetSignpostEvent(
            phase: .end, interval: token.interval, intervalID: token.intervalID,
            outcome: outcome, variant: variant, count: count))
        stats?.record(interval: token.interval, outcome: outcome, variant: variant,
                      count: count, duration: duration)
    }
}

#if DEBUG
/// DEBUG/test-only assertion helper: records every emission so a test can
/// verify an interval began and ended exactly once, and that no emitted
/// string carries a caller identifier.
public final class FleetSignpostRecorder: FleetSignpostSink, Sendable {
    private let storage = OSAllocatedUnfairLock<[FleetSignpostEvent]>(initialState: [])

    public init() {}

    public func emit(_ event: FleetSignpostEvent) {
        storage.withLock { $0.append(event) }
    }

    public var events: [FleetSignpostEvent] { storage.withLock { $0 } }

    public func beginCount(_ interval: FleetSignpostInterval) -> Int {
        events.filter { $0.phase == .begin && $0.interval == interval }.count
    }

    public func endEvents(_ interval: FleetSignpostInterval) -> [FleetSignpostEvent] {
        events.filter { $0.phase == .end && $0.interval == interval }
    }

    /// True when every begin has exactly one matching end and nothing ended
    /// twice or without beginning.
    public func isBalanced(_ interval: FleetSignpostInterval) -> Bool {
        let begins = events.filter { $0.phase == .begin && $0.interval == interval }.map(\.intervalID)
        let ends = events.filter { $0.phase == .end && $0.interval == interval }.map(\.intervalID)
        return begins.sorted() == ends.sorted() && Set(begins).count == begins.count
    }

    /// Every string this recorder's events could render into a trace: names,
    /// outcomes, variants, and counts. Tests assert identifiers are absent.
    public var renderedStrings: [String] {
        events.flatMap { event -> [String] in
            var strings = [event.phase.rawValue, event.interval.rawValue]
            if let outcome = event.outcome { strings.append(outcome.rawValue) }
            if let variant = event.variant { strings.append(variant.rawValue) }
            if let count = event.count { strings.append(String(count)) }
            return strings
        }
    }
}
#endif
