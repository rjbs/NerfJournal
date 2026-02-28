import EventKit
import SwiftUI

struct CalendarPickerView: View {
    @EnvironmentObject private var store: RemindersStore

    var body: some View {
        List {
            ForEach(store.calendarsBySource, id: \.source.sourceIdentifier) { group in
                Section(group.source.title) {
                    ForEach(group.calendars, id: \.calendarIdentifier) { calendar in
                        Toggle(isOn: Binding(
                            get: { store.selectedCalendarIDs.contains(calendar.calendarIdentifier) },
                            set: { _ in store.toggleCalendar(calendar) }
                        )) {
                            Label {
                                Text(calendar.title)
                            } icon: {
                                Circle()
                                    .fill(Color(nsColor: calendar.color))
                                    .frame(width: 12, height: 12)
                            }
                        }
                    }
                }
            }
        }
        .toggleStyle(.checkbox)
        .navigationTitle("Calendars")
    }
}
