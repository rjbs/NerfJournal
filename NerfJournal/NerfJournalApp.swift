import SwiftUI

struct TodoCommands: Commands {
    @FocusedValue(\.focusAddTodo) var focusAddTodo: Binding<Bool>?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Todo") { focusAddTodo?.wrappedValue = true }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(focusAddTodo == nil)
        }
    }
}

@main
struct NerfJournalApp: App {
    @StateObject private var journalStore = LocalJournalStore()
    @StateObject private var diaryStore = DiaryStore()
    @StateObject private var bundleStore = BundleStore()
    @StateObject private var categoryStore = CategoryStore()

    var body: some Scene {
        WindowGroup {
            DiaryView()
                .environmentObject(diaryStore)
                .environmentObject(journalStore)
                .environmentObject(bundleStore)
                .environmentObject(categoryStore)
                .focusedSceneObject(journalStore)
        }
        .defaultSize(width: 700, height: 520)
        .commands {
            DebugCommands()
            TodoCommands()
        }

        Window("Bundle Manager", id: "bundle-manager") {
            BundleManagerView()
                .environmentObject(bundleStore)
                .environmentObject(categoryStore)
        }
        .defaultSize(width: 600, height: 480)
    }
}
