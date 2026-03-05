import Foundation

/// Collects WindowEvents and drains them in batches.
///
/// Events are used only as triggers for a full OS re-sync.
/// The only payload extracted is the last focused window ID.
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

    /// Drain all pending events. After this call, the queue is empty.
    public func drain() -> [WindowEvent] {
        os_unfair_lock_lock(&lock)
        let events = pending
        pending = []
        os_unfair_lock_unlock(&lock)
        return events
    }

    /// Whether the queue has any pending events.
    public var isEmpty: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return pending.isEmpty
    }
}
