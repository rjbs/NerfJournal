import EventKit
import Foundation

@MainActor
final class RemindersStore: ObservableObject {
    private let eventStore = EKEventStore()
    private static let selectedIDsKey = "selectedCalendarIDs"

    @Published var reminders: [EKReminder] = []
    @Published var isLoading = false
    @Published var authorizationStatus: EKAuthorizationStatus =
        EKEventStore.authorizationStatus(for: .reminder)
    @Published var calendarsBySource: [(source: EKSource, calendars: [EKCalendar])] = []
    @Published private(set) var selectedCalendarIDs: Set<String> = []

    private var storeObservationTask: Task<Void, Never>?

    deinit {
        storeObservationTask?.cancel()
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        if authorizationStatus == .notDetermined {
            _ = try? await eventStore.requestFullAccessToReminders()
            authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        }

        guard authorizationStatus == .fullAccess else { return }

        refreshCalendarList()
        startObserving()
        await fetchReminders()
    }

    func refresh() async {
        guard authorizationStatus == .fullAccess else { return }
        isLoading = true
        defer { isLoading = false }
        refreshCalendarList()
        await fetchReminders()
    }

    func toggleCalendar(_ calendar: EKCalendar) {
        let id = calendar.calendarIdentifier
        if selectedCalendarIDs.contains(id) {
            selectedCalendarIDs.remove(id)
        } else {
            selectedCalendarIDs.insert(id)
        }
        persistSelection()
        Task { await fetchReminders() }
    }

    private func refreshCalendarList() {
        let allCalendars = eventStore.calendars(for: .reminder)
        let allIDs = Set(allCalendars.map(\.calendarIdentifier))

        if UserDefaults.standard.object(forKey: Self.selectedIDsKey) == nil {
            // First run: select everything.
            selectedCalendarIDs = allIDs
            persistSelection()
        } else {
            let saved = Set(UserDefaults.standard.stringArray(forKey: Self.selectedIDsKey) ?? [])
            let valid = saved.intersection(allIDs)
            selectedCalendarIDs = valid
            if valid != saved { persistSelection() }
        }

        var bySource: [String: (source: EKSource, calendars: [EKCalendar])] = [:]
        for cal in allCalendars {
            let sid = cal.source.sourceIdentifier
            if bySource[sid] == nil { bySource[sid] = (source: cal.source, calendars: []) }
            bySource[sid]!.calendars.append(cal)
        }
        calendarsBySource = bySource.values
            .map { (source: $0.source, calendars: $0.calendars.sorted { $0.title < $1.title }) }
            .sorted { $0.source.title < $1.source.title }
    }

    private func persistSelection() {
        UserDefaults.standard.set(Array(selectedCalendarIDs), forKey: Self.selectedIDsKey)
    }

    private func startObserving() {
        guard storeObservationTask == nil else { return }
        storeObservationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                self?.refreshCalendarList()
                await self?.fetchReminders()
            }
        }
    }

    private func fetchReminders() async {
        guard !selectedCalendarIDs.isEmpty else {
            reminders = []
            return
        }

        let calendarsToFetch = eventStore.calendars(for: .reminder)
            .filter { selectedCalendarIDs.contains($0.calendarIdentifier) }

        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendarsToFetch
        )

        reminders = await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { fetched in
                let sorted = (fetched ?? []).sorted { a, b in
                    let calA = a.calendar?.title ?? ""
                    let calB = b.calendar?.title ?? ""
                    if calA != calB { return calA < calB }
                    return (a.title ?? "") < (b.title ?? "")
                }
                continuation.resume(returning: sorted)
            }
        }
    }
}
