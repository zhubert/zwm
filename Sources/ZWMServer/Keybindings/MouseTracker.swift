import CoreGraphics
import Foundation

/// Tracks mouse movement via a passive CGEvent tap and fires a handler with the new location.
/// Uses `.listenOnly` so mouse events are never consumed.
public final class MouseTracker: @unchecked Sendable {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let handler: @Sendable (CGPoint) -> Void
    private var lastRecreate = Date.distantPast

    /// Minimum spacing between attempts to rebuild a tap that won't re-enable.
    private static let recreateInterval: TimeInterval = 15

    // Rate-limited activity logging so a silent tap is distinguishable from a
    // tap that fires but whose points don't hit any managed window.
    private var moveCount = 0
    private var lastLogged = Date.distantPast
    private static let logInterval: TimeInterval = 10

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
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return nil }
                let tracker = Unmanaged<MouseTracker>.fromOpaque(refcon).takeUnretainedValue()

                // The system delivers these regardless of the event mask, and the
                // tap stays dead until explicitly re-enabled.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
                    print("zwm: mouse tap disabled by \(reason) — re-enabling")
                    tracker.reenable()
                    return nil
                }

                tracker.recordMove(event.location)
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

    /// Revive the tap if the system has disabled it. Safe to call periodically —
    /// covers disables that arrive without a callback (e.g. after sleep/wake) and
    /// taps created before Accessibility was granted.
    /// Returns true if the tap had to be revived.
    @discardableResult
    public func checkHealth() -> Bool {
        guard let tap = eventTap else {
            // Creation previously failed outright — retry, throttled.
            return recreate(reason: "no tap")
        }
        guard !CGEvent.tapIsEnabled(tap: tap) else { return false }

        CGEvent.tapEnable(tap: tap, enable: true)
        if CGEvent.tapIsEnabled(tap: tap) {
            print("zwm: mouse tap found disabled during health check — re-enabled")
            return true
        }

        // A tap created while the process was untrusted is a zombie: it exists,
        // but tapEnable never takes. Only building a fresh tap recovers it.
        return recreate(reason: "re-enable had no effect")
    }

    /// Tear down and rebuild the tap. Throttled so a permanently unavailable tap
    /// (e.g. Accessibility still not granted) can't churn or flood the log.
    private func recreate(reason: String) -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastRecreate) >= Self.recreateInterval else { return false }
        lastRecreate = now

        teardown()
        if start() {
            print("zwm: mouse tap recreated (\(reason))")
            return true
        }
        print("zwm: mouse tap recreate failed (\(reason)) — Accessibility permission missing?")
        return false
    }

    private func teardown() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func reenable() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func recordMove(_ point: CGPoint) {
        moveCount += 1
        let now = Date()
        guard now.timeIntervalSince(lastLogged) >= Self.logInterval else { return }
        lastLogged = now
        print("zwm: mouse tap alive: \(moveCount) moves, last=(\(Int(point.x)), \(Int(point.y)))")
        moveCount = 0
    }
}
