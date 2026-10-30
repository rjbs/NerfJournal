import AppKit
import NerfCore
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var panel: NSPanel?
    private var quickNoteStore: QuickNoteStore?
    private var cancellables = Set<AnyCancellable>()
    private var syncTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        startSync()
        // The dev build (bundle id systems.semiotic.nerfjournal.dev) runs beside the
        // installed app, and only one process can own a global hot key, so it
        // leaves Cmd-Shift-J to the installed app. -- claude, 2026-10-28
        #if !DEV
        registerGlobalHotKey()
        #endif
    }

    // Keeps the engine syncing for the life of the process. -- claude, 2026-10-28
    private func startSync() {
        let sync = AppDatabase.shared.sync
        syncTask = Task.detached {
            await sync.engine.run()
        }
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

    func showQuickNotePanel() {
        if let existing = panel, existing.isVisible {
            // Second press while open toggles between pending and done mode.
            quickNoteStore?.isDone.toggle()
            existing.makeKeyAndOrderFront(nil)
            return
        }
        cancellables.removeAll()
        let store = QuickNoteStore()
        quickNoteStore = store
        let view = QuickNoteView(dismiss: {
            self.panel?.orderOut(nil)
            self.panel = nil
            self.quickNoteStore = nil
            self.cancellables.removeAll()
        }, store: store)
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = .preferredContentSize

        // Build the panel as nonactivating *from construction*. Setting the style
        // mask after the fact (styleMask.insert) reports as set but does not
        // change the activation behavior — so makeKeyAndOrderFront still tried to
        // activate the app, which Sequoia's cooperative activation refuses for a
        // background app, leaving the panel placed but never composited. A truly
        // nonactivating panel composites as a floating overlay without fronting
        // the app at all — and not activating means dismissing it never pulls
        // focus to another Space. -- claude, 2026-06-18
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 96),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.contentViewController = hosting
        p.title = "Quick Entry"
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.setContentSize(hosting.view.fittingSize)
        p.center()
        panel = p

        // Resize the panel whenever the SwiftUI content changes height (e.g.
        // when the date or category picker expands). -- claude, 2026-04-06
        hosting.publisher(for: \.preferredContentSize)
            .dropFirst()
            .filter { $0.width > 0 && $0.height > 0 }
            .sink { [weak p] size in p?.setContentSize(size) }
            .store(in: &cancellables)

        p.orderFrontRegardless()
        p.makeKeyAndOrderFront(nil)
    }

    private func fourCharCode(_ str: String) -> FourCharCode {
        str.utf8.prefix(4).reduce(0) { $0 << 8 + FourCharCode($1) }
    }
}
