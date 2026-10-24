import Foundation
import FleetCore

/// Bounded retry for gateway RPCs that timed out.
///
/// Only `GatewayRequestCatalog.idempotentReads` are retried. Mutations are
/// attempted exactly once and their `TransportError.requestTimeout` surfaces
/// to the caller. Retries fire only on a request timeout; a closed socket,
/// a JSON-RPC error, or a cancelled task is never retried here (the connection
/// layer owns reconnects).
public struct RequestRetryPolicy: Sendable, Equatable {
    /// Total attempts including the first one.
    public var maxAttempts: Int
    /// Backoff before the first retry; doubles per retry.
    public var baseDelay: Duration
    /// Ceiling for any single backoff delay.
    public var maxDelay: Duration
    /// Per-attempt timeout for retried reads. Nil keeps the connection's
    /// `requestTimeout`.
    public var attemptTimeout: Duration?

    public init(
        maxAttempts: Int,
        baseDelay: Duration,
        maxDelay: Duration,
        attemptTimeout: Duration? = nil
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.attemptTimeout = attemptTimeout
    }

    /// Policy for idempotent reads: 3 attempts, 30s each, backoff 0.5s then
    /// 1s (both with jitter, capped at 4s). Worst case on a silent gateway is
    /// about 90s plus backoff before the timeout copy is shown.
    public static let idempotentRead = RequestRetryPolicy(
        maxAttempts: 3,
        baseDelay: .milliseconds(500),
        maxDelay: .seconds(4),
        attemptTimeout: .seconds(30)
    )

    /// Backoff before retry number `retryIndex` (1 = before the second attempt).
    ///
    /// Exponential (`baseDelay * 2^(retryIndex-1)`), capped at `maxDelay`, then
    /// "equal jitter": half the capped delay is fixed and the other half is
    /// scaled by `jitter` (clamped to 0...1). With `jitter` 0 the result is the
    /// lower bound; with 1 it is the capped delay.
    public func backoff(beforeRetry retryIndex: Int, jitter: Double) -> Duration {
        let base = Self.seconds(baseDelay)
        let cap = Self.seconds(maxDelay)
        let exponent = Double(max(0, retryIndex - 1))
        let exponential = min(cap, base * pow(2, exponent))
        let clamped = min(max(jitter, 0), 1)
        let delay = exponential / 2 + (exponential / 2) * clamped
        return .milliseconds(Int((delay * 1000).rounded()))
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}

/// Runs one gateway RPC under a `RequestRetryPolicy`. Internal seam: the
/// transport supplies the attempt closure, tests supply fake sleep and jitter.
enum RequestRetry {
    /// Runs `attempt` once for non-idempotent methods (no retry). For
    /// idempotent reads, retries `TransportError.requestTimeout` up to
    /// `policy.maxAttempts`, sleeping `policy.backoff` between attempts.
    static func run<T: Sendable>(
        method: String,
        policy: RequestRetryPolicy,
        sleep: @Sendable (Duration) async throws -> Void,
        jitter: @Sendable () -> Double,
        attempt: @Sendable (_ attemptTimeout: Duration?) async throws -> T
    ) async throws -> T {
        guard GatewayRequestCatalog.isIdempotentRead(method) else {
            return try await attempt(nil)
        }
        var retryIndex = 0
        while true {
            do {
                return try await attempt(policy.attemptTimeout)
            } catch TransportError.requestTimeout where retryIndex + 1 < policy.maxAttempts {
                retryIndex += 1
                try await sleep(policy.backoff(beforeRetry: retryIndex, jitter: jitter()))
            }
        }
    }
}
