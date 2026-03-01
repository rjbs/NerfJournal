import SwiftUI

@main
struct NerfJournalApp: App {
    @StateObject private var journalStore = LocalJournalStore()
    @StateObject private var diaryStore = DiaryStore()

    var body: some Scene {
        WindowGroup {
            DiaryView()
                .environmentObject(diaryStore)
                .environmentObject(journalStore)
                .focusedSceneObject(journalStore)
        }
        .defaultSize(width: 700, height: 520)
        .commands { DebugCommands() }
    }
}
