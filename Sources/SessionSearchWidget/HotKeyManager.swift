// HotKeyManager.swift
//
// Two related but distinct input mechanisms live in this file. The global hotkey
// (Cmd+K) uses the Carbon Event Manager because a Carbon hotkey registration
// actually intercepts the keystroke system-wide, preventing the frontmost app from
// also consuming it — an NSEvent global monitor can only observe events, not stop
// their normal delivery, so it cannot reliably summon the widget over an app that
// also binds Cmd+K. Outside-click dismissal, by contrast, only needs to *observe*
// clicks happening in other applications, so NSEvent.addGlobalMonitorForEvents is
// the right (and much simpler) tool for that job.

import AppKit
import Carbon
import Foundation

/// Builds a four-character `OSType` (e.g. for `EventHotKeyID.signature`) from a
/// 4-character ASCII string, since Swift has no literal syntax for `OSType`.
private func fourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + OSType(scalar.value & 0xFF)
    }
    return result
}

/// Registers a global Cmd+K hotkey using the Carbon Event Manager and invokes
/// `onTrigger` on the main actor whenever it fires. See file header for why
/// Carbon is used here instead of an `NSEvent` global monitor.
@MainActor
final class HotKeyManager {
    private static let signature: OSType = fourCharCode("SSWK")
    private static let hotKeyID: UInt32 = 1

    private let onTrigger: @MainActor () -> Void

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init(onTrigger: @escaping @MainActor () -> Void) {
        self.onTrigger = onTrigger
    }

    func register() {
        guard hotKeyRef == nil else { return }

        if eventHandlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )

            let selfPointer = Unmanaged.passUnretained(self).toOpaque()

            var handlerRef: EventHandlerRef?
            let status = InstallEventHandler(
                GetEventDispatcherTarget(),
                { _, eventRef, userData -> OSStatus in
                    guard let eventRef, let userData else {
                        return OSStatus(eventNotHandledErr)
                    }

                    var pressedID = EventHotKeyID()
                    let paramStatus = GetEventParameter(
                        eventRef,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &pressedID
                    )

                    guard paramStatus == noErr,
                          pressedID.signature == HotKeyManager.signature,
                          pressedID.id == HotKeyManager.hotKeyID else {
                        return OSStatus(eventNotHandledErr)
                    }

                    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                    Task { @MainActor in
                        manager.onTrigger()
                    }
                    return noErr
                },
                1,
                &eventType,
                selfPointer,
                &handlerRef
            )

            guard status == noErr else { return }
            eventHandlerRef = handlerRef
        }

        var hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        var newHotKeyRef: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_K),
            UInt32(cmdKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &newHotKeyRef
        )

        guard registerStatus == noErr else { return }
        hotKeyRef = newHotKeyRef
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }
}

/// Watches for mouse clicks landing in other applications so the caller can
/// dismiss its window when the user clicks away. See file header for why
/// `NSEvent.addGlobalMonitorForEvents` (rather than Carbon) is the right tool here.
@MainActor
final class OutsideClickMonitor {
    private let onOutsideClick: @MainActor () -> Void
    private var monitorToken: Any?

    init(onOutsideClick: @escaping @MainActor () -> Void) {
        self.onOutsideClick = onOutsideClick
    }

    func start() {
        guard monitorToken == nil else { return }

        let callback = onOutsideClick
        monitorToken = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { (_: NSEvent) in
            Task { @MainActor in
                callback()
            }
        }
    }

    func stop() {
        if let monitorToken {
            NSEvent.removeMonitor(monitorToken)
            self.monitorToken = nil
        }
    }
}
