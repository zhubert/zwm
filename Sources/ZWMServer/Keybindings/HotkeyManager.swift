import CoreGraphics
import Foundation

/// Manages global hotkeys using a CGEvent tap.
/// Intercepts key-down events, matches against registered bindings,
/// and dispatches the bound command string to a handler.
public final class HotkeyManager: @unchecked Sendable {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var bindings: [KeyCombo: String] = [:]
    private var currentMode: String = "main"
    private var lock = os_unfair_lock()
    private let commandHandler: @Sendable (String) -> Void

    public init(commandHandler: @escaping @Sendable (String) -> Void) {
        self.commandHandler = commandHandler
    }

    /// Load keybindings from config.
    public func loadBindings(_ keybindings: [String: [String: String]]) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        bindings.removeAll()
        // Load the current mode's bindings
        if let modeBindings = keybindings[currentMode] {
            for (key, command) in modeBindings {
                if let combo = parseKeyCombo(key) {
                    bindings[combo] = command
                }
            }
        }
    }

    /// Switch the active binding mode.
    public func switchMode(_ mode: String, keybindings: [String: [String: String]]) {
        os_unfair_lock_lock(&lock)
        currentMode = mode
        bindings.removeAll()
        if let modeBindings = keybindings[mode] {
            for (key, command) in modeBindings {
                if let combo = parseKeyCombo(key) {
                    bindings[combo] = command
                }
            }
        }
        os_unfair_lock_unlock(&lock)
    }

    /// Start intercepting keyboard events. Must be called from main thread.
    public func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return mgr.handleEvent(event)
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

    /// Stop intercepting keyboard events.
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

    private func handleEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection([.maskAlternate, .maskShift, .maskControl, .maskCommand])
        let combo = KeyCombo(modifiers: flags, keyCode: keyCode)

        os_unfair_lock_lock(&lock)
        let command = bindings[combo]
        os_unfair_lock_unlock(&lock)

        if let command {
            commandHandler(command)
            return nil // Consume the event
        }

        return Unmanaged.passRetained(event)
    }
}
