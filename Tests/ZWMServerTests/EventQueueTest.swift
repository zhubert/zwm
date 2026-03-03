import CoreGraphics
import Testing
@testable import ZWMServer

// MARK: - Coalescing

@Test func coalesceEmptyReturnsEmpty() {
    let result = coalesce([])
    #expect(result.isEmpty)
}

@Test func coalescePassesThroughSingleEvents() {
    let events: [WindowEvent] = [
        .windowCreated(pid: 1, windowId: 1, appName: "App", title: "W1", subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
        .windowFocused(windowId: 1),
        .appLaunched(pid: 2),
    ]
    let result = coalesce(events)
    #expect(result == events)
}

@Test func coalesceMovedKeepsLast() {
    let events: [WindowEvent] = [
        .windowMoved(windowId: 1),
        .windowMoved(windowId: 1),
        .windowMoved(windowId: 1),
    ]
    let result = coalesce(events)
    #expect(result == [.windowMoved(windowId: 1)])
}

@Test func coalesceMovedKeepsLastPerWindow() {
    let events: [WindowEvent] = [
        .windowMoved(windowId: 1),
        .windowMoved(windowId: 2),
        .windowMoved(windowId: 1),
    ]
    let result = coalesce(events)
    #expect(result.count == 2)
    #expect(result[0] == .windowMoved(windowId: 2))
    #expect(result[1] == .windowMoved(windowId: 1))
}

@Test func coalesceResizedKeepsLast() {
    let events: [WindowEvent] = [
        .windowResized(windowId: 5),
        .windowResized(windowId: 5),
    ]
    let result = coalesce(events)
    #expect(result == [.windowResized(windowId: 5)])
}

@Test func coalesceCreatedThenDestroyedCancelOut() {
    let events: [WindowEvent] = [
        .windowCreated(pid: 1, windowId: 1, appName: "App", title: "W1", subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
        .windowDestroyed(windowId: 1),
    ]
    let result = coalesce(events)
    #expect(result.isEmpty)
}

@Test func coalesceCreatedThenDestroyedOnlyCancelsMatching() {
    let events: [WindowEvent] = [
        .windowCreated(pid: 1, windowId: 1, appName: "App", title: "W1", subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
        .windowCreated(pid: 1, windowId: 2, appName: "App", title: "W2", subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
        .windowDestroyed(windowId: 1),
    ]
    let result = coalesce(events)
    #expect(result == [.windowCreated(pid: 1, windowId: 2, appName: "App", title: "W2", subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 800, height: 600))])
}

@Test func coalesceDestroyedWithoutCreatePassesThrough() {
    let events: [WindowEvent] = [
        .windowDestroyed(windowId: 99),
    ]
    let result = coalesce(events)
    #expect(result == [.windowDestroyed(windowId: 99)])
}

@Test func coalesceSpaceChangedDeduplicates() {
    let events: [WindowEvent] = [
        .spaceChanged,
        .spaceChanged,
        .spaceChanged,
    ]
    let result = coalesce(events)
    #expect(result == [.spaceChanged])
}

@Test func coalesceSpaceChangedWithOtherEvents() {
    let events: [WindowEvent] = [
        .spaceChanged,
        .windowFocused(windowId: 1),
        .spaceChanged,
    ]
    let result = coalesce(events)
    #expect(result.count == 2)
    #expect(result[0] == .spaceChanged)
    #expect(result[1] == .windowFocused(windowId: 1))
}

@Test func coalesceMixedEvents() {
    let events: [WindowEvent] = [
        .windowCreated(pid: 1, windowId: 1, appName: "App", title: "W1", subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
        .windowMoved(windowId: 1),
        .windowResized(windowId: 1),
        .windowMoved(windowId: 1),
        .windowResized(windowId: 1),
        .windowFocused(windowId: 1),
        .spaceChanged,
        .spaceChanged,
    ]
    let result = coalesce(events)
    // create: kept, moved: last only, resized: last only, focused: kept, spaceChanged: one
    #expect(result.count == 5)
    #expect(result[0] == .windowCreated(pid: 1, windowId: 1, appName: "App", title: "W1", subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 800, height: 600)))
    #expect(result[1] == .windowMoved(windowId: 1))
    #expect(result[2] == .windowResized(windowId: 1))
    #expect(result[3] == .windowFocused(windowId: 1))
    #expect(result[4] == .spaceChanged)
}

// MARK: - EventQueue

@Test func eventQueueEnqueueAndDrain() {
    let queue = EventQueue()
    #expect(queue.isEmpty)

    queue.enqueue(.windowCreated(pid: 1, windowId: 1, appName: "App", title: "W1", subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 800, height: 600)))
    queue.enqueue(.windowFocused(windowId: 1))
    #expect(!queue.isEmpty)

    let batch = queue.drain()
    #expect(batch.count == 2)
    #expect(queue.isEmpty)
}

@Test func eventQueueDrainCoalesces() {
    let queue = EventQueue()
    queue.enqueue(.windowMoved(windowId: 1))
    queue.enqueue(.windowMoved(windowId: 1))
    queue.enqueue(.windowMoved(windowId: 1))

    let batch = queue.drain()
    #expect(batch.count == 1)
}

@Test func eventQueueDrainEmptyReturnsEmpty() {
    let queue = EventQueue()
    let batch = queue.drain()
    #expect(batch.isEmpty)
}
