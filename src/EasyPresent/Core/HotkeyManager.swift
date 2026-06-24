import AppKit
import Carbon.HIToolbox

/// Manages global hotkeys using the Carbon RegisterEventHotKey API.
/// Does NOT require Accessibility permission.
final class HotkeyManager: @unchecked Sendable {

    static let shared = HotkeyManager()

    /// Called when the Draw menu item is clicked (Draw is gesture-driven; no hotkey).
    var onDrawHotkey: (() -> Void)?

    /// Called when the Draw toggle hotkey (⌥Space) is triggered.
    var onDrawToggleHotkey: (() -> Void)?

    /// Called when the help hotkey (⌥/) is pressed / released — help shows while held.
    var onHelpDown: (() -> Void)?
    var onHelpUp: (() -> Void)?

    /// Called when the Preferences hotkey (⌥,) is pressed.
    var onPreferencesHotkey: (() -> Void)?

    /// Called when ⌥↑ / ⌥↓ are pressed (color cycling, only active while drawing).
    var onColorNext: (() -> Void)?
    var onColorPrev: (() -> Void)?

    /// Erase (clear the canvas) / undo, active only while drawing. Always ⌥E / ⌥Z — the
    /// overlay only draws while ⌥ is held, so the modifier is always down for these.
    var onErase: (() -> Void)?
    var onUndo: (() -> Void)?

    /// ⌥0–⌥9 (active only while drawing): set the auto-disappear timeout to N seconds
    /// (0 = off). The argument is the digit.
    var onSetAutoDisappear: ((Int) -> Void)?

    private var drawToggleHotKeyRef: EventHotKeyRef?
    private var helpHotKeyRef: EventHotKeyRef?
    private var prefsHotKeyRef: EventHotKeyRef?
    private var colorNextHotKeyRef: EventHotKeyRef?
    private var colorPrevHotKeyRef: EventHotKeyRef?
    private var eraseHotKeyRef: EventHotKeyRef?
    private var undoHotKeyRef: EventHotKeyRef?
    private var numberHotKeyRefs: [EventHotKeyRef?] = Array(repeating: nil, count: 10)
    private var eventHandlerRef: EventHandlerRef?

    /// Tracks whether the draw-only shortcuts are registered so `reregisterHotkeys()` can restore them.
    private var drawShortcutsActive = false

    /// Signature used to identify our hot-key events ('ZmIt')
    private let hotKeySignature: OSType = 0x5A6D_4974 // 'ZmIt'
    // Note: Zoom and Draw are gesture-driven (⌥ double-click / hold ⌥), not hotkeys.
    private let drawToggleHotKeyID: UInt32 = 4
    private let helpHotKeyID: UInt32 = 5
    private let prefsHotKeyID: UInt32 = 6
    private let colorNextHotKeyID: UInt32 = 7
    private let colorPrevHotKeyID: UInt32 = 8
    private let eraseHotKeyID: UInt32 = 9
    private let undoHotKeyID: UInt32 = 10
    private let numberHotKeyIDBase: UInt32 = 30  // ⌥0..⌥9 → IDs 30..39

    private init() {}

    // MARK: - Public

    func start() {
        guard eventHandlerRef == nil else {
            NSLog("[HotkeyManager] Hot key already registered — skipping.")
            return
        }

        // Install a Carbon event handler for hot-key pressed AND released (the help
        // hotkey shows its popover only while held).
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            2,
            &eventTypes,
            selfPtr,
            &eventHandlerRef
        )

        guard status == noErr else {
            NSLog("[HotkeyManager] Failed to install event handler: %d", status)
            return
        }

        // Zoom and Draw are gesture-driven (⌥ double-click / hold ⌥) — no hotkeys.

        // Register the user-configurable pin/unpin toggle hotkey (default ⌥Space).
        let toggleKeyCode = Settings.shared.toggleHotkeyKeyCode
        let toggleModifiers = Settings.shared.toggleHotkeyModifiers
        let drawToggleKeyID = EventHotKeyID(signature: hotKeySignature, id: drawToggleHotKeyID)
        let drawToggleStatus = RegisterEventHotKey(
            toggleKeyCode,
            toggleModifiers,
            drawToggleKeyID,
            GetApplicationEventTarget(),
            0,
            &drawToggleHotKeyRef
        )

        guard drawToggleStatus == noErr else {
            NSLog("[HotkeyManager] Failed to register draw toggle hotkey: %d", drawToggleStatus)
            return
        }

        NSLog("[HotkeyManager] Draw toggle hotkey registered: %@",
              Settings.hotkeyDisplayString(keyCode: toggleKeyCode, modifiers: toggleModifiers))

