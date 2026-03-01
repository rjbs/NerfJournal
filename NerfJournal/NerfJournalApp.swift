import SwiftUI

@main
struct NerfJournalApp: App {
    @StateObject private var journalStore = LocalJournalStore()
    @StateObject private var diaryStore = DiaryStore()
    @StateObject private var bundleStore = BundleStore()

    var body: some Scene {
        WindowGroup {
            DiaryView()
                .environmentObject(diaryStore)
                .environmentObject(journalStore)
                .environmentObject(bundleStore)
                .focusedSceneObject(journalStore)
        }
        .defaultSize(width: 700, height: 520)
        .commands { DebugCommands() }

        Window("Bundle Manager", id: "bundle-manager") {
            BundleManagerView()
                .environmentObject(bundleStore)
        }
        .defaultSize(width: 600, height: 480)
    }
}
