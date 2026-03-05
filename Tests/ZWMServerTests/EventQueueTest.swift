import CoreGraphics
import Testing
@testable import ZWMServer

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

@Test func eventQueueDrainPassesThroughAll() {
    let queue = EventQueue()
    queue.enqueue(.windowMoved(windowId: 1))
    queue.enqueue(.windowMoved(windowId: 1))
    queue.enqueue(.windowMoved(windowId: 1))

    let batch = queue.drain()
    #expect(batch.count == 3)
}

@Test func eventQueueDrainEmptyReturnsEmpty() {
    let queue = EventQueue()
    let batch = queue.drain()
    #expect(batch.isEmpty)
}
