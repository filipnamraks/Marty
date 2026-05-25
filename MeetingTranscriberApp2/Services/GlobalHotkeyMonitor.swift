import Foundation
import AppKit
import IOKit.hid

/// Listens for ⇧⌘M anywhere on the system (even while the user is in Zoom/Meet).
/// Emits `.pressed` on keyDown and `.released` on keyUp.
///
/// Uses `CGEventTap`, which requires **Input Monitoring** permission. The user
/// grants this from System Settings → Privacy & Security → Input Monitoring,
/// then must relaunch Marty for it to take effect.
final class GlobalHotkeyMonitor {

    enum Event { case pressed, released }

    enum PermissionState { case granted, denied, unknown }

    var onEvent: ((Event) -> Void)?

    /// True if the active tap is consuming keystrokes (no system beep). Requires Accessibility.
    private(set) var isConsuming: Bool = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let keycode: Int64
    private let requiredModifiers: CGEventFlags
    private let modifierMask: UInt64 = CGEventFlags([.maskCommand, .maskShift, .maskAlternate, .maskControl]).rawValue

    /// Default: ⇧⌘M (keycode 46 = kVK_ANSI_M).
    init(keycode: Int64 = 46, modifiers: CGEventFlags = [.maskCommand, .maskShift]) {
        self.keycode = keycode
        self.requiredModifiers = modifiers
    }

    func permissionState() -> PermissionState {
        // Probe-create a tap to discover whether the user has granted Input Monitoring.
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let probe = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )
        guard let probe = probe else { return .denied }
        CFMachPortInvalidate(probe)
        return .granted
    }

    func start() throws {
        if tap != nil { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Try .defaultTap first (consumes events → no beep, needs Accessibility).
        // If macOS refuses, fall back to .listenOnly (just Input Monitoring) so the
        // hotkey still works — the user gets a beep until they grant Accessibility.
        let consumingCallback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            let consumed = monitor.handle(type: type, event: event)
            return consumed ? nil : Unmanaged.passUnretained(event)
        }
        let listenCallback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            _ = monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        var installedTap: CFMachPort?
        var consuming = false
        if let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(mask),
            callback: consumingCallback, userInfo: selfPtr
        ) {
            installedTap = t
            consuming = true
        } else if let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: CGEventMask(mask),
            callback: listenCallback, userInfo: selfPtr
        ) {
            installedTap = t
            consuming = false
        }

        guard let tap = installedTap else {
            throw NSError(
                domain: "Marty.GlobalHotkey",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not install hotkey listener. Grant Marty Input Monitoring in System Settings → Privacy & Security and relaunch."]
            )
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        self.isConsuming = consuming
    }

    func stop() {
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoopSource = nil
    }

    deinit { stop() }

    /// Returns true if this event was our hotkey (and should be consumed).
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown || type == .keyUp else { return false }
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        guard kc == keycode else { return false }
        let flags = event.flags.rawValue & modifierMask
        guard flags == requiredModifiers.rawValue else { return false }

        if type == .keyDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) == 1
            if isRepeat { return true } // still consume so the focused app doesn't beep on repeat
            DispatchQueue.main.async { [weak self] in self?.onEvent?(.pressed) }
        } else if type == .keyUp {
            DispatchQueue.main.async { [weak self] in self?.onEvent?(.released) }
        }
        return true
    }
}
