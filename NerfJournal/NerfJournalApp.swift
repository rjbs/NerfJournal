import SwiftUI

struct TodoCommands: Commands {
    @FocusedValue(\.focusAddTodo) var focusAddTodo: Binding<Bool>?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Todo") { focusAddTodo?.wrappedValue = true }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(focusAddTodo == nil)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Open Work Diary") { openWindow(id: "diary") }
                .keyboardShortcut("1", modifiers: .command)
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
        WindowGroup(id: "diary") {
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
                .focusedSceneObject(journalStore)
        }
        .defaultSize(width: 600, height: 480)
    }
}
