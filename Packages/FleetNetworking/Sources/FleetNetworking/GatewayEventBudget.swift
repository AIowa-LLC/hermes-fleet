import Foundation
import FleetCore
import os

/// Memory budgets for everything the WebSocket transport buffers on behalf of
/// a remote peer. Every buffered path has BOTH a count limit and a byte limit,
/// and an overflow is never silent: it publishes an `EventGap` so the owner of
/// the affected session marks its history incomplete and refetches.
///
/// Buffering inventory (what can grow because of inbound traffic):
///
/// | Path | Per item | Per queue | Aggregate |
/// | --- | --- | --- | --- |
/// | Socket receive buffer (URLSession) | `maxFrameBytes` (set as `maximumMessageSize`) | one message | one message |
/// | Parked frames during replay | estimated event bytes | `maxReplayHoldEvents` / `maxReplayHoldBytes` | same (one queue) |
/// | Replay batch (`session.events.since`) | one frame | `maxReplayBatchEvents` / `maxReplayBatchBytes` | same |
/// | Event subscriber queues | estimated event bytes | `maxSubscriberBacklog` / `maxSubscriberBacklogBytes` | `maxAggregateBufferedBytes` over all subscribers |
/// | Conversation subscriber queues | source event bytes | same as event subscribers | shared with the above |
/// | Per-session watermarks | one Int | `maxTrackedSessions` (LRU; eviction marks incomplete) | same |
/// | Incomplete-session set | one id | `maxTrackedSessions`, then a single "all sessions" flag | same |
/// | Open server requests | one request | `ServerRequestBox.maxOpen` | same |
/// | Pinned queue entries (approvals) | 16 KiB | 64 per queue, then evictable | 64 per queue |
/// | Pending gaps (per gap subscriber) | one gap | 64, then one "unknown session" gap | same |
/// | Health samples / ready events | one value | newest-wins by design (state, not history) | same |
///
/// Unavoidable buffering: URLSession assembles a whole WebSocket message in
/// memory before handing it over, so the earliest a frame can be refused is at
/// its message boundary. `maximumMessageSize` makes URLSession fail the receive
/// (closing the socket) instead of delivering a larger message, so at most one
/// `maxFrameBytes` message is transiently held. Retained size is estimated from
/// the decoded payload structure (not the wire length) because that is what
/// actually stays resident.
public enum GatewayEventBudget {
    /// Largest single inbound WebSocket message accepted (1 MiB).
    public static let maxFrameBytes = 1 << 20
    /// Parked frames while a replay pass is in flight.
    public static let maxReplayHoldEvents = 2_000
    public static let maxReplayHoldBytes = 8 << 20
    /// A replay batch larger than either is not injected; history is refetched.
    public static let maxReplayBatchEvents = 5_000
    public static let maxReplayBatchBytes = 8 << 20
    /// One event subscriber's backlog.
    public static let maxSubscriberBacklog = 10_000
    public static let maxSubscriberBacklogBytes = 16 << 20
    /// All subscriber backlogs together.
    public static let maxAggregateBufferedBytes = 48 << 20
    /// Distinct sessions with a watermark / marked incomplete.
    public static let maxTrackedSessions = 1_000
    /// Newest-wins health event backlog.
    public static let maxHealthBacklog = 1_024
    /// Pending gaps per gap subscriber before collapsing to one global gap.
    public static let maxPendingGaps = 64

    /// Estimated resident bytes of a decoded event (structure + strings).
    public static func estimatedBytes(of event: GatewayEvent) -> Int {
        64 + event.rawType.utf8.count + (event.sessionID?.utf8.count ?? 0)
            + (event.payload.map(estimatedBytes(of:)) ?? 0)
    }

    public static func estimatedBytes(of value: JSONValue) -> Int {
        switch value {
        case .null, .bool: return 16
        case .number: return 24
        case .string(let s): return 32 + s.utf8.count
        case .array(let a): return a.reduce(32) { $0 + estimatedBytes(of: $1) }
        case .object(let o): return o.reduce(48) { $0 + 32 + $1.key.utf8.count + estimatedBytes(of: $1.value) }
        }
    }
}

