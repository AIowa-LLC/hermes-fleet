import Foundation
import os
import FleetCore

/// Transport-side connection state machine. Richer than `TransportState`
/// (which is what FleetCore's seam exposes); maps cleanly onto it.
public enum ConnectionState: Sendable, Hashable, Equatable {
    /// No socket exists.
    case idle
    /// Socket handshake in progress; waiting for `gateway.ready`.
    case connecting
    /// Socket open AND `gateway.ready` received — fully connected.
    case open
    /// Cleanly closed (client requested or server normal closure).
    case closed
    /// Failed/abnormal termination, with a human + machine-readable reason.
    case error(DisconnectReason)

    /// Map onto the FleetCore seam's observable state.
    public var transportState: TransportState {
        switch self {
        case .idle: return .disconnected
        case .connecting: return .connecting
        case .open: return .connected
        case .closed: return .disconnected
        case .error(let reason): return .failed(reason.debugDescription)
        }
    }
}

/// Timeouts/heartbeat knobs for the transport. Defaults match the reference
/// client (`apps/shared/src/json-rpc-gateway.ts`): 15s ping / tiered inbound
/// liveness (Hermex #227 pattern — see `ConnectionLivenessTiming`) / 15s
/// connect / 120s request.
public struct TransportConfiguration: Sendable, Equatable {
    public var pingInterval: Duration
    /// Tiered heartbeat-freshness liveness windows (t_a07ca37e): silence is
    /// evaluated against transportFresh (12s — provably alive, skip status
    /// polls) / reconnect (18s) / reconnect-while-tool-in-flight (25s), with
    /// the active check running at `checkingInterval` (5s) cadence. Stored
    /// as `ConnectionLivenessTiming` so one named type owns the constants.
    public var livenessTiming: ConnectionLivenessTiming
    public var connectTimeout: Duration
    public var requestTimeout: Duration
    /// P1-4: maximum CONSECUTIVE junk frames (binary data, or text that fails
    /// JSON-RPC decode) tolerated before the transport closes + classifies the
    /// connection as abnormal. Junk frames never refresh liveness, so this
    /// bounds how long a malformed/bad peer can masquerade as alive.
    public var malformedFrameLimit: Int
    /// P0.1: whether this transport tells the gateway, once per connection
    /// after `gateway.ready`, that its owner answers server→client requests
    /// (`client.capabilities {server_requests: true}`). Only the conversation
    /// transport — the one whose screen renders approval / clarify / sudo /
    /// secret prompts — opts in. A transport that advertised without a UI
    /// behind it would make the gateway park prompts nobody can answer
    /// instead of failing fast.
    public var advertisesServerRequests: Bool

    /// Convenience accessor for the flat inbound deadline implied by the
    /// tiered windows (the reconnect window extended for in-flight tool
    /// calls): kept for tests + the H2 env override which reason in seconds.
    public var inboundDeadline: Duration {
        .seconds(livenessTiming.runningToolReconnectInterval)
    }

    public init(
        pingInterval: Duration = .seconds(15),
        livenessTiming: ConnectionLivenessTiming = .standard,
        connectTimeout: Duration = .seconds(15),
        requestTimeout: Duration = .seconds(120),
        malformedFrameLimit: Int = 8,
        advertisesServerRequests: Bool = false
    ) {
        self.pingInterval = pingInterval
        self.livenessTiming = livenessTiming
        self.connectTimeout = connectTimeout
        self.requestTimeout = requestTimeout
        self.malformedFrameLimit = malformedFrameLimit
        self.advertisesServerRequests = advertisesServerRequests
    }

    /// Legacy flat-deadline init (t_a07ca37e compat): maps the pre-tiering
    /// single `inboundDeadline` onto equivalent tiered windows so existing
    /// call sites/tests keep their exact teardown timing — fresh below half
    /// the deadline, stale (teardown) at the deadline, no tool extension
    /// (the flat deadline never extended for tools). The check cadence
    /// collapses below 5s for sub-5s deadlines so short-window tests still
    /// evaluate promptly. New code should pass `livenessTiming:` directly.
    public init(
        pingInterval: Duration = .seconds(15),
        inboundDeadline: Duration,
        connectTimeout: Duration = .seconds(15),
        requestTimeout: Duration = .seconds(120),
        malformedFrameLimit: Int = 8,
        advertisesServerRequests: Bool = false
    ) {
        let seconds = max(0.05, Double(inboundDeadline.components.seconds)
            + Double(inboundDeadline.components.attoseconds) / 1_000_000_000_000_000_000)
        self.init(
            pingInterval: pingInterval,
            livenessTiming: ConnectionLivenessTiming(
                checkingInterval: min(5, seconds / 2),
                transportFreshInterval: seconds / 2,
                reconnectInterval: seconds,
                runningToolReconnectInterval: seconds
            ),
            connectTimeout: connectTimeout,
            requestTimeout: requestTimeout,
            malformedFrameLimit: malformedFrameLimit,
            advertisesServerRequests: advertisesServerRequests
        )
    }

    public static let standard = TransportConfiguration()

    /// P0.1: the conversation transport — `standard` timing, and it
    /// advertises `client.capabilities {server_requests: true}` because the
    /// conversation screen answers approval / clarify / sudo / secret requests.
    public static let conversation = TransportConfiguration(advertisesServerRequests: true)
}

/// Thread-safe box for the observable `TransportState` so the actor can expose
/// a `nonisolated` property. Uses `OSAllocatedUnfairLock` (async-safe scoped
/// locking) — `NSLock` is unavailable from async contexts on this toolchain.
public final class TransportStateBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<TransportState>(initialState: .disconnected)

    public init(_ initial: TransportState = .disconnected) {
        lock.withLock { $0 = initial }
    }

    public var current: TransportState {
        lock.withLock { $0 }
    }

    public func set(_ newValue: TransportState) {
        lock.withLock { $0 = newValue }
    }
}
