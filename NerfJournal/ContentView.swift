import EventKit
import SwiftUI

struct ContentView: View {
    @StateObject private var store = RemindersStore()

    var body: some View {
        content
            .navigationTitle("Pending Reminders")
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isLoading)
                }
            }
            .task {
                await store.load()
            }
    }

    @ViewBuilder
    private var content: some View {
        if store.authorizationStatus == .denied || store.authorizationStatus == .restricted {
            Text("Access to Reminders was denied.\nPlease update permissions in System Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.isLoading && store.reminders.isEmpty {
            ProgressView("Loading reminders\u{2026}")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.reminders.isEmpty {
            Text("No pending reminders.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(store.reminders, id: \.calendarItemIdentifier) { reminder in
                ReminderRow(reminder: reminder)
            }
        }
    }
}

struct ReminderRow: View {
    let reminder: EKReminder

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(reminder.title ?? "(untitled)")
                .lineLimit(2)
            if let calendar = reminder.calendar {
                Text(calendar.title)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: calendar.color))
            }
        }
        .padding(.vertical, 2)
    }
}
