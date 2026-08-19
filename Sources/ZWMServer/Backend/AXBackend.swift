import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import PrivateApi

/// Real macOS window backend using Accessibility APIs.
public final class AXBackend: @unchecked Sendable {
    private var eventHandler: (@Sendable (WindowEvent) -> Void)?
    private var appObservers: [pid_t: AXObserver] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var _lock = os_unfair_lock()
    /// Track known window IDs per PID so we can detect which window was
    /// destroyed when _AXUIElementGetWindow returns 0 on invalid elements.
    private var knownWindowsByPid: [pid_t: Set<UInt32>] = [:]
    /// Cache AXUIElement references by window ID to avoid O(n) scans.
    /// Invalidated on window creation/destruction.
    private var elementCache: [UInt32: (pid: pid_t, element: AXUIElement)] = [:]
    /// Track last event time per PID to detect stale observers.
    private var lastEventByPid: [pid_t: Date] = [:]
    /// When each app's observer was registered. Lets the health check age an
    /// observer that has never delivered a single event.
    private var observerRegisteredAt: [pid_t: Date] = [:]
    /// PIDs whose observer failed to register one or more notifications. Such an
    /// observer is dead on arrival and can never age out via event staleness.
    private var failedRegistrations: Set<pid_t> = []
    /// Last time the health check re-registered an observer, to bound retry noise.
    private var lastObserverRetry: [pid_t: Date] = [:]

    /// Minimum spacing between health-check re-registration attempts for one app.
    private static let observerRetryInterval: TimeInterval = 15

    public init() {}

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return body()
    }
}

extension AXBackend: WindowBackend {

    public func discoverWindows() async throws -> [DiscoveredWindow] {
        // NSWorkspace and NSRunningApplication require main actor
        let appInfos: [(pid: pid_t, name: String)] = await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { (pid: $0.processIdentifier, name: $0.localizedName ?? $0.bundleIdentifier ?? "Unknown") }
        }

        print("zwm: discoverWindows: found \(appInfos.count) regular apps")
        var windows: [DiscoveredWindow] = []
        for app in appInfos {
            let appElement = AXUIElementCreateApplication(app.pid)
            var readError = AXError.success
            guard let windowElements = axArrayAttribute(appElement, kAXWindowsAttribute, error: &readError) else {
                // Log the code — apiDisabled (-25211) across every app means the
                // process isn't AX-trusted, which is very different from an app
                // that simply has no windows.
                print("zwm: discoverWindows: \(app.name) (pid \(app.pid)) — no AX windows attribute (\(readError.rawValue))")
                continue
            }

            print("zwm: discoverWindows: \(app.name) (pid \(app.pid)) — \(windowElements.count) windows")
            for windowElement in windowElements {
                var windowId: UInt32 = 0
                let result = _AXUIElementGetWindow(windowElement, &windowId)
                guard result == .success, windowId != 0 else {
                    print("zwm: discoverWindows:   _AXUIElementGetWindow failed: \(result.rawValue)")
                    continue
                }

                // Track this window so we can detect destroys, and cache the element
                withLock {
                    _ = knownWindowsByPid[app.pid, default: []].insert(windowId)
                    elementCache[windowId] = (pid: app.pid, element: windowElement)
                }

                let frame = axFrame(windowElement)
                let isMinimized = axBoolAttribute(windowElement, kAXMinimizedAttribute as CFString)
                let title = axStringAttribute(windowElement, kAXTitleAttribute) ?? ""
                let level = windowLevel(for: windowId)
                let subrole = axStringAttribute(windowElement, kAXSubroleAttribute) ?? ""
                let hasCloseButton = axHasCloseButton(windowElement)

                print("zwm: discoverWindows:   wid=\(windowId) level=\(level) minimized=\(isMinimized) subrole=\(subrole) closeBtn=\(hasCloseButton) title=\"\(title)\"")
                windows.append(DiscoveredWindow(
                    windowId: windowId, pid: app.pid, appName: app.name, title: title,
                    frame: frame, isMinimized: isMinimized,
                    windowLevel: level, subrole: subrole, hasCloseButton: hasCloseButton
                ))
            }
        }

