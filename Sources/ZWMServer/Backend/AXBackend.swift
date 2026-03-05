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
            guard let windowElements = axArrayAttribute(appElement, kAXWindowsAttribute) else {
                print("zwm: discoverWindows: \(app.name) (pid \(app.pid)) — no AX windows attribute")
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

                // Track this window so we can detect destroys
                withLock { _ = knownWindowsByPid[app.pid, default: []].insert(windowId) }

                let frame = axFrame(windowElement)
                let isMinimized = axBoolAttribute(windowElement, kAXMinimizedAttribute as CFString)
                let isFullscreen = axBoolAttribute(windowElement, "AXFullScreen" as CFString)
                let title = axStringAttribute(windowElement, kAXTitleAttribute) ?? ""
                let level = windowLevel(for: windowId)
                let subrole = axStringAttribute(windowElement, kAXSubroleAttribute) ?? ""

                print("zwm: discoverWindows:   wid=\(windowId) level=\(level) minimized=\(isMinimized) subrole=\(subrole) title=\"\(title)\"")
                windows.append(DiscoveredWindow(
                    windowId: windowId, pid: app.pid, appName: app.name, title: title,
                    frame: frame, isMinimized: isMinimized, isFullscreen: isFullscreen,
                    windowLevel: level, subrole: subrole
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
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)

        var size = CGSize(width: frame.size.width, height: frame.size.height)
        guard let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)

        // Double-set trick: some apps constrain on the first call
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
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

    public func setMinimized(_ windowId: UInt32, _ minimized: Bool) async throws {
        guard let element = await findWindowElement(windowId) else {
            throw AXBackendError.windowNotFound(windowId)
        }
        AXUIElementSetAttributeValue(
            element, kAXMinimizedAttribute as CFString,
            minimized ? kCFBooleanTrue : kCFBooleanFalse
        )
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

    // MARK: - AX Observer per app

    private func startObservingApp(_ pid: pid_t) {
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

        guard result == .success, let observer else { return }

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

        for name in notifications {
            AXObserverAddNotification(observer, appElement, name as CFString, refcon)
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )

        withLock { appObservers[pid] = observer }
    }

    private func stopObservingApp(_ pid: pid_t) {
        let observer = withLock { appObservers.removeValue(forKey: pid) }
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

        print("zwm: AX notification: \(notification) windowId=\(windowId) pid=\(pid)")

        switch notification {
        case kAXWindowCreatedNotification:
            if windowId != 0 {
                withLock { _ = knownWindowsByPid[pid, default: []].insert(windowId) }
                let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
                let title = axStringAttribute(element, kAXTitleAttribute) ?? ""
                let subrole = axStringAttribute(element, kAXSubroleAttribute) ?? ""
                let frame = axFrame(element)
                emit(.windowCreated(pid: pid, windowId: windowId, appName: appName, title: title, subrole: subrole, frame: frame))
            }
        case kAXUIElementDestroyedNotification:
            if windowId != 0 {
                withLock { _ = knownWindowsByPid[pid, default: []].remove(windowId) }
                emit(.windowDestroyed(windowId: windowId))
            }
            // When windowId==0, the destroyed element is not a window (e.g. a tab).
            // Don't try to detect which window is gone — AX and CGWindowList are unreliable
            // during tab transitions. The reconcile loop will catch truly destroyed windows.
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

    /// Find the AXUIElement for a given CGWindowID by scanning all regular apps.
    private func findWindowElement(_ windowId: UInt32) async -> AXUIElement? {
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
                    return win
                }
            }
        }
        return nil
    }

    private func axArrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
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
    case accessibilityNotEnabled
}
