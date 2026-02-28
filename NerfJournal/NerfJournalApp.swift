import SwiftUI

@main
struct NerfJournalApp: App {
    @StateObject private var store = RemindersStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView()
            }
            .environmentObject(store)
        }
        .defaultSize(width: 420, height: 640)

        Window("Calendars", id: "calendar-picker") {
            NavigationStack {
                CalendarPickerView()
            }
            .environmentObject(store)
        }
        .defaultSize(width: 280, height: 400)
    }
}