        return windows
    }

    public func setFrame(_ windowId: UInt32, _ frame: CGRect) async throws {
        guard let element = await findWindowElement(windowId) else {
            throw AXBackendError.windowNotFound(windowId)
        }

        // Toggle enhanced UI to suppress animations
        setAxAttribute(element, "AXEnhancedUserInterface" as CFString, true)
        defer { setAxAttribute(element, "AXEnhancedUserInterface" as CFString, false) }

        // Set position first, then size
        var point = CGPoint(x: frame.origin.x, y: frame.origin.y)
        guard let posValue = AXValueCreate(.cgPoint, &point) else { return }
        let posResult = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
        if posResult != .success {
            print("zwm: setFrame(\(windowId)): position set failed: \(posResult.rawValue)")
        }

        var size = CGSize(width: frame.size.width, height: frame.size.height)
        guard let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        let sizeResult = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        if sizeResult != .success {
            print("zwm: setFrame(\(windowId)): size set failed: \(sizeResult.rawValue)")
        }

        // Double-set trick: some apps constrain on the first call
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)

        if posResult != .success && sizeResult != .success {
            throw AXBackendError.setFrameFailed(windowId: windowId, code: posResult.rawValue)
        }
    }

    public func getFrame(_ windowId: UInt32) async throws -> CGRect {
        guard let element = await findWindowElement(windowId) else {
            throw AXBackendError.windowNotFound(windowId)
        }
        return axFrame(element)
    }

    public func focus(_ windowId: UInt32) async throws {
        guard let element = await findWindowElement(windowId) else {
            throw AXBackendError.windowNotFound(windowId)
        }

        // Raise the window
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)

        // Activate the app (requires main actor)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if pid > 0 {
            await MainActor.run {
                if let app = NSRunningApplication(processIdentifier: pid) {
                    app.activate()
                }
            }
        }
    }

    public func close(_ windowId: UInt32) async throws {
        guard let element = await findWindowElement(windowId) else {
            throw AXBackendError.windowNotFound(windowId)
        }

        var closeButton: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButton)
        if let button = closeButton {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }

    public func monitors() async -> [MonitorInfo] {
        await MainActor.run {
            // NSScreen uses Cocoa coordinates (origin at bottom-left of primary screen, Y up).
            // AX APIs use screen coordinates (origin at top-left of primary screen, Y down).
            // Convert here so the layout engine works in AX coordinates consistently.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

            return NSScreen.screens.enumerated().map { (index, screen) in
                MonitorInfo(
                    id: UInt32(index + 1),
                    frame: cocoaToAX(screen.frame, primaryHeight: primaryHeight),
                    visibleFrame: cocoaToAX(screen.visibleFrame, primaryHeight: primaryHeight)
                )
            }
        }
    }

    /// Convert a rect from Cocoa coordinates (bottom-left origin) to AX coordinates (top-left origin).
    private func cocoaToAX(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    public func observe(_ handler: @escaping @Sendable (WindowEvent) -> Void) async throws {
        withLock { eventHandler = handler }

        await MainActor.run {
            let center = NSWorkspace.shared.notificationCenter

            // App-level notifications that carry a running application
            var observers: [NSObjectProtocol] = []

            func observeApp(
                _ name: NSNotification.Name,
                _ factory: @escaping @Sendable (pid_t) -> WindowEvent
            ) {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                    self?.emit(factory(app.processIdentifier))
                })
            }

            observeApp(NSWorkspace.didActivateApplicationNotification) { .appActivated(pid: $0) }
            observeApp(NSWorkspace.didHideApplicationNotification) { .appHidden(pid: $0) }
            observeApp(NSWorkspace.didUnhideApplicationNotification) { .appUnhidden(pid: $0) }

            observers.append(center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.emit(.appLaunched(pid: app.processIdentifier))
                self?.startObservingApp(app.processIdentifier)
            })

            observers.append(center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.emit(.appTerminated(pid: app.processIdentifier))
                self?.stopObservingApp(app.processIdentifier)
            })

            observers.append(center.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.emit(.spaceChanged)
            })

            self.withLock { self.workspaceObservers = observers }

            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                self.startObservingApp(app.processIdentifier)
            }
        }
    }

    public func checkObserverHealth() async -> Int {
        let now = Date()
        let staleCutoff = now.addingTimeInterval(-30)
        let observedPids = withLock { Array(appObservers.keys) }

        // Check which apps are still running
        let runningPids: Set<pid_t> = await MainActor.run {
            Set(NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { $0.processIdentifier })
        }

        var reregistered = 0
        for pid in observedPids {
            // If app is no longer running, clean up
            guard runningPids.contains(pid) else {
                print("zwm: health: app \(pid) terminated without notification, cleaning up")
                stopObservingApp(pid)
                withLock { _ = lastObserverRetry.removeValue(forKey: pid) }
                continue
            }

            // Don't retry the same app more often than the retry interval, so a
            // permanently unobservable app can't flood the log every 5s.
            let retryAllowed = withLock {
                lastObserverRetry[pid].map { now.timeIntervalSince($0) >= Self.observerRetryInterval } ?? true
            }
            guard retryAllowed else { continue }

            // An observer whose notification registration failed is dead on arrival:
            // it will never deliver an event, so the staleness check below can never
            // fire for it. Retry it unconditionally.
            if withLock({ failedRegistrations.contains(pid) }) {
                print("zwm: health: observer for pid \(pid) has failed registrations, re-registering")
                withLock { lastObserverRetry[pid] = now }
                stopObservingApp(pid)
                startObservingApp(pid)
                reregistered += 1
                continue
            }

            // Age from the last event, or from registration time if the observer has
            // never delivered one — a silently broken observer looks permanently
            // "brand new" otherwise, and is never retried.
            let lastActivity = withLock { lastEventByPid[pid] ?? observerRegisteredAt[pid] }
            if let last = lastActivity, last < staleCutoff, !observerIsLive(pid) {
                print("zwm: health: observer for pid \(pid) appears stale, re-registering")
                withLock { lastObserverRetry[pid] = now }
                stopObservingApp(pid)
                startObservingApp(pid)
                reregistered += 1
            }
        }

        // Check for new apps that we're not observing
        for pid in runningPids {
            let isObserved = withLock { appObservers[pid] != nil }
            if !isObserved {
                print("zwm: health: new app \(pid) not observed, registering")
                startObservingApp(pid)
                reregistered += 1
            }
        }

        return reregistered
    }

    /// Probe whether an app's observer is actually functional.
    ///
    /// Re-adding a notification that is already registered returns
    /// `.notificationAlreadyRegistered` on a live observer, and a hard error
    /// (`.cannotComplete`, `.invalidUIElement`, …) on a dead one. This tests the
    /// observer itself — reading `kAXWindowsAttribute` succeeds even when
    /// notification delivery is broken, so it can't tell the two apart.
    private func observerIsLive(_ pid: pid_t) -> Bool {
        guard let observer = withLock({ appObservers[pid] }) else { return false }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = AXObserverAddNotification(
            observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon
        )
        return result == .notificationAlreadyRegistered || result == .success
    }

    // MARK: - Accessibility readiness

    /// Block until the Accessibility API actually answers, or `timeout` elapses.
    ///
    /// TCC grants can land a moment after launch — reinstalling the bundle re-keys
    /// the entry, so the first seconds of a run can be untrusted. Registering AX
    /// observers during that window produces observers that never fire, so the
    /// engine must not start until this returns true.
    public func waitUntilReady(timeout: TimeInterval = 60) async -> Bool {
        if accessibilityIsFunctional() { return true }

        // Prompt once, then poll — the user may need to grant permission by hand.
        // Literal rather than kAXTrustedCheckOptionPrompt — the global is a `var`
        // and so isn't concurrency-safe under Swift 6 strict checking.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        print("zwm: waiting for Accessibility permission (trusted=\(AXIsProcessTrusted()))")

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if accessibilityIsFunctional() {
                print("zwm: Accessibility API ready")
                return true
            }
        }
        print("zwm: Accessibility API still unavailable after \(Int(timeout))s — starting anyway")
        return false
    }

    /// `AXIsProcessTrusted()` can flip true slightly before the AX API starts
    /// answering, so probe a real read and treat `apiDisabled` as "not ready".
    private func accessibilityIsFunctional() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value
        )
        // .noValue / .attributeUnsupported just mean nothing is focused right now.
        return result != .apiDisabled && result != .notImplemented
    }

    // MARK: - AX Observer per app

    /// Register an AX observer for an app. Returns true only if every notification
    /// was registered — a partial failure means the observer is not trustworthy and
    /// the pid is recorded so `checkObserverHealth` retries it.
    @discardableResult
    private func startObservingApp(_ pid: pid_t) -> Bool {
        var observer: AXObserver?
        let result = AXObserverCreate(
            pid,
            { (_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) in
                guard let refcon else { return }
                let backend = Unmanaged<AXBackend>.fromOpaque(refcon).takeUnretainedValue()
                backend.handleAXNotification(element: element, notification: notification as String)
            },
            &observer
        )

        guard result == .success, let observer else {
            print("zwm: observer: AXObserverCreate failed for pid \(pid): \(result.rawValue)")
            // No entry in appObservers, so the health check's "new app" branch retries.
            return false
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)

        let notifications: [String] = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXFocusedWindowChangedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
        ]

        var failures: [(String, AXError)] = []
        for name in notifications {
            let addResult = AXObserverAddNotification(observer, appElement, name as CFString, refcon)
            // Already-registered is benign; anything else means this event never arrives.
            if addResult != .success && addResult != .notificationAlreadyRegistered {
                failures.append((name, addResult))
            }
        }

        if !failures.isEmpty {
            let detail = failures.map { "\($0.0)=\($0.1.rawValue)" }.joined(separator: " ")
            print("zwm: observer: pid \(pid) failed \(failures.count)/\(notifications.count) notifications: \(detail)")
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )

        withLock {
            appObservers[pid] = observer
            observerRegisteredAt[pid] = Date()
            if failures.isEmpty {
                failedRegistrations.remove(pid)
            } else {
                failedRegistrations.insert(pid)
            }
        }
        return failures.isEmpty
    }

    private func stopObservingApp(_ pid: pid_t) {
        let observer = withLock { () -> AXObserver? in
            let obs = appObservers.removeValue(forKey: pid)
            observerRegisteredAt.removeValue(forKey: pid)
            failedRegistrations.remove(pid)
            lastEventByPid.removeValue(forKey: pid)
            // Remove cached elements for all windows of this app
            if let windowIds = knownWindowsByPid.removeValue(forKey: pid) {
                for wid in windowIds {
                    elementCache.removeValue(forKey: wid)
                }
            }
            return obs
        }
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
    }

    private func handleAXNotification(element: AXUIElement, notification: String) {
        var windowId: UInt32 = 0
        _AXUIElementGetWindow(element, &windowId)

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        withLock { lastEventByPid[pid] = Date() }

        print("zwm: AX notification: \(notification) windowId=\(windowId) pid=\(pid)")

        switch notification {
        case kAXWindowCreatedNotification:
            if windowId != 0 {
                withLock {
                    _ = knownWindowsByPid[pid, default: []].insert(windowId)
                    elementCache[windowId] = (pid: pid, element: element)
                }
                let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
                let title = axStringAttribute(element, kAXTitleAttribute) ?? ""
                let subrole = axStringAttribute(element, kAXSubroleAttribute) ?? ""
                let frame = axFrame(element)
                emit(.windowCreated(pid: pid, windowId: windowId, appName: appName, title: title, subrole: subrole, frame: frame))
            }
        case kAXUIElementDestroyedNotification:
            if windowId != 0 {
                withLock {
                    _ = knownWindowsByPid[pid, default: []].remove(windowId)
                    elementCache.removeValue(forKey: windowId)
                }
                emit(.windowDestroyed(windowId: windowId))
            } else if pid != 0 {
                // The destroyed element itself is already invalid, so
                // _AXUIElementGetWindow can't resolve its window id — this happens for
                // real window closes, not just non-window elements like tabs. Diff the
                // app's current AX windows against what we last knew about it to find
                // which window id actually disappeared, so we don't have to wait for
                // the periodic validation fallback to notice.
                let appElement = AXUIElementCreateApplication(pid)
                let liveIds: Set<UInt32> = {
                    guard let windows = axArrayAttribute(appElement, kAXWindowsAttribute) else { return [] }
                    var ids: Set<UInt32> = []
                    for win in windows {
                        var wid: UInt32 = 0
                        if _AXUIElementGetWindow(win, &wid) == .success, wid != 0 {
                            ids.insert(wid)
                        }
                    }
                    return ids
                }()
                let missingIds: Set<UInt32> = withLock {
                    let known = knownWindowsByPid[pid, default: []]
                    let missing = known.subtracting(liveIds)
                    knownWindowsByPid[pid] = known.subtracting(missing)
                    for wid in missing {
                        elementCache.removeValue(forKey: wid)
                    }
                    return missing
                }
                for wid in missingIds {
                    emit(.windowDestroyed(windowId: wid))
                }
            }
        case kAXFocusedWindowChangedNotification:
            if windowId != 0 { emit(.windowFocused(windowId: windowId)) }
        case kAXWindowMovedNotification:
            if windowId != 0 { emit(.windowMoved(windowId: windowId)) }
        case kAXWindowResizedNotification:
            if windowId != 0 { emit(.windowResized(windowId: windowId)) }
        case kAXWindowMiniaturizedNotification:
            if windowId != 0 { emit(.windowMinimized(windowId: windowId)) }
        case kAXWindowDeminiaturizedNotification:
            if windowId != 0 { emit(.windowUnminimized(windowId: windowId)) }
        default:
            break
        }
    }

    // MARK: - Helpers

    private func emit(_ event: WindowEvent) {
        let handler = withLock { eventHandler }
        handler?(event)
    }

    /// Find the AXUIElement for a given CGWindowID.
    /// Uses cached element first; falls back to a full scan if cache misses.
    private func findWindowElement(_ windowId: UInt32) async -> AXUIElement? {
        // Try cache first — O(1)
        let cached = withLock { elementCache[windowId] }
        if let cached {
            // Validate the cached element is still valid
            var wid: UInt32 = 0
            if _AXUIElementGetWindow(cached.element, &wid) == .success, wid == windowId {
                return cached.element
            }
            // Cache entry is stale — remove it
            withLock { _ = elementCache.removeValue(forKey: windowId) }
        }

        // Full scan fallback — O(n)
        let pids: [pid_t] = await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { $0.processIdentifier }
        }
        for pid in pids {
            let appElement = AXUIElementCreateApplication(pid)
            guard let windows = axArrayAttribute(appElement, kAXWindowsAttribute) else { continue }
            for win in windows {
                var wid: UInt32 = 0
                if _AXUIElementGetWindow(win, &wid) == .success, wid == windowId {
                    // Populate cache for next time
                    withLock { elementCache[windowId] = (pid: pid, element: win) }
                    return win
                }
            }
        }
        return nil
    }

    private func axArrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var ignored = AXError.success
        return axArrayAttribute(element, attribute, error: &ignored)
    }

    private func axArrayAttribute(_ element: AXUIElement, _ attribute: String, error: inout AXError) -> [AXUIElement]? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        error = result
        guard result == .success, let array = value as? [AXUIElement] else { return nil }
        return array
    }

    private func axFrame(_ element: AXUIElement) -> CGRect {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)

        var point = CGPoint.zero
        var size = CGSize.zero

        if let posValue, CFGetTypeID(posValue) == AXValueGetTypeID() {
            AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
        }
        if let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }

        return CGRect(origin: point, size: size)
    }

    private func axBoolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { return false }
        return (value as? Bool) ?? false
    }

    private func axStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private func setAxAttribute(_ element: AXUIElement, _ attribute: CFString, _ value: Bool) {
        AXUIElementSetAttributeValue(element, attribute, value ? kCFBooleanTrue : kCFBooleanFalse)
    }

    private func axHasCloseButton(_ element: AXUIElement) -> Bool {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &value)
        return result == .success && value != nil
    }

    private func windowLevel(for windowId: UInt32) -> Int {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowId) as? [[String: Any]],
              let windowInfo = info.first,
              let level = windowInfo[kCGWindowLayer as String] as? Int else {
            return 0
        }
        return level
    }
}

public enum AXBackendError: Error, Sendable {
    case windowNotFound(UInt32)
    case setFrameFailed(windowId: UInt32, code: Int32)
}
