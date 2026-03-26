import CoreGraphics
import Foundation

/// Tracks mouse movement via a passive CGEvent tap and fires a handler with the new location.
/// Uses `.listenOnly` so mouse events are never consumed.
public final class MouseTracker: @unchecked Sendable {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let handler: @Sendable (CGPoint) -> Void

    public init(handler: @escaping @Sendable (CGPoint) -> Void) {
        self.handler = handler
    }

    /// Start observing mouse movement. Must be called from the main thread.
    public func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return nil }
                let tracker = Unmanaged<MouseTracker>.fromOpaque(refcon).takeUnretainedValue()
                tracker.handler(event.location)
                return nil
            },
            userInfo: refcon
        ) else {
            return false
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Stop observing mouse movement.
    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }
}
