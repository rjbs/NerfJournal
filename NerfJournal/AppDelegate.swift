import AppKit
import Carbon.HIToolbox
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var panel: NSPanel?
    private var activationToken: NSObjectProtocol?
    private var quickNoteStore: QuickNoteStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerGlobalHotKey()
    }

    private func registerGlobalHotKey() {
        // Register Cmd-Shift-J (kVK_ANSI_J = 38) as a global hot key.  The Carbon
        // RegisterEventHotKey API works in sandboxed apps without accessibility
        // permissions, unlike NSEvent.addGlobalMonitorForEvents or CGEventTap.
        // -- claude, 2026-03-02
        let hotKeyID = EventHotKeyID(signature: fourCharCode("nrfj"), id: 1)
        let eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, userData) -> OSStatus in
                guard let userData else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { MainActor.assumeIsolated { delegate.showQuickNotePanel() } }
                return noErr
            },
            1, [eventSpec],
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        RegisterEventHotKey(
            UInt32(kVK_ANSI_J), UInt32(cmdKey | shiftKey),
            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef
        )
    }

    @MainActor
    func showQuickNotePanel() {
        if let existing = panel, existing.isVisible {
            // Second press while open toggles between note and todo mode.
            quickNoteStore?.isTodo.toggle()
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let store = QuickNoteStore()
        quickNoteStore = store
        let view = QuickNoteView(dismiss: {
            self.panel?.orderOut(nil)
            self.panel = nil
            self.quickNoteStore = nil
        }, store: store)
        let hosting = NSHostingController(rootView: view)
        let p = NSPanel(contentViewController: hosting)
        p.title = "Quick Entry"
        p.isFloatingPanel = true
        p.level = .floating
        p.setContentSize(hosting.view.fittingSize)
        p.center()
        p.orderFrontRegardless()
        panel = p

        if NSApp.isActive {
            p.makeKeyAndOrderFront(nil)
        } else {
            // On multi-display systems, calling makeKeyAndOrderFront immediately
            // after activate() loses a race: the journal window on display 1 grabs
            // key status during the activation handoff before we can claim it.
            // Waiting for didBecomeActiveNotification ensures the app is fully
            // active before we steal the key window. -- claude, 2026-03-02
            activationToken = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil, queue: .main
            ) { [weak self, weak p] _ in
                if let token = self?.activationToken {
                    NotificationCenter.default.removeObserver(token)
                    self?.activationToken = nil
                }
                p?.makeKeyAndOrderFront(nil)
            }
            NSApp.activate()
        }
    }

    private func fourCharCode(_ str: String) -> FourCharCode {
        str.utf8.prefix(4).reduce(0) { $0 << 8 + FourCharCode($1) }
    }
}
