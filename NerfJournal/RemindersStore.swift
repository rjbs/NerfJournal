import EventKit
import Foundation

@MainActor
final class RemindersStore: ObservableObject {
    private let eventStore = EKEventStore()

    @Published var reminders: [EKReminder] = []
    @Published var isLoading = false
    @Published var authorizationStatus: EKAuthorizationStatus =
        EKEventStore.authorizationStatus(for: .reminder)

    func load() async {
        isLoading = true
        defer { isLoading = false }

        if authorizationStatus == .notDetermined {
            _ = try? await eventStore.requestFullAccessToReminders()
            authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        }

        guard authorizationStatus == .fullAccess else { return }

        await fetchReminders()
    }

    func refresh() async {
        guard authorizationStatus == .fullAccess else { return }
        isLoading = true
        defer { isLoading = false }
        await fetchReminders()
    }

    private func fetchReminders() async {
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
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