/// A single-consumer FIFO bounded by item count AND total bytes. When a push
/// exceeds a bound the OLDEST entries are evicted and RETURNED to the caller,
/// so the transport can publish a gap for each affected session instead of
/// dropping silently. Cancelling the consumer finishes the queue.
final class BoundedQueue<Element: Sendable>: @unchecked Sendable {
    struct Entry: Sendable {
        let value: Element
        let bytes: Int
        let sessionID: String?
        /// Approval requests and their withdrawals are pinned (not evicted for
        /// overflow) because dropping one would strand a prompt. The event type
        /// is chosen by the peer, so pins are capped per queue (`maxPinned`)
        /// and per entry (`maxPinnedEntryBytes`); excess is evictable.
        var pinned = false
    }

    /// At most this many entries per queue are pinned, each at most this big,
    /// so pinned memory is bounded at 64 × 16 KiB = 1 MiB regardless of the peer.
    static var maxPinned: Int { 64 }
    static var maxPinnedEntryBytes: Int { 16 << 10 }

    private struct State {
        var items: [Entry?] = []
        var head = 0
        /// Entries currently pinned (bounded: see `maxPinned`).
        var pinnedCount = 0
        var bytes = 0
        var waiter: CheckedContinuation<Element?, Never>?
        var finished = false
        var count: Int { items.count - head }
    }

    let maxCount: Int
    let maxBytes: Int
    private let lock = OSAllocatedUnfairLock(initialState: State())

    init(maxCount: Int, maxBytes: Int) {
        self.maxCount = maxCount
        self.maxBytes = maxBytes
    }

    var byteCount: Int { lock.withLock { $0.bytes } }
    var count: Int { lock.withLock { $0.count } }

    /// Enqueue; returns entries evicted to honour the bounds (oldest first).
    @discardableResult
    func push(_ entry: Entry) -> [Entry] {
        let maxCount = self.maxCount, maxBytes = self.maxBytes
        let (handoff, dropped): (CheckedContinuation<Element?, Never>?, [Entry]) = lock.withLock { state in
            guard !state.finished else { return (nil, []) }
            if let waiter = state.waiter, state.count == 0 {
                state.waiter = nil
                return (waiter, [])
            }
            var entry = entry
            // A pin is a narrow exemption, never a way around the budget:
            // the peer chooses event types, so pinning is capped by count and
            // per-entry size; anything beyond is an ordinary evictable entry.
            if entry.pinned {
                if state.pinnedCount < Self.maxPinned, entry.bytes <= Self.maxPinnedEntryBytes {
                    state.pinnedCount += 1
                } else {
                    entry.pinned = false
                }
            }
            state.items.append(entry)
            state.bytes += entry.bytes
            var evictedEntries: [Entry] = []
            while state.count > 1, state.count > maxCount || state.bytes > maxBytes {
                guard let evicted = Self.evictOldestUnpinned(&state) else { break }
                evictedEntries.append(evicted)
            }
            return (nil, evictedEntries)
        }
        handoff?.resume(returning: entry.value)
        return dropped
    }

    /// Evict the oldest entry (aggregate-budget enforcement by the owner).
    func dropOldest() -> Entry? {
        lock.withLock { state in Self.evictOldestUnpinned(&state) }
    }

    private static func evictOldestUnpinned(_ state: inout State) -> Entry? {
        var index = state.head
        while index < state.items.count, state.items[index]?.pinned == true { index += 1 }
        guard index < state.items.count, let entry = state.items[index] else { return nil }
        if index == state.head { return popOldest(&state) }
        state.items.remove(at: index)
        state.bytes -= entry.bytes
        return entry
    }

    /// Removes the head entry. The slot is tombstoned immediately so the
    /// payload is released now, not when the array is eventually compacted.
    private static func popOldest(_ state: inout State) -> Entry {
        let entry = state.items[state.head]!
        state.items[state.head] = nil
        state.head += 1
        state.bytes -= entry.bytes
        if entry.pinned { state.pinnedCount -= 1 }
        if state.head > 64, state.head * 2 > state.items.count {
            state.items.removeFirst(state.head)
            state.head = 0
        }
        return entry
    }

    func next() async -> Element? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Element?, Never>) in
            let ready: Element?? = lock.withLock { state in
                if state.count > 0 {
                    return .some(Self.popOldest(&state).value)
                }
                if state.finished { return .some(nil) }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func finish() {
        let waiter: CheckedContinuation<Element?, Never>? = lock.withLock { state in
            state.finished = true
            state.items.removeAll()
            state.head = 0
            state.bytes = 0
            state.pinnedCount = 0
            let w = state.waiter
            state.waiter = nil
            return w
        }
        waiter?.resume(returning: nil)
    }
}