        // Register the help hotkey: ⌥/ (Option+slash). Shows help while held.
        let helpKeyID = EventHotKeyID(signature: hotKeySignature, id: helpHotKeyID)
        let helpStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_Slash),
            UInt32(optionKey),
            helpKeyID,
            GetApplicationEventTarget(),
            0,
            &helpHotKeyRef
        )

        guard helpStatus == noErr else {
            NSLog("[HotkeyManager] Failed to register help hotkey: %d", helpStatus)
            return
        }

        // Register the Preferences hotkey: ⌥, (Option+comma).
        let prefsKeyID = EventHotKeyID(signature: hotKeySignature, id: prefsHotKeyID)
        let prefsStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_Comma),
            UInt32(optionKey),
            prefsKeyID,
            GetApplicationEventTarget(),
            0,
            &prefsHotKeyRef
        )

        guard prefsStatus == noErr else {
            NSLog("[HotkeyManager] Failed to register preferences hotkey: %d", prefsStatus)
            return
        }
    }

    func stop() {
        if let ref = drawToggleHotKeyRef {
            UnregisterEventHotKey(ref)
            drawToggleHotKeyRef = nil
        }
        if let ref = helpHotKeyRef {
            UnregisterEventHotKey(ref)
            helpHotKeyRef = nil
        }
        if let ref = prefsHotKeyRef {
            UnregisterEventHotKey(ref)
            prefsHotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
        NSLog("[HotkeyManager] Hotkeys unregistered.")
    }

    /// Re-register all hotkeys with current Settings values.
    func reregisterHotkeys() {
        let active = drawShortcutsActive
        stop()
        disableDrawShortcuts()
        start()
        if active { enableDrawShortcuts() }
    }

    /// Register the keys that are live only while a draw session is open. They all use the
    /// hold modifier (⌥), so they only fire while the user is actively drawing and never
    /// shadow normal typing the rest of the time:
    ///  • color cycling — ⌥↑ / ⌥↓
    ///  • erase / undo  — ⌥E / ⌥Z
    ///  • auto-disappear — ⌥0…⌥9 (0 = off, N = N seconds)
    func enableDrawShortcuts() {
        disableDrawShortcuts()
        drawShortcutsActive = true

        let mod = Settings.shared.holdModifier.carbonFlag
        RegisterEventHotKey(UInt32(kVK_UpArrow), mod,
                            EventHotKeyID(signature: hotKeySignature, id: colorNextHotKeyID),
                            GetApplicationEventTarget(), 0, &colorNextHotKeyRef)
        RegisterEventHotKey(UInt32(kVK_DownArrow), mod,
                            EventHotKeyID(signature: hotKeySignature, id: colorPrevHotKeyID),
                            GetApplicationEventTarget(), 0, &colorPrevHotKeyRef)
        RegisterEventHotKey(UInt32(kVK_ANSI_E), mod,
                            EventHotKeyID(signature: hotKeySignature, id: eraseHotKeyID),
                            GetApplicationEventTarget(), 0, &eraseHotKeyRef)
        RegisterEventHotKey(UInt32(kVK_ANSI_Z), mod,
                            EventHotKeyID(signature: hotKeySignature, id: undoHotKeyID),
                            GetApplicationEventTarget(), 0, &undoHotKeyRef)
        let numberKeyCodes: [Int] = [
            kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
            kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
        ]
        for digit in 0...9 {
            RegisterEventHotKey(UInt32(numberKeyCodes[digit]), mod,
                                EventHotKeyID(signature: hotKeySignature, id: numberHotKeyIDBase + UInt32(digit)),
                                GetApplicationEventTarget(), 0, &numberHotKeyRefs[digit])
        }
    }

    func disableDrawShortcuts() {
        drawShortcutsActive = false
        if let r = colorNextHotKeyRef { UnregisterEventHotKey(r); colorNextHotKeyRef = nil }
        if let r = colorPrevHotKeyRef { UnregisterEventHotKey(r); colorPrevHotKeyRef = nil }
        if let r = eraseHotKeyRef { UnregisterEventHotKey(r); eraseHotKeyRef = nil }
        if let r = undoHotKeyRef { UnregisterEventHotKey(r); undoHotKeyRef = nil }
        for i in numberHotKeyRefs.indices {
            if let r = numberHotKeyRefs[i] { UnregisterEventHotKey(r); numberHotKeyRefs[i] = nil }
        }
    }

    // MARK: - Event Processing

    fileprivate func handleHotKeyEvent(_ event: EventRef) {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            UInt32(kEventParamDirectObject),
            UInt32(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else { return }

        guard hotKeyID.signature == hotKeySignature else { return }

        let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)

        if hotKeyID.id == drawToggleHotKeyID {
            guard pressed else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onDrawToggleHotkey?()
            }
        } else if hotKeyID.id == helpHotKeyID {
            DispatchQueue.main.async { [weak self] in
                if pressed { self?.onHelpDown?() } else { self?.onHelpUp?() }
            }
        } else if hotKeyID.id == prefsHotKeyID {
            guard pressed else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onPreferencesHotkey?()
            }
        } else if hotKeyID.id == colorNextHotKeyID {
            guard pressed else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onColorNext?()
            }
        } else if hotKeyID.id == colorPrevHotKeyID {
            guard pressed else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onColorPrev?()
            }
        } else if hotKeyID.id == eraseHotKeyID {
            guard pressed else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onErase?()
            }
        } else if hotKeyID.id == undoHotKeyID {
            guard pressed else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onUndo?()
            }
        } else if hotKeyID.id >= numberHotKeyIDBase && hotKeyID.id < numberHotKeyIDBase + 10 {
            guard pressed else { return }
            let digit = Int(hotKeyID.id - numberHotKeyIDBase)
            DispatchQueue.main.async { [weak self] in
                self?.onSetAutoDisappear?(digit)
            }
        }
    }
}

// MARK: - C Callback

private func hotKeyEventHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.handleHotKeyEvent(event)

    return noErr
}
