import SwiftUI

@main
struct NerfJournalApp: App {
    @StateObject private var store = LocalJournalStore()
    @StateObject private var diaryStore = DiaryStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView()
            }
            .environmentObject(store)
        }
        .defaultSize(width: 420, height: 640)
        .commands { DebugCommands() }

        Window("Work Diary", id: "diary") {
            DiaryView()
                .environmentObject(diaryStore)
        }
        .defaultSize(width: 700, height: 520)
    }
}