/// Runs `release` when the last owner lets go.
final class Lease: @unchecked Sendable {
    private let release: @Sendable () -> Void
    init(_ release: @escaping @Sendable () -> Void) { self.release = release }
    deinit { release() }
}

/// Fan-out registry of bounded queues with an aggregate byte budget. Used for
/// both raw event subscribers and conversation-event subscribers.
final class BoundedFanOut<Element: Sendable>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[UUID: BoundedQueue<Element>]>(initialState: [:])
    private let maxAggregateBytes: Int
    private let onGap: @Sendable (EventGap) -> Void

    init(maxAggregateBytes: Int, onGap: @escaping @Sendable (EventGap) -> Void) {
        self.maxAggregateBytes = maxAggregateBytes
        self.onGap = onGap
    }

    func register(maxCount: Int, maxBytes: Int) -> (id: UUID, queue: BoundedQueue<Element>) {
        let queue = BoundedQueue<Element>(maxCount: maxCount, maxBytes: maxBytes)
        let id = UUID()
        lock.withLock { $0[id] = queue }
        return (id, queue)
    }

    func remove(_ id: UUID) {
        let queue = lock.withLock { $0.removeValue(forKey: id) }
        queue?.finish()
    }

    var subscriberCount: Int { lock.withLock { $0.count } }
    var totalBytes: Int { lock.withLock { $0.values.reduce(0) { $0 + $1.byteCount } } }

    /// Deliver to every subscriber, then enforce the aggregate budget by
    /// evicting from the largest backlog. Every eviction becomes a gap.
    func yield(_ value: Element, bytes: Int, sessionID: String?, pinned: Bool = false) {
        let queues = lock.withLock { Array($0.values) }
        let entry = BoundedQueue<Element>.Entry(value: value, bytes: bytes, sessionID: sessionID, pinned: pinned)
        var dropped: [(String?, EventGap.Reason)] = []
        for queue in queues {
            for evicted in queue.push(entry) { dropped.append((evicted.sessionID, .subscriberOverflow)) }
        }
        var total = queues.reduce(0) { $0 + $1.byteCount }
        while total > maxAggregateBytes, let largest = queues.max(by: { $0.byteCount < $1.byteCount }),
              largest.count > 1, let evicted = largest.dropOldest() {
            total -= evicted.bytes
            dropped.append((evicted.sessionID, .aggregateOverflow))
        }
        for (session, reason) in dropped { onGap(EventGap(sessionID: session, reason: reason)) }
    }

    func makeStream(maxCount: Int, maxBytes: Int) -> AsyncStream<Element> {
        let (id, queue) = register(maxCount: maxCount, maxBytes: maxBytes)
        // The stream's closure owns the lease; the registry does not. When the
        // stream is dropped (even if never iterated) the lease is released and
        // the subscriber is deregistered. Cancellation deregisters too.
        let lease = Lease { [weak self] in self?.remove(id) }
        return AsyncStream<Element>(unfolding: {
            _ = lease
            return await queue.next()
        }, onCancel: { [weak self] in
            self?.remove(id)
        })
    }
}

/// Broadcasts gaps to gap subscribers. A subscriber that lags keeps the newest
/// `maxPendingGaps`; if even that overflows, one "unknown session" gap is
/// delivered last, which makes every open session recover.
final class GapBroadcaster: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[UUID: AsyncStream<EventGap>.Continuation]>(initialState: [:])

    func publish(_ gap: EventGap) {
        let continuations = lock.withLock { Array($0.values) }
        for continuation in continuations {
            if case .dropped = continuation.yield(gap) {
                continuation.yield(EventGap(sessionID: nil, reason: .gapBacklogOverflow))
            }
        }
    }

    func subscribe() -> AsyncStream<EventGap> {
        let (stream, continuation) = AsyncStream<EventGap>.makeStream(
            bufferingPolicy: .bufferingNewest(GatewayEventBudget.maxPendingGaps))
        let id = UUID()
        lock.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    var subscriberCount: Int { lock.withLock { $0.count } }
}
