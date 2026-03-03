import Foundation

/// Collects WindowEvents and coalesces them into batches.
///
/// Coalescing rules:
/// - Multiple windowMoved/windowResized for the same window → keep last
/// - windowCreated + windowDestroyed for the same window → cancel out
/// - Multiple spaceChanged → keep one
/// - Everything else passes through
public final class EventQueue: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var pending: [WindowEvent] = []

    public init() {}

    /// Add an event to the queue.
    public func enqueue(_ event: WindowEvent) {
        os_unfair_lock_lock(&lock)
        pending.append(event)
        os_unfair_lock_unlock(&lock)
    }

    /// Drain and coalesce all pending events.
    /// Returns the coalesced batch. After this call, the queue is empty.
    public func drain() -> [WindowEvent] {
        os_unfair_lock_lock(&lock)
        let events = pending
        pending = []
        os_unfair_lock_unlock(&lock)
        return coalesce(events)
    }

    /// Whether the queue has any pending events.
    public var isEmpty: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return pending.isEmpty
    }
}

/// Coalesce a list of events into a minimal set.
public func coalesce(_ events: [WindowEvent]) -> [WindowEvent] {
    guard !events.isEmpty else { return [] }

    // Use Optional array so we can nil-out cancelled events
    var slots: [WindowEvent?] = events.map { $0 }
    var lastMoved: [UInt32: Int] = [:]
    var lastResized: [UInt32: Int] = [:]
    var createdAt: [UInt32: Int] = [:]  // windowId → slot index of create
    var hasSpaceChanged = false

    for (i, event) in events.enumerated() {
        switch event {
        case .windowMoved(let wid):
            if let prev = lastMoved[wid] {
                slots[prev] = nil
            }
            lastMoved[wid] = i

        case .windowResized(let wid):
            if let prev = lastResized[wid] {
                slots[prev] = nil
            }
            lastResized[wid] = i

        case .windowCreated(_, let wid, _, _, _, _):
            createdAt[wid] = i

        case .windowDestroyed(let wid):
            if let createIdx = createdAt[wid] {
                // Created then destroyed in same batch → cancel both
                slots[createIdx] = nil
                slots[i] = nil
                createdAt.removeValue(forKey: wid)
            }

        case .spaceChanged:
            if hasSpaceChanged {
                slots[i] = nil
            } else {
                hasSpaceChanged = true
            }

        default:
            break
        }
    }

    return slots.compactMap { $0 }
}
