import AppKit
import Foundation
import NerfCore

// The current civil day, as observable state.
//
// `CivilDate.today` is a fine thing to call from an action, but a view that
// reads it acquires no dependency on the passing of time: SwiftUI has no reason
// to re-evaluate the body, so a window left open overnight keeps rendering
// yesterday as though it were today until some unrelated state change happens
// to redraw it. Publishing the day fixes that — views observe this object and
// re-render when the date rolls over. -- claude, 2026-08-23
@MainActor
final class DayClock: ObservableObject {
    @Published private(set) var today: CivilDate = .today

    private var rolloverTimer: Timer?

    init() {
        // A midnight timer alone isn't enough: the machine sleeps through it, and
        // the clock or zone can move under us. Every one of these just re-asks
        // what day it is, so extra notifications cost nothing.
        let center = NotificationCenter.default
        for name: Notification.Name in [
            NSApplication.didBecomeActiveNotification,
            .NSSystemClockDidChange,
            .NSSystemTimeZoneDidChange,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }

        scheduleRollover()
    }

    // The timer is main-actor state, so the deinit runs there too (SE-0371,
    // available from macOS 26). -- claude, 2026-10-17
    isolated deinit {
        rolloverTimer?.invalidate()
    }

    private func tick() {
        let now = CivilDate.today
        if now != today { today = now }
        scheduleRollover()
    }

    // Fire just after the next local midnight. The second of slack keeps a timer
    // that fires a hair early from seeing the old day and having to wait out
    // another full day to correct itself.
    private func scheduleRollover() {
        rolloverTimer?.invalidate()

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        guard let midnight = cal.nextDate(
            after: Date(),
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else { return }

        let timer = Timer(fire: midnight.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        rolloverTimer = timer
    }
}
